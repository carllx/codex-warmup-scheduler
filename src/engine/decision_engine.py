"""
Codex Warmup V2 - Decision Engine
Rolling Horizon + Rule Scoring + Event-Triggered Replanner
"""

import json
from datetime import datetime, timedelta
import dateutil.parser

class DecisionEngine:
    def __init__(self, config=None, config_path=None):
        if config_path:
            with open(config_path, "r", encoding="utf-8") as f:
                config = json.load(f)
        elif config is None:
            config = {}
        self.config = config
        self.weights = config.get("weights", {})
        self.planning = config.get("planning", {})
        self.user_value_weights = config.get("userValueWeights", [])

        # Default weights
        self.w_work = self.weights.get("workCoverage", 0.8)
        self.w_align = self.weights.get("boundaryAlignment", 1.2)
        self.w_wake = self.weights.get("wakeBenefit", 1.0)
        self.w_cost = self.weights.get("warmupCost", 5.0)
        self.p_sleep_base = self.weights.get("sleepDisruptionBase", 10.0)
        self.min_useful_score = self.weights.get("minimumUsefulScore", 30.0)
        self.min_incremental_benefit = self.planning.get("minIncrementalBenefit", 15.0)

        self.horizon_hours = self.planning.get("horizonHours", 24)
        self.grid_step_min = self.planning.get("gridStepMinutes", 15)
        self.window_duration_min = self.planning.get("windowDurationMin", 300)
        self.window_capacity = self.planning.get("windowCapacity", 100.0)
        self.warmup_consumption = self.planning.get("warmupConsumption", 1.0)

        self.user_profile = self.config.get("userProfile", {})
        self.demand_profile = self.config.get("demandProfile", [])

    def parse_time(self, t_str):
        if isinstance(t_str, datetime):
            return t_str
        return dateutil.parser.isoparse(t_str)

    def is_in_sleep(self, dt, sleep_windows):
        if not sleep_windows:
            return False
        t_hm = dt.strftime("%H:%M")
        windows = [sleep_windows] if isinstance(sleep_windows[0], str) else sleep_windows
        return any((s <= t_hm < e) if s < e else (t_hm >= s or t_hm < e) for s, e in windows)

    def get_time_weight(self, dt, profile=None):
        t_hm = dt.strftime("%H:%M")
        prof = profile or self.user_profile
        if prof and prof.get("expectedWorkWindows") is not None:
            work_windows = prof.get("expectedWorkWindows", [])
            if not work_windows:
                return 0.0
            if any((s <= t_hm < e) if s < e else (t_hm >= s or t_hm < e) for s, e in work_windows):
                return 1.0
            return 0.0 if self.is_in_sleep(dt, prof.get("sleepWindows", [])) else 0.2

        for slot in self.user_value_weights:
            s, e = slot["start"], slot["end"]
            if (s <= t_hm < e) if s < e else (t_hm >= s or t_hm < e):
                return slot["weight"]
        return 0.2

    def evaluate_window_utility(self, t, profile=None, now=None):
        if now is None:
            now = t
        prof = profile or self.user_profile
        window_end = t + timedelta(minutes=self.window_duration_min)
        step_min = 15
        step_weights = []
        step_curr = t
        while step_curr < window_end:
            step_weights.append(self.get_time_weight(step_curr, prof))
            step_curr += timedelta(minutes=step_min)
        raw_work_coverage = (sum(step_weights) / len(step_weights) * 100.0) if step_weights else 0.0

        candidate_reset = t + timedelta(minutes=self.window_duration_min)
        best_align_score = 0.0
        primary_start_str = prof.get("expectedPrimaryWorkStart") if prof else None
        all_starts = []
        if primary_start_str:
            all_starts.append((primary_start_str, True))
        for w in (prof.get("expectedWorkWindows", []) if prof else []):
            all_starts.append((w[0], False))

        for s_str, is_prim in all_starts:
            h, m = map(int, s_str.split(":"))
            for day_offset in range(3):
                day_base = (now + timedelta(days=day_offset)).date()
                target_dt = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                diff_min = abs((candidate_reset - target_dt).total_seconds()) / 60.0
                if is_prim:
                    align = 100.0 if diff_min <= 5 else (90.0 if diff_min <= 15 else (75.0 if diff_min <= 30 else (50.0 if diff_min <= 60 else (20.0 if diff_min <= 120 else 0.0))))
                else:
                    align = 40.0 if diff_min <= 15 else (25.0 if diff_min <= 30 else (10.0 if diff_min <= 60 else 0.0))
                if align > best_align_score:
                    best_align_score = align

        utility = self.w_work * raw_work_coverage + self.w_align * best_align_score
        return {
            "utility": utility,
            "workCoverage": raw_work_coverage,
            "boundaryAlignment": best_align_score,
            "bestAlignScore": best_align_score
        }

    def evaluate_trajectory_utility(self, policy_action, state):
        now = self.parse_time(state["now"])
        quota = state.get("quota", {})
        profile = state.get("userProfile") or self.user_profile
        work_windows = profile.get("expectedWorkWindows", []) if profile else []
        sleep_windows = profile.get("sleepWindows", []) if profile else []
        demand_profile = state.get("demandProfile") or profile.get("demandProfile") or self.demand_profile

        action_type, t_cand = policy_action
        warmup_cost = self.w_cost if (action_type == "WARMUP_AT" and t_cand is not None) else 0.0
        is_sleep_cand = self.is_in_sleep(t_cand, sleep_windows) if (action_type == "WARMUP_AT" and t_cand is not None) else False
        sleep_disruption = self.p_sleep_base if is_sleep_cand else 0.0

        active_until, remaining_capacity = None, 0.0
        if quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            reset_at = self.parse_time(quota["resetAt"])
            if reset_at.tzinfo is None and now.tzinfo is not None:
                reset_at = reset_at.replace(tzinfo=now.tzinfo)
            if reset_at > now:
                active_until, remaining_capacity = reset_at, self.window_capacity

        windows = [{"start": now.strftime("%Y-%m-%d %H:%M"), "end": active_until.strftime("%Y-%m-%d %H:%M"), "source": "INITIAL_ACTIVE", "capacity": remaining_capacity}] if active_until else []

        curr = now
        end_time = now + timedelta(hours=self.horizon_hours)
        step = timedelta(minutes=self.grid_step_min)
        total_demand, total_served, total_unserved = 0.0, 0.0, 0.0

        while curr < end_time:
            if active_until is not None and curr >= active_until:
                active_until, remaining_capacity = None, 0.0

            if action_type == "WARMUP_AT" and t_cand is not None and (curr <= t_cand < curr + step) and active_until is None:
                active_until = t_cand + timedelta(minutes=self.window_duration_min)
                remaining_capacity = max(0.0, self.window_capacity - self.warmup_consumption)
                windows.append({
                    "start": t_cand.strftime("%Y-%m-%d %H:%M"),
                    "end": active_until.strftime("%Y-%m-%d %H:%M"),
                    "source": "ARTIFICIAL_WARMUP",
                    "capacity": remaining_capacity
                })

            curr_hm = curr.strftime("%H:%M")
            step_demand = 0.0
            if demand_profile:
                for band in demand_profile:
                    b_s, b_e = band["start"], band["end"]
                    in_band = (b_s <= curr_hm < b_e) if b_s < b_e else (curr_hm >= b_s or curr_hm < b_e)
                    if in_band:
                        b_s_dt = datetime.strptime(b_s, "%H:%M")
                        b_e_dt = datetime.strptime(b_e, "%H:%M") + (timedelta(days=1) if b_e <= b_s else timedelta(0))
                        steps = max(1.0, (b_e_dt - b_s_dt).total_seconds() / (60.0 * self.grid_step_min))
                        step_demand += band["demand"] / steps
            elif any((w[0] <= curr_hm < w[1]) if w[0] < w[1] else (curr_hm >= w[0] or curr_hm < w[1]) for w in work_windows):
                step_demand = 2.0

            total_demand += step_demand
            if step_demand > 0:
                if active_until is None:
                    active_until = curr + timedelta(minutes=self.window_duration_min)
                    remaining_capacity = self.window_capacity
                    windows.append({
                        "start": curr.strftime("%Y-%m-%d %H:%M"),
                        "end": active_until.strftime("%Y-%m-%d %H:%M"),
                        "source": "NATURAL_USE",
                        "capacity": remaining_capacity
                    })

                if active_until is not None and curr < active_until:
                    servable = min(step_demand, remaining_capacity)
                    remaining_capacity -= servable
                    total_served += servable
                    total_unserved += (step_demand - servable)
                else:
                    total_unserved += step_demand

            curr += step

        total_costs = warmup_cost + sleep_disruption
        return {
            "totalServedDemand": round(total_served, 1),
            "totalUnservedDemand": round(total_unserved, 1),
            "totalDemand": round(total_demand, 1),
            "incrementalCosts": round(total_costs, 1),
            "warmupCost": round(warmup_cost, 1),
            "sleepDisruption": round(sleep_disruption, 1),
            "isSleep": is_sleep_cand,
            "windows": windows
        }

    def compute_natural_baseline(self, state):
        now = self.parse_time(state["now"])
        quota = state.get("quota", {})
        profile = state.get("userProfile") or self.user_profile
        work_windows = profile.get("expectedWorkWindows", []) if profile else []

        traj = self.evaluate_trajectory_utility(("NO_WARMUP", None), state)
        served_demand, total_demand = traj["totalServedDemand"], traj["totalDemand"]
        curr_weight = self.get_time_weight(now, profile)

        # Invariant: baselineUtility must always equal NO_WARMUP trajectory served demand when demand exists
        if quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            b_type, b_util = "EXISTING_ACTIVE_WINDOW", served_demand
        elif curr_weight >= 0.7:
            b_type, b_util = "NATURAL_USE_NOW", served_demand
        elif total_demand > 0 or work_windows:
            b_type, b_util = "NEXT_NATURAL_USE", served_demand
        else:
            b_type, b_util = "NO_EXPECTED_WORK", 0.0

        return {
            "baselineType": b_type,
            "baselineUtility": b_util,
            "servedDemand": served_demand,
            "unservedDemand": traj["totalUnservedDemand"],
            "windows": traj["windows"],
            "trajectory": traj
        }

    def generate_candidates(self, state):
        now = self.parse_time(state["now"])
        candidates = set()
        end_time = now + timedelta(hours=self.horizon_hours)
        curr = now
        while curr <= end_time:
            candidates.add(curr)
            curr += timedelta(minutes=self.grid_step_min)

        candidates.add(now)
        quota = state.get("quota", {})
        if quota.get("resetAt"):
            reset_at = self.parse_time(quota["resetAt"])
            if reset_at >= now:
                candidates.add(reset_at + timedelta(seconds=60))

        profile = state.get("userProfile") or self.user_profile
        all_targets = [(profile["expectedPrimaryWorkStart"], True)] if profile.get("expectedPrimaryWorkStart") else []
        all_targets += [(w[0], False) for w in profile.get("expectedWorkWindows", [])]

        for start_str, is_prim in all_targets:
            h, m = map(int, start_str.split(":"))
            for day_offset in range(2):
                day_base = (now + timedelta(days=day_offset)).date()
                target_dt = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                cand_opt1 = target_dt - timedelta(minutes=self.window_duration_min)
                if cand_opt1 >= now:
                    candidates.add(cand_opt1)
                if is_prim and (cand_opt1 + timedelta(minutes=5)) >= now:
                    candidates.add(cand_opt1 + timedelta(minutes=5))

        return sorted([c for c in candidates if c >= now])

    def score_candidate(self, t, state):
        now = self.parse_time(state["now"])
        quota = state.get("quota", {})
        device = state.get("device", {})
        profile = state.get("userProfile") or self.user_profile

        if quota.get("weeklyBlocked"):
            return None, "Weekly quota blocked"
        if quota.get("fiveHourWindowStatus") == "BLOCKED":
            return None, "Quota window blocked"

        wake_available = device.get("wakeToRunAvailable", True)
        sleep_windows = profile.get("sleepWindows", [])
        is_sleep = self.is_in_sleep(t, sleep_windows)
        if is_sleep and not wake_available:
            return None, "WakeToRun unavailable during sleep"

        if quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            active_reset = self.parse_time(quota["resetAt"])
            if active_reset.tzinfo is None and now.tzinfo is not None:
                active_reset = active_reset.replace(tzinfo=now.tzinfo)
            if t < active_reset:
                return None, f"Inside active window until {active_reset.strftime('%H:%M')}"

        eval_res = self.evaluate_window_utility(t, profile, now)
        raw_work_coverage = eval_res["workCoverage"]
        boundary_alignment_score = eval_res["boundaryAlignment"]
        candidate_reset = t + timedelta(minutes=self.window_duration_min)
        cand_traj = self.evaluate_trajectory_utility(("WARMUP_AT", t), state)

        wake_benefit_score = 0.0
        sleep_disruption_penalty = self.p_sleep_base if is_sleep else 0.0
        warmup_cost_penalty = self.w_cost
        risk_penalty = 300.0 if quota.get("fiveHourWindowStatus") == "AMBIGUOUS" else 0.0

        w_now = self.get_time_weight(now, profile)
        immediate_work_bonus = 100.0 if (not is_sleep and (t - now).total_seconds() <= 300 and w_now >= 0.7) else (40.0 if (not is_sleep and (t - now).total_seconds() <= 300 and w_now >= 0.3) else 0.0)

        hours_away = max(0.0, (t - now).total_seconds() / 3600.0)
        temporal_discount = max(0.6, 1.0 - (hours_away * 0.02))

        base_score = (
            self.w_work * raw_work_coverage + self.w_align * boundary_alignment_score +
            self.w_wake * wake_benefit_score + immediate_work_bonus -
            sleep_disruption_penalty - warmup_cost_penalty - risk_penalty
        )
        total_score = base_score * temporal_discount

        return {
            "time": t.strftime("%Y-%m-%d %H:%M"),
            "candidate_dt": t,
            "expectedBoundary": candidate_reset.strftime("%Y-%m-%d %H:%M"),
            "totalScore": round(total_score, 1),
            "candidateUtility": cand_traj["totalServedDemand"],
            "servedDemand": cand_traj["totalServedDemand"],
            "unservedDemand": cand_traj["totalUnservedDemand"],
            "trajectoryWindows": cand_traj["windows"],
            "workCoverage": round(raw_work_coverage, 1),
            "boundaryAlignment": round(boundary_alignment_score, 1),
            "wakeBenefit": round(wake_benefit_score, 1),
            "immediateBonus": round(immediate_work_bonus, 1),
            "sleepDisruption": round(sleep_disruption_penalty, 1),
            "warmupCost": round(warmup_cost_penalty, 1),
            "incrementalCosts": cand_traj["incrementalCosts"],
            "risk": round(risk_penalty, 1),
            "isSleep": is_sleep
        }, "OK"

    def plan_next_action(self, state):
        now = self.parse_time(state["now"])
        if "userProfile" not in state and self.user_profile:
            state["userProfile"] = self.user_profile
        if "demandProfile" not in state and self.demand_profile:
            state["demandProfile"] = self.demand_profile

        baseline = self.compute_natural_baseline(state)
        b_type, b_util = baseline["baselineType"], baseline["baselineUtility"]
        inc_thresh = self.min_incremental_benefit

        candidates = self.generate_candidates(state)
        scored = []
        for cand in candidates:
            breakdown, reason = self.score_candidate(cand, state)
            if breakdown is not None:
                inc_benefit = round(breakdown["candidateUtility"] - b_util - breakdown["incrementalCosts"], 1)
                breakdown["baselineType"] = b_type
                breakdown["baselineUtility"] = b_util
                breakdown["incrementalBenefit"] = inc_benefit
                breakdown["incrementalThreshold"] = inc_thresh
                breakdown["baselineServedDemand"] = baseline["servedDemand"]
                breakdown["baselineUnservedDemand"] = baseline["unservedDemand"]
                breakdown["baselineWindows"] = baseline["windows"]
                scored.append(breakdown)

        scored.sort(key=lambda x: (x["incrementalBenefit"], x["totalScore"]), reverse=True)
        if not scored:
            return {
                "decision": "NO_ACTION", "baselineType": b_type, "baselineUtility": b_util,
                "candidateUtility": 0.0, "incrementalBenefit": round(0.0 - b_util, 1),
                "incrementalThreshold": inc_thresh, "score": round(0.0 - b_util, 1),
                "reason": "No valid candidates found", "topCandidates": []
            }

        for item in scored:
            if "candidate_dt" in item:
                del item["candidate_dt"]

        best = scored[0]

        # Gate 1: Absolute usefulness check
        if best["totalScore"] < self.min_useful_score:
            return {
                "decision": "NO_ACTION", "baselineType": b_type, "baselineUtility": b_util,
                "candidateUtility": best["candidateUtility"], "incrementalBenefit": best["incrementalBenefit"],
                "incrementalThreshold": inc_thresh, "score": best["totalScore"],
                "reason": f"Best score ({best['totalScore']}) below minimum useful threshold ({self.min_useful_score})",
                "breakdown": best, "topCandidates": scored[:5]
            }

        # Gate 2: Incremental Benefit Semantic Gate over NO_WARMUP baseline
        if best["incrementalBenefit"] <= inc_thresh:
            return {
                "decision": "NO_ACTION", "baselineType": b_type, "baselineUtility": b_util,
                "candidateUtility": best["candidateUtility"], "incrementalBenefit": best["incrementalBenefit"],
                "incrementalThreshold": inc_thresh, "score": best["incrementalBenefit"],
                "reason": (
                    f"Candidate utility ({best['candidateUtility']}) does not exceed "
                    f"natural baseline '{b_type}' ({b_util}) by threshold ({inc_thresh}) "
                    f"[incremental benefit: {best['incrementalBenefit']}]"
                ),
                "breakdown": best, "topCandidates": scored[:5]
            }

        best_time = self.parse_time(best["time"])
        if best_time.tzinfo is None and now.tzinfo is not None:
            best_time = best_time.replace(tzinfo=now.tzinfo)
        is_immediate = (best_time <= now + timedelta(minutes=5))

        return {
            "decision": "WARMUP_NOW" if is_immediate else "SCHEDULE_WARMUP",
            "baselineType": b_type, "baselineUtility": b_util,
            "candidateUtility": best["candidateUtility"], "incrementalBenefit": best["incrementalBenefit"],
            "incrementalThreshold": inc_thresh, "scheduledTime": best["time"],
            "expectedBoundary": best["expectedBoundary"], "score": best["totalScore"],
            "reason": f"Candidate delivers positive incremental benefit ({best['incrementalBenefit']}) over natural baseline '{b_type}' ({b_util})",
            "breakdown": best, "topCandidates": scored[:5]
        }

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Codex Warmup V2 Decision Engine")
    parser.add_argument("--now", type=str, required=True, help="Current ISO timestamp")
    parser.add_argument("--config", type=str, required=True, help="Path to config.json")
    parser.add_argument("--active-until", type=str, default=None, help="Active window expiry ISO timestamp")
    parser.add_argument("--weekly-exhausted", action="store_true", help="Whether weekly quota is exhausted")
    parser.add_argument("--window-status", type=str, default=None, choices=["ACTIVE", "INACTIVE", "AMBIGUOUS", "BLOCKED"], help="Window status")
    args = parser.parse_args()

    engine = DecisionEngine(config_path=args.config)
    window_status = args.window_status or ("ACTIVE" if args.active_until else "INACTIVE")

    state = {
        "now": args.now,
        "quota": {
            "resetAt": args.active_until,
            "weeklyBlocked": args.weekly_exhausted,
            "fiveHourWindowStatus": window_status,
            "windowDurationMinutes": 300
        },
        "device": {"wakeToRunAvailable": True, "state": "AWAKE"}
    }
    if "userProfile" in engine.config:
        state["userProfile"] = engine.config["userProfile"]
    if "demandProfile" in engine.config:
        state["demandProfile"] = engine.config["demandProfile"]

    result = engine.plan_next_action(state)
    print(json.dumps(result, ensure_ascii=False, indent=2))
