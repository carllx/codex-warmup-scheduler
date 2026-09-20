"""
tests/test_readiness_policy.py
Dedicated regression and verification suite for the Readiness / Optionality Policy.
Asserts:
- S6 Positive: UNKNOWN demand + readiness policy -> SCHEDULE_WARMUP at 06:00, 180m advance
- S6 Negative: boundary-at-start (S == B) rejected -> NO_ACTION
- Independence regression: CALIBRATED demand without capacity win still schedules via READINESS_BENEFIT
- Hard safety constraints: weeklyBlocked, BLOCKED, AMBIGUOUS, wake-in-sleep, active-window enclosure
- NO_DEMAND preservation: unconditionally yields NO_ACTION even if readiness policy is active
- Malformed readinessPolicy handling: fail-closed to UNKNOWN / NO_ACTION
- CLI Integration: production CLI entry point with readiness policy
"""

import os
import sys
import json
import subprocess
import unittest

# Path setup
current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(current_dir)
sys.path.insert(0, os.path.join(project_root, "src", "engine"))

from decision_engine import DecisionEngine

class TestReadinessPolicy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        config_file = os.path.join(project_root, "config", "default.json")
        with open(config_file, "r", encoding="utf-8") as f:
            cls.config = json.load(f)
        cls.engine = DecisionEngine(cls.config)

    def test_s6_readiness_positive_unknown_demand(self):
        """
        S6 Positive — Readiness / Optionality Benefit:
        now = 04:00, quota = INACTIVE, demandProfile = UNKNOWN.
        readinessPolicy:
          enabled = True, primaryUseStart = "09:00", preferredReset = "11:00"
        Expected:
          candidate warmup = 06:00
          expected boundary = 11:00
          natural reset if first use starts 09:00 = 14:00
          resetAdvanceMinutes = 180.0
          decision = SCHEDULE_WARMUP
          decisionReason = READINESS_BENEFIT
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "demandProfile": {"status": "UNKNOWN", "bands": []},
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "11:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertEqual(plan["decisionReason"], "READINESS_BENEFIT")
        self.assertIn("06:00", plan["scheduledTime"])
        self.assertIn("11:00", plan["expectedBoundary"])
        self.assertIn("14:00", plan["naturalReset"])
        self.assertEqual(plan["resetAdvanceMinutes"], 180.0)
        self.assertEqual(plan["candidateUtility"], 0.0)
        self.assertEqual(plan["incrementalBenefit"], 0.0)
        self.assertGreater(plan["score"], 30.0)

    def test_s6_negative_boundary_at_start_rejected(self):
        """
        S6 Negative — boundary-at-start rejected (Correction 3):
        primaryUseStart = 09:00, preferredReset = 09:00.
        Candidate warmup = 04:00 produces reset boundary B = 09:00.
        Because S == B (09:00 == 09:00) rather than S < B, this provides zero
        meaningful readiness advance and must NOT be a readiness win.
        Expected: NO_ACTION.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "demandProfile": {"status": "UNKNOWN", "bands": []},
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "09:00"
            }
        }
        candidates = self.engine.generate_candidates(state)
        cand_04_times = [c.strftime("%H:%M") for c in candidates]
        self.assertIn("04:00", cand_04_times)

        cand_04_dt = self.engine.parse_time("2026-09-18T04:00:00+08:00")
        eval_res = self.engine.evaluate_readiness_benefit(cand_04_dt, state)
        self.assertFalse(eval_res["isMeaningful"])
        self.assertEqual(eval_res["resetAdvanceMinutes"], 0.0)

        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")

    def test_readiness_calibrated_demand_independent_win(self):
        """
        Independence regression:
        Proves CALIBRATED demand does not disable Readiness.
        Scenario:
        - demandProfile = CALIBRATED with low demand (40.0 in 09:00-12:30).
        - Capacity evaluation: natural baseline serves 40.0; warmup candidate also serves 40.0.
          Incremental benefit = 40.0 - 40.0 - 5.0 (cost) = -5.0 <= 15.0 threshold.
          -> hasCapacityWin is False!
        - Readiness evaluation:
          primaryUseStart = 09:00, preferredReset = 11:00.
          Candidate 06:00 yields resetAdvanceMinutes = 180.0 > 0.
          -> hasReadinessWin is True!
        Expected:
          decision = SCHEDULE_WARMUP
          decisionReason = READINESS_BENEFIT
          resetAdvanceMinutes = 180.0
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "userProfile": {
                "expectedWorkWindows": [["09:00", "12:30"]],
                "expectedPrimaryWorkStart": "09:00",
                "sleepWindows": [["01:30", "08:00"]]
            },
            "demandProfile": {
                "status": "CALIBRATED",
                "bands": [
                    {"start": "09:00", "end": "12:30", "demand": 40.0}
                ]
            },
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "11:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertEqual(plan["decisionReason"], "READINESS_BENEFIT")
        self.assertIn("06:00", plan["scheduledTime"])
        self.assertIn("11:00", plan["expectedBoundary"])
        self.assertIn("14:00", plan["naturalReset"])
        self.assertEqual(plan["resetAdvanceMinutes"], 180.0)
        self.assertFalse(plan["breakdown"]["hasCapacityWin"])
        self.assertTrue(plan["breakdown"]["hasReadinessWin"])
        self.assertLessEqual(plan["incrementalBenefit"], plan["incrementalThreshold"])

    def test_readiness_safety_hard_gates(self):
        """
        Safety constraints:
        - weeklyBlocked -> NO_ACTION
        - fiveHourWindowStatus == 'BLOCKED' -> NO_ACTION
        - fiveHourWindowStatus == 'AMBIGUOUS' -> NO_ACTION
        - wakeToRunAvailable == False during sleep -> NO_ACTION
        - inside active window -> NO_ACTION
        """
        base_state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "userProfile": {
                "sleepWindows": [["01:30", "08:00"]]
            },
            "demandProfile": {"status": "UNKNOWN", "bands": []},
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "11:00"
            }
        }

        # 1. weeklyBlocked
        s_weekly = json.loads(json.dumps(base_state))
        s_weekly["quota"]["weeklyBlocked"] = True
        self.assertEqual(self.engine.plan_next_action(s_weekly)["decision"], "NO_ACTION")

        # 2. BLOCKED window
        s_blocked = json.loads(json.dumps(base_state))
        s_blocked["quota"]["fiveHourWindowStatus"] = "BLOCKED"
        self.assertEqual(self.engine.plan_next_action(s_blocked)["decision"], "NO_ACTION")

        # 3. AMBIGUOUS window
        s_ambig = json.loads(json.dumps(base_state))
        s_ambig["quota"]["fiveHourWindowStatus"] = "AMBIGUOUS"
        self.assertEqual(self.engine.plan_next_action(s_ambig)["decision"], "NO_ACTION")

        # 4. wakeToRunAvailable False during sleep
        s_no_wake = json.loads(json.dumps(base_state))
        s_no_wake["device"]["wakeToRunAvailable"] = False
        self.assertEqual(self.engine.plan_next_action(s_no_wake)["decision"], "NO_ACTION")

        # 5. Inside active window until 08:00
        s_active = json.loads(json.dumps(base_state))
        s_active["quota"]["fiveHourWindowStatus"] = "ACTIVE"
        s_active["quota"]["resetAt"] = "2026-09-18T08:00:00+08:00"
        self.assertEqual(self.engine.plan_next_action(s_active)["decision"], "NO_ACTION")

    def test_readiness_no_demand_status_yields_no_action(self):
        """
        Correction 2:
        NO_DEMAND status must unconditionally return NO_ACTION / NO_EXPECTED_WORK,
        even if readinessPolicy is enabled.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "demandProfile": {"status": "NO_DEMAND"},
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "11:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "NO_EXPECTED_WORK")

    def test_readiness_malformed_policy_fails_closed(self):
        """
        Malformed readinessPolicy configurations must fail-closed to UNKNOWN / NO_ACTION.
        """
        malformed_policies = [
            {"enabled": True, "primaryUseStart": "invalid"},
            {"enabled": True, "primaryUseStart": "09:00", "preferredReset": "invalid"},
            {"enabled": "yes", "primaryUseStart": "09:00", "preferredReset": "11:00"},
            "not-a-dict",
            {"enabled": False, "primaryUseStart": "09:00", "preferredReset": "11:00"}
        ]
        for bad_pol in malformed_policies:
            state = {
                "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
                "now": "2026-09-18T04:00:00+08:00",
                "quota": {
                    "resetAt": None,
                    "weeklyBlocked": False,
                    "fiveHourWindowStatus": "INACTIVE",
                    "windowDurationMinutes": 300
                },
                "demandProfile": {"status": "UNKNOWN", "bands": []},
                "readinessPolicy": bad_pol
            }
            plan = self.engine.plan_next_action(state)
            self.assertEqual(plan["decision"], "NO_ACTION")
            self.assertEqual(plan["baselineType"], "DEMAND_UNKNOWN")

    def test_cli_readiness_policy_execution(self):
        """
        CLI integration test: runs decision_engine.py with temporary config enabling readinessPolicy.
        Verifies explainable readiness fields through the production CLI entry point.
        """
        import tempfile
        script_path = os.path.join(project_root, "src", "engine", "decision_engine.py")
        test_cfg = dict(self.config)
        test_cfg["readinessPolicy"] = {
            "enabled": True,
            "primaryUseStart": "09:00",
            "preferredReset": "11:00"
        }
        test_cfg["demandProfile"] = {"status": "UNKNOWN", "bands": []}

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            json.dump(test_cfg, f)
            temp_cfg_path = f.name

        try:
            cmd = [
                sys.executable, script_path,
                "--now", "2026-09-18T04:00:00+08:00",
                "--config", temp_cfg_path,
                "--window-status", "INACTIVE"
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
            result = json.loads(proc.stdout)

            self.assertEqual(result["decision"], "SCHEDULE_WARMUP")
            self.assertEqual(result["decisionReason"], "READINESS_BENEFIT")
            self.assertIn("06:00", result["scheduledTime"])
            self.assertIn("11:00", result["expectedBoundary"])
            self.assertIn("14:00", result["naturalReset"])
            self.assertEqual(result["resetAdvanceMinutes"], 180.0)
            self.assertEqual(result["candidateUtility"], 0.0)
            self.assertGreater(result["score"], 30.0)
        finally:
            if os.path.exists(temp_cfg_path):
                os.remove(temp_cfg_path)

    def test_readiness_immediate_boundary_does_not_starve_to_tomorrow(self):
        """
        Production regression:
        At now = 2026-09-21T06:00:07+08:00 (7 seconds past nominal 06:00 boundary):
        - Quota is INACTIVE / sliding uninitialized (resetsAt = 11:00:07).
        - demandProfile = UNKNOWN.
        - readinessPolicy: enabled=True, primaryUseStart="09:00", preferredReset="11:00".
        Candidate 2026-09-21 06:00 yields resetAdvanceMinutes ≈ 179.9m.
        Candidate 2026-09-22 06:00 yields resetAdvanceMinutes = 180.0m.
        Because 2026-09-21 06:00 is an immediate opportunity (<= now + 5 min),
        and has a far higher totalScore (immediate bonus, no 24h temporal discount),
        it must win over tomorrow's 180.0m candidate and decide WARMUP_NOW,
        rather than being starved into SCHEDULE_WARMUP for tomorrow.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-21T06:00:07+08:00",
            "quota": {
                "resetAt": "2026-09-21T11:00:07+08:00",
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "demandProfile": {"status": "UNKNOWN", "bands": []},
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "11:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "WARMUP_NOW")
        self.assertEqual(plan["decisionReason"], "READINESS_BENEFIT")
        self.assertEqual(plan["scheduledTime"], "2026-09-21 06:00")
        self.assertEqual(plan["expectedBoundary"], "2026-09-21 11:00")
        self.assertAlmostEqual(plan["resetAdvanceMinutes"], 179.9, places=1)

    def test_readiness_future_candidate_returns_schedule_warmup(self):
        """
        Boundary verification:
        Proves that when the viable readiness candidate is genuinely non-immediate
        (e.g., at now = 2026-09-21T05:30:00+08:00, 30 minutes before 06:00),
        it returns SCHEDULE_WARMUP (not WARMUP_NOW).
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-21T05:30:00+08:00",
            "quota": {
                "resetAt": "2026-09-21T10:30:00+08:00",
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "demandProfile": {"status": "UNKNOWN", "bands": []},
            "readinessPolicy": {
                "enabled": True,
                "primaryUseStart": "09:00",
                "preferredReset": "11:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertEqual(plan["decisionReason"], "READINESS_BENEFIT")
        self.assertEqual(plan["scheduledTime"], "2026-09-21 06:00")
        self.assertEqual(plan["expectedBoundary"], "2026-09-21 11:00")

if __name__ == "__main__":
    unittest.main()
