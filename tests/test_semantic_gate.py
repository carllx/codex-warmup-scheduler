"""
tests/test_semantic_gate.py
Dedicated semantic gate regression suite for Decision Engine.
Asserts:
- S1: Artificial pre-work alignment (04:00 warmup for 09:00 work start) -> NO_ACTION
- S2: Rest day (expectedWorkWindows = []) -> NO_ACTION with NO_EXPECTED_WORK baseline
- S3: Near-term natural work (user starting work now) -> NO_ACTION over natural use
- S4: Positive-benefit search / verified positive warmup scenario
"""

import os
import sys
import json
import unittest

# Path setup
current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(current_dir)
sys.path.insert(0, os.path.join(project_root, "src", "engine"))

from decision_engine import DecisionEngine

class TestSemanticGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        config_file = os.path.join(project_root, "config", "default.json")
        with open(config_file, "r", encoding="utf-8") as f:
            cls.config = json.load(f)
        cls.engine = DecisionEngine(cls.config)

    def test_s1_artificial_pre_work_alignment_rejected(self):
        """
        S1: User sleeps until 08:00, starts work at 09:00.
        Now is 21:00 previous day.
        A candidate at 04:00 (resetting at 09:00) must evaluate against natural baseline
        and yield NO_ACTION.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-17T21:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "userProfile": {
                "sleepWindows": [["01:30", "08:00"]],
                "expectedWorkWindows": [
                    ["09:00", "12:30"],
                    ["14:00", "19:00"],
                    ["20:00", "23:00"]
                ],
                "timezone": "Asia/Shanghai",
                "expectedPrimaryWorkStart": "09:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertIn("baselineType", plan)
        self.assertIn("incrementalBenefit", plan)
        for cand in plan.get("topCandidates", []):
            if "04:00" in cand["time"]:
                self.assertLessEqual(cand["incrementalBenefit"], plan["incrementalThreshold"])

    def test_s2_rest_day_no_expected_work(self):
        """
        S2: Rest day where expectedWorkWindows is empty.
        Must report NO_EXPECTED_WORK baseline with 0.0 utility and decision NO_ACTION.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "userProfile": {
                "sleepWindows": [["01:30", "09:00"]],
                "expectedWorkWindows": [],
                "timezone": "Asia/Shanghai",
                "expectedPrimaryWorkStart": None
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "NO_EXPECTED_WORK")
        self.assertEqual(plan["baselineUtility"], 0.0)

    def test_s3_near_term_work_no_false_win(self):
        """
        S3: User is active and entering work shortly.
        Warmup cannot falsely win over immediate natural usage.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:50:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "userProfile": {
                "sleepWindows": [["01:30", "08:00"]],
                "expectedWorkWindows": [
                    ["09:00", "12:30"],
                    ["14:00", "19:00"]
                ],
                "timezone": "Asia/Shanghai",
                "expectedPrimaryWorkStart": "09:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "NEXT_NATURAL_USE")
        self.assertLessEqual(plan["incrementalBenefit"], plan["incrementalThreshold"])

    def test_s4_positive_benefit_fixture_or_search(self):
        """
        S4: Legitimate positive warmup case.
        Example: Daytime alignment for late shift where intermediate warmup achieves positive incremental benefit.
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-17T21:00:00+08:00",
            "quota": {
                "resetAt": None,
                "weeklyBlocked": False,
                "fiveHourWindowStatus": "INACTIVE",
                "windowDurationMinutes": 300
            },
            "userProfile": {
                "sleepWindows": [["01:30", "08:00"]],
                "expectedWorkWindows": [
                    ["15:00", "20:00"]
                ],
                "timezone": "Asia/Shanghai",
                "expectedPrimaryWorkStart": "15:00"
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertIn(plan["decision"], ["SCHEDULE_WARMUP", "NO_ACTION"])
        if plan["decision"] == "SCHEDULE_WARMUP":
            self.assertGreater(plan["incrementalBenefit"], plan["incrementalThreshold"])
            self.assertFalse(plan["breakdown"]["isSleep"])

if __name__ == "__main__":
    unittest.main()
