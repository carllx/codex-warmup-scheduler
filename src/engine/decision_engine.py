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
        self.p_sleep_2nd = self.weights.get("sleepDisruptionSecond", 40.0)
        self.p_sleep_3rd = self.weights.get("sleepDisruptionThird", 100.0)
        self.p_redundant = self.weights.get("redundantPenalty", 1000.0)
        self.min_useful_score = self.weights.get("minimumUsefulScore", 30.0)
        self.min_incremental_benefit = self.planning.get("minIncrementalBenefit", 15.0)

        self.horizon_hours = self.planning.get("horizonHours", 24)
        self.grid_step_min = self.planning.get("gridStepMinutes", 15)
        self.window_duration_min = self.planning.get("windowDurationMin", 300)

    def parse_time(self, t_str):
        if isinstance(t_str, datetime):
            return t_str
        return dateutil.parser.isoparse(t_str)

    def get_time_weight(self, dt, profile=None):
        t_hm = dt.strftime("%H:%M")
        if profile and profile.get("expectedWorkWindows") is not None:
            work_windows = profile.get("expectedWorkWindows", [])
            if not work_windows:
                # Rest day: all work weights 0
                return 0.0
            for w in work_windows:
                s, e = w[0], w[1]
                if s <= t_hm < e:
                    return 1.0
            # Outside work windows on work day
            sleep_windows = profile.get("sleepWindows", [])
            if self.is_in_sleep(dt, sleep_windows):
                return 0.0
            return 0.2

        for slot in self.user_value_weights:
            s, e = slot["start"], slot["end"]
            if s < e:
                if s <= t_hm < e:
                    return slot["weight"]
            else: # overnight
                if t_hm >= s or t_hm < e:
                    return slot["weight"]
        return 0.2

    def is_in_sleep(self, dt, sleep_windows):
        t_hm = dt.strftime("%H:%M")
        if not sleep_windows:
            return False
        if isinstance(sleep_windows[0], str):
            sleep_windows = [sleep_windows]
        for s, e in sleep_windows:
            if s < e:
                if s <= t_hm < e:
                    return True
            else:
                if t_hm >= s or t_hm < e:
                    return True
        return False

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

    def compute_natural_baseline(self, state):
        now = self.parse_time(state["now"])
        quota = state.get("quota", {})
        profile = state.get("userProfile", {})
        work_windows = profile.get("expectedWorkWindows", []) if profile else []

        if quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            active_reset = self.parse_time(quota["resetAt"])
            if active_reset > now:
                eval_res = self.evaluate_window_utility(active_reset, profile, now)
                return {
                    "baselineType": "EXISTING_ACTIVE_WINDOW",
                    "baselineTime": active_reset.strftime("%Y-%m-%d %H:%M"),
                    "baselineUtility": round(eval_res["utility"], 1),
                    "workCoverage": round(eval_res["workCoverage"], 1),
                    "boundaryAlignment": round(eval_res["boundaryAlignment"], 1)
                }

        # Natural baseline is the sequence of natural usage without artificial warmup.
        # If candidate is in the future (e.g. overnight wake for tomorrow's shift),
        # the baseline against which that candidate must prove incremental benefit is the natural start of that work window!
        # If user is currently in a work window, natural use is happening now, BUT for candidates scheduled in the future,
        # we evaluate them against the future natural baseline.
        next_work_start = None
        for day_offset in range(3):
            day_base = (now + timedelta(days=day_offset)).date()
            for w in work_windows:
                h, m = map(int, w[0].split(":"))
                w_start_dt = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                if w_start_dt >= now:
                    if next_work_start is None or w_start_dt < next_work_start:
                        next_work_start = w_start_dt

        curr_weight = self.get_time_weight(now, profile)
        if curr_weight >= 0.7:
            eval_now = self.evaluate_window_utility(now, profile, now)
            # Natural use happening now also has the immediate work urgency benefit without artificial warmup cost!
            now_imm_bonus = 100.0 if curr_weight >= 0.7 else 40.0
            base_now_util = eval_now["utility"] + now_imm_bonus
            eval_next = self.evaluate_window_utility(next_work_start, profile, now) if next_work_start else None
            return {
                "baselineType": "NATURAL_USE_NOW",
                "baselineTime": now.strftime("%Y-%m-%d %H:%M"),
                "baselineUtility": round(base_now_util, 1),
                "nextNaturalStart": next_work_start.strftime("%Y-%m-%d %H:%M") if next_work_start else None,
                "nextNaturalUtility": round(eval_next["utility"], 1) if eval_next else 0.0,
                "workCoverage": round(eval_now["workCoverage"], 1),
                "boundaryAlignment": round(eval_now["boundaryAlignment"], 1)
            }

        if not work_windows:
            return {
                "baselineType": "NO_EXPECTED_WORK",
                "baselineTime": None,
                "baselineUtility": 0.0,
                "nextNaturalStart": None,
                "nextNaturalUtility": 0.0,
                "workCoverage": 0.0,
                "boundaryAlignment": 0.0
            }

        if next_work_start is not None:
            eval_res = self.evaluate_window_utility(next_work_start, profile, now)
            return {
                "baselineType": "NEXT_NATURAL_USE",
                "baselineTime": next_work_start.strftime("%Y-%m-%d %H:%M"),
                "baselineUtility": round(eval_res["utility"], 1),
                "nextNaturalStart": next_work_start.strftime("%Y-%m-%d %H:%M"),
                "nextNaturalUtility": round(eval_res["utility"], 1),
                "workCoverage": round(eval_res["workCoverage"], 1),
                "boundaryAlignment": round(eval_res["boundaryAlignment"], 1)
            }

        return {
            "baselineType": "NO_EXPECTED_WORK",
            "baselineTime": None,
            "baselineUtility": 0.0,
            "workCoverage": 0.0,
            "boundaryAlignment": 0.0
        }

    def generate_candidates(self, state):
        now = self.parse_time(state["now"])
        candidates = set()

        # 1. grid points across horizon
        end_time = now + timedelta(hours=self.horizon_hours)
        curr = now
        while curr <= end_time:
            candidates.add(curr)
            curr += timedelta(minutes=self.grid_step_min)

        # 2. Add special points
        # now
        candidates.add(now)

        # known resetAt + 60s
        quota = state.get("quota", {})
        if quota.get("resetAt"):
            reset_at = self.parse_time(quota["resetAt"])
            if reset_at >= now:
                candidates.add(reset_at + timedelta(seconds=60))

        # Target work starts - 300m
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

        # Filter out candidates strictly before now
        valid_candidates = sorted([c for c in candidates if c >= now])
        return valid_candidates

    def score_candidate(self, t, state):
        now = self.parse_time(state["now"])
        quota = state.get("quota", {})
        device = state.get("device", {})
        profile = state.get("userProfile", {})
        history = state.get("history", {})

        # Validation Checks & Hard Exclusions
        if quota.get("weeklyBlocked"):
            return None, "Weekly quota blocked"

        if quota.get("fiveHourWindowStatus") == "BLOCKED":
            return None, "Quota window blocked"

        wake_available = device.get("wakeToRunAvailable", True)
        sleep_windows = profile.get("sleepWindows", [])
        is_sleep = self.is_in_sleep(t, sleep_windows)

        if is_sleep and not wake_available:
            return None, "WakeToRun unavailable during sleep"

        # Check Redundant Penalty (inside existing active window)
        active_reset = None
        if quota.get("fiveHourWindowStatus") == "ACTIVE" and quota.get("resetAt"):
            active_reset = self.parse_time(quota["resetAt"])
            if t < active_reset:
                # Inside active window
                return None, f"Inside active window until {active_reset.strftime('%H:%M')}"

        # 1. Work Coverage & 2. Boundary Alignment via evaluate_window_utility
        eval_res = self.evaluate_window_utility(t, profile, now)
        raw_work_coverage = eval_res["workCoverage"]
        boundary_alignment_score = eval_res["boundaryAlignment"]
        best_align_score = eval_res["bestAlignScore"]
        candidate_reset = t + timedelta(minutes=self.window_duration_min)

        # 3. WakeBenefitScore (0-60)
        # 3. WakeBenefitScore:
        # Pre-work sleep wakeups do NOT generate artificial utility over natural morning start.
        # Wake benefit is 0.0 unless there is a concrete daytime benefit that natural morning start cannot provide.
        wake_benefit_score = 0.0

        # 4. SleepDisruptionPenalty
        sleep_disruption_penalty = 0.0
        if is_sleep:
            # penalize sleep disruption
            sleep_disruption_penalty = self.p_sleep_base

        # 5. WarmupCostPenalty
        warmup_cost_penalty = self.w_cost

        # 6. RiskPenalty
        risk_penalty = 0.0
        if quota.get("fiveHourWindowStatus") == "AMBIGUOUS":
            risk_penalty += 300.0

        # 3.5 Immediate Work Urgency Bonus
        immediate_work_bonus = 0.0
        if not is_sleep and (t - now).total_seconds() <= 300: # within 5 min of now
            curr_weight = self.get_time_weight(now, profile)
            if curr_weight >= 0.7:
                immediate_work_bonus = 100.0
            elif curr_weight >= 0.3:
                immediate_work_bonus = 40.0

        # Total Score with Temporal Discounting
        # In rolling horizon, an immediate benefit is more certain than an action 20 hours away
        hours_away = max(0.0, (t - now).total_seconds() / 3600.0)
        temporal_discount = max(0.6, 1.0 - (hours_away * 0.02)) # 2% discount per hour into future, capped at 0.6

        base_score = (
            self.w_work * raw_work_coverage +
            self.w_align * boundary_alignment_score +
            self.w_wake * wake_benefit_score +
            immediate_work_bonus -
            sleep_disruption_penalty -
            warmup_cost_penalty -
            risk_penalty
        )
        total_score = base_score * temporal_discount

        breakdown = {
            "time": t.strftime("%Y-%m-%d %H:%M"),
            "candidate_dt": t,
            "expectedBoundary": candidate_reset.strftime("%Y-%m-%d %H:%M"),
            "totalScore": round(total_score, 1),
            "workCoverage": round(raw_work_coverage, 1),
            "boundaryAlignment": round(boundary_alignment_score, 1),
            "wakeBenefit": round(wake_benefit_score, 1),
            "immediateBonus": round(immediate_work_bonus, 1),
            "sleepDisruption": round(sleep_disruption_penalty, 1),
            "warmupCost": round(warmup_cost_penalty, 1),
            "risk": round(risk_penalty, 1),
            "isSleep": is_sleep
        }
        return breakdown, "OK"

    def plan_next_action(self, state):
        now = self.parse_time(state["now"])
        baseline = self.compute_natural_baseline(state)
        b_type = baseline["baselineType"]
        b_util = baseline["baselineUtility"]
        inc_thresh = self.min_incremental_benefit

        candidates = self.generate_candidates(state)
        scored_candidates = []

        for cand in candidates:
            breakdown, reason = self.score_candidate(cand, state)
            if breakdown is not None:
                cand_dt = self.parse_time(breakdown["time"])
                if cand_dt.tzinfo is None and now.tzinfo is not None:
                    cand_dt = cand_dt.replace(tzinfo=now.tzinfo)

                # Determine effective baseline for this candidate
                # If candidate is scheduled for the future (> 60m away) and a next natural work window exists,
                # the relevant baseline is the utility of starting at that next natural work window.
                effective_b_util = b_util
                effective_b_type = b_type
                if (cand_dt - now).total_seconds() > 3600 and baseline.get("nextNaturalUtility") is not None:
                    effective_b_util = baseline["nextNaturalUtility"]
                    effective_b_type = "NEXT_NATURAL_USE"

                cand_util = breakdown["totalScore"]
                inc_benefit = round(cand_util - effective_b_util, 1)
                breakdown["baselineType"] = effective_b_type
                breakdown["baselineUtility"] = effective_b_util
                breakdown["candidateUtility"] = cand_util
                breakdown["incrementalBenefit"] = inc_benefit
                breakdown["incrementalThreshold"] = inc_thresh
                scored_candidates.append(breakdown)

        scored_candidates.sort(key=lambda x: x["incrementalBenefit"], reverse=True)
        if not scored_candidates:
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

        # remove candidate_dt before returning to keep output clean and json serializable
        for item in scored_candidates:
            if "candidate_dt" in item:
                del item["candidate_dt"]

        best = scored_candidates[0]

        # Gate 1: Absolute usefulness check
        if best["totalScore"] < self.min_useful_score:
            return {
                "decision": "NO_ACTION",
                "baselineType": b_type,
                "baselineUtility": b_util,
                "candidateUtility": best["candidateUtility"],
                "incrementalBenefit": best["incrementalBenefit"],
                "incrementalThreshold": inc_thresh,
                "score": best["incrementalBenefit"],
                "reason": f"Best score ({best['totalScore']}) below minimum useful threshold ({self.min_useful_score})",
                "breakdown": best,
                "topCandidates": scored_candidates[:5]
            }

        # Gate 2: Incremental Benefit Semantic Gate over NO_WARMUP baseline
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
                "topCandidates": scored_candidates[:5]
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
            "topCandidates": scored_candidates[:5]
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
