"""
test_demand_regressions.py
Focused regressions for Demand Profile semantics (D1 - D5)
Validates fail-closed behavior for malformed CALIBRATED demand while preserving
legitimate UNKNOWN readiness benefits and existing capacity semantics.
"""

import os
import json
import unittest
from src.engine.decision_engine import DecisionEngine

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

class TestDemandRegressions(unittest.TestCase):

    def setUp(self):
        self.base_profile = {
            "sleepWindows": [["23:00", "07:00"]],
            "expectedWorkWindows": [["09:00", "17:00"]],
            "expectedPrimaryWorkStart": "09:00"
        }
        self.readiness_policy = {
            "enabled": True,
            "primaryUseStart": "09:00",
            "preferredReset": "11:00"
        }

    def test_d1_legitimate_unknown_with_readiness(self):
        """
        D1: UNKNOWN demand + valid readiness policy
        -> schedules READINESS_BENEFIT at 06:00 for 11:00 preferred reset.
        """
        engine = DecisionEngine({
            "userProfile": self.base_profile,
            "readinessPolicy": self.readiness_policy
        })
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "demandProfile": {"status": "UNKNOWN", "bands": []},
            "readinessPolicy": self.readiness_policy
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertEqual(plan["decisionReason"], "READINESS_BENEFIT")
        self.assertEqual(plan["scheduledTime"], "2026-09-18 06:00")
        self.assertEqual(plan["expectedBoundary"], "2026-09-18 11:00")
        self.assertEqual(plan["resetAdvanceMinutes"], 180.0)

    def test_d2_malformed_calibrated_with_readiness_fails_closed(self):
        """
        D2: malformed explicit CALIBRATED + valid readiness policy
        -> fail-closed to DEMAND_INVALID
        -> NO_ACTION, no READINESS_BENEFIT, no warmup scheduled.
        """
        malformed_demands = [
            {"status": "CALIBRATED", "bands": [{"start": "15:00"}]},
            {"status": "CALIBRATED", "bands": []},
            {"status": "CALIBRATED", "bands": None},
            {"status": "CALIBRATED", "bands": [{"start": "invalid", "end": "20:00", "demand": 10}]},
            "CALIBRATED",
            [{"start": "invalid"}]
        ]
        for bad_demand in malformed_demands:
            engine = DecisionEngine({
                "userProfile": self.base_profile,
                "readinessPolicy": self.readiness_policy,
                "demandProfile": bad_demand
            })
            state = {
                "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
                "now": "2026-09-18T04:00:00+08:00",
                "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
                "demandProfile": bad_demand,
                "readinessPolicy": self.readiness_policy
            }
            plan = engine.plan_next_action(state)
            self.assertEqual(plan["decision"], "NO_ACTION")
            self.assertEqual(plan["baselineType"], "DEMAND_INVALID")
            self.assertNotIn("scheduledTime", plan)
            self.assertNotIn("resetAdvanceMinutes", plan)
            self.assertIn("fail-closed", plan["reason"])

    def test_d3_valid_calibrated_low_demand_with_readiness(self):
        """
        D3: valid CALIBRATED low demand + readiness
        -> hasCapacityWin is false (incremental benefit below threshold)
        -> hasReadinessWin is true
        -> qualifies via READINESS_BENEFIT
        """
        calibrated_low_demand = {
            "status": "CALIBRATED",
            "bands": [{"start": "09:00", "end": "12:30", "demand": 40.0}]
        }
        engine = DecisionEngine({
            "userProfile": self.base_profile,
            "readinessPolicy": self.readiness_policy,
            "demandProfile": calibrated_low_demand
        })
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "demandProfile": calibrated_low_demand,
            "readinessPolicy": self.readiness_policy
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertEqual(plan["decisionReason"], "READINESS_BENEFIT")
        self.assertFalse(plan["breakdown"]["hasCapacityWin"])
        self.assertTrue(plan["breakdown"]["hasReadinessWin"])

    def test_d4_no_demand_with_readiness(self):
        """
        D4: NO_DEMAND + readiness policy
        -> NO_ACTION (NO_DEMAND explicitly disables readiness scheduling)
        """
        engine = DecisionEngine({
            "userProfile": self.base_profile,
            "readinessPolicy": self.readiness_policy,
            "demandProfile": {"status": "NO_DEMAND"}
        })
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T04:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "demandProfile": {"status": "NO_DEMAND"},
            "readinessPolicy": self.readiness_policy
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")

    def test_d5_s5_capacity_case_unchanged(self):
        """
        D5: valid S5 capacity case
        -> +55 CAPACITY_BENEFIT unchanged
        """
        s5_config_path = os.path.join(REPO_ROOT, "tests", "fixtures", "config_s5_cross_reset.json")
        engine = DecisionEngine(config_path=s5_config_path)
        with open(s5_config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)

        state = {
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "userProfile": cfg.get("userProfile"),
            "demandProfile": cfg.get("demandProfile")
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertEqual(plan["decisionReason"], "CAPACITY_BENEFIT")
        self.assertEqual(plan["incrementalBenefit"], 55.0)

if __name__ == "__main__":
    unittest.main()
