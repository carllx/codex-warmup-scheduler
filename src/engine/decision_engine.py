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
        if profile and profile.get("expectedWorkWindows") is not None:
            work_windows = profile.get("expectedWorkWindows", [])
            if not work_windows:
                return 0.0
            if any((s <= t_hm < e) if s < e else (t_hm >= s or t_hm < e) for s, e in work_windows):
                return 1.0
            return 0.0 if self.is_in_sleep(dt, profile.get("sleepWindows", [])) else 0.2

        for slot in self.user_value_weights:
            s, e = slot["start"], slot["end"]
            if (s <= t_hm < e) if s < e else (t_hm >= s or t_hm < e):
                return slot["weight"]
        return 0.2

    def evaluate_window_utility(self, t, profile, now=None):
        if now is None:
            now = t
        window_end = t + timedelta(minutes=self.window_duration_min)
        step_min = 15
        step_weights = []
        step_curr = t
        while step_curr < window_end:
            step_weights.append(self.get_time_weight(step_curr, profile))
            step_curr += timedelta(minutes=step_min)
        raw_work_coverage = (sum(step_weights) / len(step_weights) * 100.0) if step_weights else 0.0

        candidate_reset = t + timedelta(minutes=self.window_duration_min)
        best_align_score = 0.0
        primary_start_str = profile.get("expectedPrimaryWorkStart") if profile else None
        all_starts = []
        if primary_start_str:
            all_starts.append((primary_start_str, True))
        for w in (profile.get("expectedWorkWindows", []) if profile else []):
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

        boundary_alignment_score = best_align_score
        utility = self.w_work * raw_work_coverage + self.w_align * boundary_alignment_score
        return {
            "utility": utility,
            "workCoverage": raw_work_coverage,
            "boundaryAlignment": boundary_alignment_score,
            "bestAlignScore": best_align_score
        }

    def evaluate_trajectory_utility(self, policy_action, state):
        """
        Simulates full state trajectory over horizon [now, now + horizon].
        Models:
        - Active quota window from prior usage (resetAt)
        - Artificial warmup at t_cand (WARMUP_AT)
        - Natural usage demand (from demandProfile or expectedWorkWindows)
        - Window resets and post-reset natural usage
        - Quota window capacity (default 100) and warmup consumption (default 1)
        - Served demand vs unserved demand, incremental costs
        """
        now = self.parse_time(state["now"])
        quota = state.get("quota", {})
        profile = state.get("userProfile", {})
        work_windows = profile.get("expectedWorkWindows", []) if profile else []
        sleep_windows = profile.get("sleepWindows", []) if profile else []

        demand_profile = state.get("demandProfile") or profile.get("demandProfile") or self.config.get("demandProfile")

        action_type, t_cand = policy_action
        warmup_cost = 0.0
        sleep_disruption = 0.0
        is_sleep_cand = False

        if action_type == "WARMUP_AT" and t_cand is not None:
            warmup_cost = self.w_cost
            is_sleep_cand = self.is_in_sleep(t_cand, sleep_windows)
            if is_sleep_cand:
                sleep_disruption = self.p_sleep_base

        active_until = None
        remaining_capacity = 0.0

        if quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            reset_at = self.parse_time(quota["resetAt"])
            if reset_at.tzinfo is None and now.tzinfo is not None:
                reset_at = reset_at.replace(tzinfo=now.tzinfo)
            if reset_at > now:
                active_until = reset_at
                remaining_capacity = self.window_capacity

        windows = []
        if active_until:
            windows.append({
                "start": now.strftime("%Y-%m-%d %H:%M"),
                "end": active_until.strftime("%Y-%m-%d %H:%M"),
                "source": "INITIAL_ACTIVE",
                "capacity": remaining_capacity
            })

        curr = now
        end_time = now + timedelta(hours=self.horizon_hours)
        step = timedelta(minutes=self.grid_step_min)

        total_demand, total_served, total_unserved = 0.0, 0.0, 0.0

        while curr < end_time:
            # Check window expiration / reset
            if active_until is not None and curr >= active_until:
                active_until = None
                remaining_capacity = 0.0

            # Artificial warmup trigger
            if action_type == "WARMUP_AT" and t_cand is not None:
                if curr <= t_cand < curr + step:
                    if active_until is None:
                        active_until = t_cand + timedelta(minutes=self.window_duration_min)
                        remaining_capacity = max(0.0, self.window_capacity - self.warmup_consumption)
                        windows.append({
                            "start": t_cand.strftime("%Y-%m-%d %H:%M"),
                            "end": active_until.strftime("%Y-%m-%d %H:%M"),
                            "source": "ARTIFICIAL_WARMUP",
                            "capacity": remaining_capacity
                        })

            # Determine demand at this time step
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
            else:
                if any((w[0] <= curr_hm < w[1]) if w[0] < w[1] else (curr_hm >= w[0] or curr_hm < w[1]) for w in work_windows):
                    step_demand = 2.0

            total_demand += step_demand

            # Natural use trigger: demand without active window opens fresh window
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

                # Serve demand from active window capacity
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
        profile = state.get("userProfile", {})
        work_windows = profile.get("expectedWorkWindows", []) if profile else []

        traj = self.evaluate_trajectory_utility(("NO_WARMUP", None), state)
        curr_weight = self.get_time_weight(now, profile)

        if not work_windows:
            b_type = "NO_EXPECTED_WORK"
            b_util = 0.0
        elif quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            b_type = "EXISTING_ACTIVE_WINDOW"
            b_util = traj["totalServedDemand"]
        elif curr_weight >= 0.7:
            b_type = "NATURAL_USE_NOW"
            b_util = traj["totalServedDemand"]
        else:
            b_type = "NEXT_NATURAL_USE"
            b_util = traj["totalServedDemand"]

        return {
            "baselineType": b_type,
            "baselineUtility": b_util,
            "servedDemand": traj["totalServedDemand"],
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

        profile = state.get("userProfile", {})
        all_targets = []
        primary_start = profile.get("expectedPrimaryWorkStart")
        if primary_start:
            all_targets.append((primary_start, True))
        for w in profile.get("expectedWorkWindows", []):
            all_targets.append((w[0], False))

        for start_str, is_prim in all_targets:
            for day_offset in range(2):
                day_base = (now + timedelta(days=day_offset)).date()
                h, m = map(int, start_str.split(":"))
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
        profile = state.get("userProfile", {})

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
        sleep_disruption_penalty = self.p_sleep_base if is_sleep else 0.0
        warmup_cost_penalty = self.w_cost

        base_score = (
            self.w_work * raw_work_coverage +
            self.w_align * boundary_alignment_score -
            sleep_disruption_penalty -
            warmup_cost_penalty
        )

        return {
            "time": t.strftime("%Y-%m-%d %H:%M"),
            "candidate_dt": t,
            "expectedBoundary": candidate_reset.strftime("%Y-%m-%d %H:%M"),
            "totalScore": round(base_score, 1),
            "candidateUtility": cand_traj["totalServedDemand"],
            "servedDemand": cand_traj["totalServedDemand"],
            "unservedDemand": cand_traj["totalUnservedDemand"],
            "trajectoryWindows": cand_traj["windows"],
            "workCoverage": round(raw_work_coverage, 1),
            "boundaryAlignment": round(boundary_alignment_score, 1),
            "wakeBenefit": 0.0,
            "immediateBonus": 0.0,
            "sleepDisruption": sleep_disruption_penalty,
            "warmupCost": warmup_cost_penalty,
            "incrementalCosts": cand_traj["incrementalCosts"],
            "risk": 0.0,
            "isSleep": is_sleep
        }, "OK"

    def plan_next_action(self, state):
        now = self.parse_time(state["now"])
        baseline = self.compute_natural_baseline(state)
        b_type = baseline["baselineType"]
        b_util = baseline["baselineUtility"]
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
                "decision": "NO_ACTION",
                "baselineType": b_type,
                "baselineUtility": b_util,
                "candidateUtility": 0.0,
                "incrementalBenefit": round(0.0 - b_util, 1),
                "incrementalThreshold": inc_thresh,
                "score": round(0.0 - b_util, 1),
                "reason": "No valid candidates found",
                "topCandidates": []
            }

        for item in scored:
            if "candidate_dt" in item:
                del item["candidate_dt"]

        best = scored[0]

        if best["incrementalBenefit"] <= inc_thresh:
            return {
                "decision": "NO_ACTION",
                "baselineType": b_type,
                "baselineUtility": b_util,
                "candidateUtility": best["candidateUtility"],
                "incrementalBenefit": best["incrementalBenefit"],
                "incrementalThreshold": inc_thresh,
                "score": best["incrementalBenefit"],
                "reason": (
                    f"Candidate utility ({best['candidateUtility']}) does not exceed "
                    f"natural baseline '{b_type}' ({b_util}) by threshold ({inc_thresh}) "
                    f"[incremental benefit: {best['incrementalBenefit']}]"
                ),
                "breakdown": best,
                "topCandidates": scored[:5]
            }

        best_time = self.parse_time(best["time"])
        if best_time.tzinfo is None and now.tzinfo is not None:
            best_time = best_time.replace(tzinfo=now.tzinfo)
        is_immediate = (best_time <= now + timedelta(minutes=5))

        return {
            "decision": "WARMUP_NOW" if is_immediate else "SCHEDULE_WARMUP",
            "baselineType": b_type,
            "baselineUtility": b_util,
            "candidateUtility": best["candidateUtility"],
            "incrementalBenefit": best["incrementalBenefit"],
            "incrementalThreshold": inc_thresh,
            "scheduledTime": best["time"],
            "expectedBoundary": best["expectedBoundary"],
            "score": best["totalScore"],
            "reason": (
                f"Candidate delivers positive incremental benefit ({best['incrementalBenefit']}) "
                f"over natural baseline '{b_type}' ({b_util})"
            ),
            "breakdown": best,
            "topCandidates": scored[:5]
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
    
    window_status = args.window_status
    if not window_status:
        window_status = "ACTIVE" if args.active_until else "INACTIVE"

    state = {
        "now": args.now,
        "quota": {
            "resetAt": args.active_until,
            "weeklyBlocked": args.weekly_exhausted,
            "fiveHourWindowStatus": window_status,
            "windowDurationMinutes": 300
        },
        "device": {
            "wakeToRunAvailable": True,
            "state": "AWAKE"
        }
    }
    result = engine.plan_next_action(state)
    print(json.dumps(result, ensure_ascii=False, indent=2))
