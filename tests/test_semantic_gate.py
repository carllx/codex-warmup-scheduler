"""
tests/test_semantic_gate.py
Dedicated semantic gate regression suite for Decision Engine.
Asserts:
- S1: Artificial pre-work alignment (04:00 warmup for 09:00 work start) -> NO_ACTION
- S2: Rest day (expectedWorkWindows = []) -> NO_ACTION with NO_EXPECTED_WORK baseline
- S3: Near-term natural work (user starting work now) -> NO_ACTION over natural use
- S4: Afternoon work alignment rejected -> deterministic NO_ACTION (identical available state from 15:00)
- S5: True cross-reset capacity -> SCHEDULE_WARMUP at 11:00 (serves 160 vs baseline 100)
- CLI Integration: S5 positive fixture through production CLI interface
- CLI Integration: S4 negative fixture through production CLI interface
- Invariant: baselineUtility matches servedDemand even when expectedWorkWindows is absent
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

    def test_s4_afternoon_work_alignment_rejected(self):
        """
        S4: Expected work = 15:00–20:00.
        NO_WARMUP: 15:00 natural use -> 15:00–20:00 window.
        WARMUP_AT(10:00): 10:00 artificial window -> reset 15:00 -> 15:00 natural use -> 15:00–20:00 window.
        Since both yield identical available state from 15:00 onward, 10:00 warmup
        must not obtain positive incremental benefit merely because reset aligns with 15:00.
        Deterministically asserts NO_ACTION.
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
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertLessEqual(plan["incrementalBenefit"], plan["incrementalThreshold"])
        cand_10_dt = self.engine.parse_time("2026-09-18T10:00:00+08:00")
        cand_10, _ = self.engine.score_candidate(cand_10_dt, state)
        cand_10_inc = cand_10["candidateUtility"] - plan["baselineUtility"] - cand_10["incrementalCosts"]
        self.assertLessEqual(cand_10_inc, 0.0)

    def test_s5_true_cross_reset_capacity(self):
        """
        S5: High demand across 15:00–20:00 exceeding single window capacity:
        - 15:00–16:00: demand 80
        - 16:00–20:00: demand 80
        Total demand = 160. Single window capacity = 100. Warmup consumption = 1.0.

        NO_WARMUP:
        - 15:00 natural start -> single window [15:00, 20:00] serves 100, leaving 60 unserved.

        WARMUP_AT(11:00):
        - Window 1 [11:00, 16:00] (capacity 99) serves 80 between 15:00–16:00.
        - 16:00 reset -> Window 2 [16:00, 21:00] serves 80 between 16:00–20:00.
        - Total served = 160 (0 unserved).
        - Incremental served = 160 - 100 = +60.
        - Net benefit = 60 - 5 (warmup cost) = 55.0 > incremental threshold (15.0).
        - Decision = SCHEDULE_WARMUP at 11:00.
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
                "sleepWindows": [["01:30", "08:00"]],
                "expectedWorkWindows": [
                    ["15:00", "20:00"]
                ],
                "timezone": "Asia/Shanghai",
                "expectedPrimaryWorkStart": "15:00"
            },
            "demandProfile": [
                {"start": "15:00", "end": "16:00", "demand": 80.0},
                {"start": "16:00", "end": "20:00", "demand": 80.0}
            ]
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "SCHEDULE_WARMUP")
        self.assertIn("11:00", plan["scheduledTime"])
        self.assertGreater(plan["incrementalBenefit"], plan["incrementalThreshold"])
        self.assertEqual(plan["breakdown"]["servedDemand"], 160.0)
        self.assertEqual(plan["breakdown"]["unservedDemand"], 0.0)
        self.assertEqual(plan["breakdown"]["baselineServedDemand"], 100.0)
        self.assertEqual(plan["breakdown"]["baselineUnservedDemand"], 60.0)
        self.assertEqual(plan["incrementalBenefit"], 55.0)

    def test_cli_s5_true_cross_reset_capacity(self):
        """
        CLI integration test: runs decision_engine.py via CLI with config fixture containing S5 demand profile.
        Verifies:
        - NO_WARMUP served = 100
        - WARMUP candidate served = 160
        - net incremental benefit = 55
        - decision = SCHEDULE_WARMUP at 11:00
        """
        script_path = os.path.join(project_root, "src", "engine", "decision_engine.py")
        config_path = os.path.join(project_root, "tests", "fixtures", "config_s5_cross_reset.json")
        cmd = [
            sys.executable, script_path,
            "--now", "2026-09-18T08:00:00+08:00",
            "--config", config_path,
            "--window-status", "INACTIVE"
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        result = json.loads(proc.stdout)

        self.assertEqual(result["decision"], "SCHEDULE_WARMUP")
        self.assertIn("11:00", result["scheduledTime"])
        self.assertEqual(result["breakdown"]["baselineServedDemand"], 100.0)
        self.assertEqual(result["breakdown"]["servedDemand"], 160.0)
        self.assertEqual(result["incrementalBenefit"], 55.0)
        self.assertGreater(result["score"], 30.0) # passes minimumUsefulScore gate

    def test_cli_s4_false_alignment_rejected(self):
        """
        CLI integration test: runs decision_engine.py via CLI with config fixture for S4.
        Verifies that S4 remains NO_ACTION over the CLI interface.
        """
        script_path = os.path.join(project_root, "src", "engine", "decision_engine.py")
        config_path = os.path.join(project_root, "tests", "fixtures", "config_s4_false_alignment.json")
        cmd = [
            sys.executable, script_path,
            "--now", "2026-09-17T21:00:00+08:00",
            "--config", config_path,
            "--window-status", "INACTIVE"
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        result = json.loads(proc.stdout)

        self.assertEqual(result["decision"], "NO_ACTION")
        self.assertLessEqual(result["incrementalBenefit"], 0.0)

    def test_baseline_utility_matches_served_demand_when_work_windows_absent(self):
        """
        Invariant test:
        baselineUtility must always equal the NO_WARMUP trajectory's actual served-demand utility
        when trajectory demand exists, even if userProfile.expectedWorkWindows is empty or absent.
        """
        engine = DecisionEngine({
            "demandProfile": [
                {"start": "15:00", "end": "20:00", "demand": 100.0}
            ]
        })
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "userProfile": {"expectedWorkWindows": []} # empty work windows
        }
        baseline = engine.compute_natural_baseline(state)
        self.assertGreater(baseline["servedDemand"], 0.0)
        self.assertEqual(baseline["baselineUtility"], baseline["servedDemand"])
        self.assertNotEqual(baseline["baselineType"], "NO_EXPECTED_WORK")

if __name__ == "__main__":
    unittest.main()
