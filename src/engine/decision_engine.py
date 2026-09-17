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
        primary_start = profile.get("expectedPrimaryWorkStart")
        if primary_start:
            # Anchor to today or tomorrow's primary work start
            for day_offset in range(2):
                day_base = (now + timedelta(days=day_offset)).date()
                h, m = map(int, primary_start.split(":"))
                target_dt = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                cand_opt1 = target_dt - timedelta(minutes=self.window_duration_min)
                cand_opt2 = cand_opt1 + timedelta(minutes=5)
                if cand_opt1 >= now:
                    candidates.add(cand_opt1)
                if cand_opt2 >= now:
                    candidates.add(cand_opt2)

        # Secondary work windows
        for w in profile.get("expectedWorkWindows", []):
            start_str = w[0]
            for day_offset in range(2):
                day_base = (now + timedelta(days=day_offset)).date()
                h, m = map(int, start_str.split(":"))
                sec_target = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                cand = sec_target - timedelta(minutes=self.window_duration_min)
                if cand >= now:
                    candidates.add(cand)

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

        # 1. WorkCoverageScore (0-100)
        # 5h window from t to t + 300m
        window_end = t + timedelta(minutes=self.window_duration_min)
        step_min = 15
        total_steps = self.window_duration_min // step_min
        step_weights = []
        step_curr = t
        while step_curr < window_end:
            step_weights.append(self.get_time_weight(step_curr, profile))
            step_curr += timedelta(minutes=step_min)
        
        avg_weight = sum(step_weights) / len(step_weights) if step_weights else 0
        raw_work_coverage = avg_weight * 100.0

        # 2. BoundaryAlignmentScore (0-100)
        # candidate reset boundary = t + 300m
        candidate_reset = t + timedelta(minutes=self.window_duration_min)
        primary_start_str = profile.get("expectedPrimaryWorkStart")
        
        best_align_score = 0.0
        if primary_start_str:
            # find closest primary work start
            for day_offset in range(3):
                day_base = (now + timedelta(days=day_offset)).date()
                h, m = map(int, primary_start_str.split(":"))
                target_dt = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                diff_min = abs((candidate_reset - target_dt).total_seconds()) / 60.0
                
                if diff_min <= 5:
                    align = 100.0
                elif diff_min <= 15:
                    align = 90.0
                elif diff_min <= 30:
                    align = 75.0
                elif diff_min <= 60:
                    align = 50.0
                elif diff_min <= 120:
                    align = 20.0
                else:
                    align = 0.0
                
                if align > best_align_score:
                    best_align_score = align

        # Secondary work windows boundary alignment
        best_sec_align = 0.0
        for w in profile.get("expectedWorkWindows", []):
            start_str = w[0]
            for day_offset in range(3):
                day_base = (now + timedelta(days=day_offset)).date()
                h, m = map(int, start_str.split(":"))
                sec_target = datetime(day_base.year, day_base.month, day_base.day, h, m, tzinfo=now.tzinfo)
                diff_min = abs((candidate_reset - sec_target).total_seconds()) / 60.0
                if diff_min <= 15:
                    sec_align = 40.0
                elif diff_min <= 30:
                    sec_align = 25.0
                elif diff_min <= 60:
                    sec_align = 10.0
                else:
                    sec_align = 0.0
                if sec_align > best_sec_align:
                    best_sec_align = sec_align

        boundary_alignment_score = max(best_align_score, best_sec_align)

        # 3. WakeBenefitScore (0-60)
        # Granted only if warmup is during sleep AND reset boundary improves daytime start
        wake_benefit_score = 0.0
        if is_sleep and wake_available:
            if best_align_score >= 90.0:
                wake_benefit_score = 60.0
            elif best_align_score >= 75.0:
                wake_benefit_score = 45.0
            elif best_align_score >= 50.0:
                wake_benefit_score = 25.0
            else:
                wake_benefit_score = 0.0

        # 4. SleepDisruptionPenalty
        sleep_disruption_penalty = 0.0
        if is_sleep:
            # check how many wakes have occurred or planned in this sleep period
            sleep_disruption_penalty = self.p_sleep_base

        # 5. WarmupCostPenalty
        warmup_cost_penalty = self.w_cost

        # 6. RiskPenalty
        risk_penalty = 0.0
        if quota.get("fiveHourWindowStatus") == "AMBIGUOUS":
            risk_penalty += 300.0

        # 3.5 Immediate Work Urgency Bonus
        # If user is currently awake, not in sleep, and candidate is immediate (now),
        # and work window is currently active or starting soon (within 60m),
        # prioritize taking immediate action over waiting for tomorrow's sleep wake
        immediate_work_bonus = 0.0
        if not is_sleep and (t - now).total_seconds() <= 300: # within 5 min of now
            curr_weight = self.get_time_weight(now, profile)
            if curr_weight >= 0.7:
                # Work has already started or is starting right now!
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
        candidates = self.generate_candidates(state)
        scored_candidates = []

        for cand in candidates:
            breakdown, reason = self.score_candidate(cand, state)
            if breakdown is not None:
                scored_candidates.append(breakdown)

        scored_candidates.sort(key=lambda x: x["totalScore"], reverse=True)

        now = self.parse_time(state["now"])
        if not scored_candidates:
            return {
                "decision": "NO_ACTION",
                "reason": "No valid candidates found",
                "topCandidates": []
            }

        # remove candidate_dt before returning to keep output clean and json serializable
        for item in scored_candidates:
            if "candidate_dt" in item:
                del item["candidate_dt"]

        best = scored_candidates[0]
        if best["totalScore"] < self.min_useful_score:
            return {
                "decision": "NO_ACTION",
                "reason": f"Best score ({best['totalScore']}) below minimum useful threshold ({self.min_useful_score})",
                "topCandidates": scored_candidates[:5]
            }

        best_time = self.parse_time(best["time"])
        if best_time.tzinfo is None and now.tzinfo is not None:
            best_time = best_time.replace(tzinfo=now.tzinfo)
        is_immediate = (best_time <= now + timedelta(minutes=5))

        return {
            "decision": "WARMUP_NOW" if is_immediate else "SCHEDULE_WARMUP",
            "scheduledTime": best["time"],
            "expectedBoundary": best["expectedBoundary"],
            "score": best["totalScore"],
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
