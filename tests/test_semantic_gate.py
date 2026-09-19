"""
tests/test_semantic_gate.py
Dedicated semantic gate regression suite for Decision Engine.
Asserts:
- S1: Artificial pre-work alignment (04:00 warmup for 09:00 work start) -> NO_ACTION
- S2: Rest day (NO_DEMAND) -> NO_ACTION with NO_EXPECTED_WORK baseline
- S3: Near-term natural work (user starting work now) -> NO_ACTION over natural use
- S4: Afternoon work alignment rejected -> deterministic NO_ACTION (identical available state from 15:00)
- S5: True cross-reset capacity -> SCHEDULE_WARMUP at 11:00 (serves 160 vs baseline 100)
- CLI Integration: S5 positive fixture through production CLI interface
- CLI Integration: S4 negative fixture through production CLI interface
- CLI Integration: Production default config (UNKNOWN) fails closed with NO_ACTION
- UNKNOWN demand status + expectedWorkWindows -> NO_ACTION, DEMAND_UNKNOWN, zero inferred quota demand
- NO_DEMAND demand status -> NO_ACTION, NO_EXPECTED_WORK
- Invariant: baselineUtility matches servedDemand when trajectory demand exists
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
        S1: User sleeps until 08:00, starts work at 09:00 with calibrated demand 40.
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
            },
            "demandProfile": {
                "status": "CALIBRATED",
                "bands": [
                    {"start": "09:00", "end": "12:30", "demand": 40.0}
                ]
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
        S2: Rest day where status is NO_DEMAND.
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
            },
            "demandProfile": {
                "status": "NO_DEMAND"
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
            },
            "demandProfile": {
                "status": "CALIBRATED",
                "bands": [
                    {"start": "09:00", "end": "12:30", "demand": 40.0}
                ]
            }
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "NEXT_NATURAL_USE")
        self.assertLessEqual(plan["incrementalBenefit"], plan["incrementalThreshold"])

    def test_s4_afternoon_work_alignment_rejected(self):
        """
        S4: Expected work = 15:00–20:00 with calibrated demand 60.
        NO_WARMUP: 15:00 natural use -> 15:00–20:00 window serves 60.
        WARMUP_AT(10:00): 10:00 artificial window -> reset 15:00 -> 15:00 natural use -> 15:00–20:00 window serves 60.
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
            },
            "demandProfile": {
                "status": "CALIBRATED",
                "bands": [
                    {"start": "15:00", "end": "20:00", "demand": 60.0}
                ]
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
            "demandProfile": {
                "status": "CALIBRATED",
                "bands": [
                    {"start": "15:00", "end": "16:00", "demand": 80.0},
                    {"start": "16:00", "end": "20:00", "demand": 80.0}
                ]
            }
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

    def test_cli_production_default_config_is_unknown_and_fails_closed(self):
        """
        CLI integration test: runs decision_engine.py with repo config/default.json.
        Verifies that because demandProfile.status is UNKNOWN, the production CLI
        deterministically fails closed with NO_ACTION, DEMAND_UNKNOWN, and zero inferred demand.
        """
        script_path = os.path.join(project_root, "src", "engine", "decision_engine.py")
        config_path = os.path.join(project_root, "config", "default.json")
        cmd = [
            sys.executable, script_path,
            "--now", "2026-09-17T21:00:00+08:00",
            "--config", config_path,
            "--window-status", "INACTIVE"
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        result = json.loads(proc.stdout)

        self.assertEqual(result["decision"], "NO_ACTION")
        self.assertEqual(result["baselineType"], "DEMAND_UNKNOWN")
        self.assertEqual(result["baselineUtility"], 0.0)
        self.assertEqual(result["candidateUtility"], 0.0)
        self.assertEqual(result["incrementalBenefit"], 0.0)
        self.assertIn("fail-closed", result["reason"])

    def test_unknown_demand_fails_closed_no_action(self):
        """
        Proves:
        UNKNOWN status + expectedWorkWindows != []
        -> NO_ACTION
        -> DEMAND_UNKNOWN
        -> zero inferred quota demand
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-17T21:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "userProfile": {
                "expectedWorkWindows": [["09:00", "12:30"], ["14:00", "19:00"]],
                "expectedPrimaryWorkStart": "09:00"
            },
            "demandProfile": {"status": "UNKNOWN", "bands": []}
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "DEMAND_UNKNOWN")
        self.assertEqual(plan["baselineUtility"], 0.0)
        self.assertEqual(plan["candidateUtility"], 0.0)
        self.assertEqual(plan["incrementalBenefit"], 0.0)
        self.assertIn("fail-closed", plan["reason"])

    def test_no_demand_status_yields_no_action(self):
        """
        Proves:
        NO_DEMAND status
        -> NO_ACTION
        -> NO_EXPECTED_WORK baseline
        """
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "userProfile": {
                "expectedWorkWindows": [["09:00", "12:30"]],
                "expectedPrimaryWorkStart": "09:00"
            },
            "demandProfile": {"status": "NO_DEMAND"}
        }
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "NO_EXPECTED_WORK")
        self.assertEqual(plan["baselineUtility"], 0.0)

    def test_baseline_utility_matches_served_demand_when_work_windows_absent(self):
        """
        Invariant test:
        baselineUtility must always equal the NO_WARMUP trajectory's actual served-demand utility
        when trajectory demand exists, even if userProfile.expectedWorkWindows is empty or absent.
        """
        engine = DecisionEngine({
            "demandProfile": {
                "status": "CALIBRATED",
                "bands": [
                    {"start": "15:00", "end": "20:00", "demand": 100.0}
                ]
            }
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

    def test_malformed_string_calibrated_fails_closed(self):
        """
        Proves:
        profile_input = "CALIBRATED" (without bands)
        -> fail-closed to UNKNOWN
        -> NO_ACTION, DEMAND_UNKNOWN
        """
        engine = DecisionEngine({"demandProfile": "CALIBRATED"})
        self.assertEqual(engine.demand_status, "UNKNOWN")
        self.assertEqual(engine.demand_bands, [])
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "demandProfile": "CALIBRATED"
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "DEMAND_UNKNOWN")

    def test_calibrated_empty_bands_fails_closed(self):
        """
        Proves:
        {"status": "CALIBRATED", "bands": []}
        -> fail-closed to UNKNOWN
        -> NO_ACTION, DEMAND_UNKNOWN
        """
        engine = DecisionEngine({"demandProfile": {"status": "CALIBRATED", "bands": []}})
        self.assertEqual(engine.demand_status, "UNKNOWN")
        self.assertEqual(engine.demand_bands, [])
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "demandProfile": {"status": "CALIBRATED", "bands": []}
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "DEMAND_UNKNOWN")

    def test_calibrated_malformed_band_fails_closed_no_exception(self):
        """
        Proves:
        {"status": "CALIBRATED", "bands": [{"start": "15:00"}]} (missing end and demand)
        or negative demand, or invalid HH:MM
        -> fail-closed to UNKNOWN without raising an exception
        -> NO_ACTION, DEMAND_UNKNOWN
        """
        malformed_inputs = [
            {"status": "CALIBRATED", "bands": [{"start": "15:00"}]},
            {"status": "CALIBRATED", "bands": [{"start": "15:00", "end": "20:00"}]},
            {"status": "CALIBRATED", "bands": [{"start": "99:99", "end": "20:00", "demand": 10.0}]},
            {"status": "CALIBRATED", "bands": [{"start": "15:00", "end": "20:00", "demand": -5.0}]},
            {"status": "CALIBRATED", "bands": [{"start": "15:00", "end": "20:00", "demand": "invalid"}]},
            {"status": "CALIBRATED", "bands": ["not-a-dict"]}
        ]
        for bad_prof in malformed_inputs:
            engine = DecisionEngine({"demandProfile": bad_prof})
            self.assertEqual(engine.demand_status, "UNKNOWN")
            self.assertEqual(engine.demand_bands, [])
            state = {
                "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
                "now": "2026-09-18T08:00:00+08:00",
                "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
                "demandProfile": bad_prof
            }
            plan = engine.plan_next_action(state)
            self.assertEqual(plan["decision"], "NO_ACTION")
            self.assertEqual(plan["baselineType"], "DEMAND_UNKNOWN")

    def test_legacy_malformed_direct_list_fails_closed(self):
        """
        Proves:
        Legacy direct list with malformed band:
        -> fail-closed to UNKNOWN
        -> NO_ACTION, DEMAND_UNKNOWN
        """
        engine = DecisionEngine({"demandProfile": [{"start": "invalid"}]})
        self.assertEqual(engine.demand_status, "UNKNOWN")
        self.assertEqual(engine.demand_bands, [])
        state = {
            "device": {"wakeToRunAvailable": True, "state": "AWAKE"},
            "now": "2026-09-18T08:00:00+08:00",
            "quota": {"resetAt": None, "weeklyBlocked": False, "fiveHourWindowStatus": "INACTIVE"},
            "demandProfile": [{"start": "invalid"}]
        }
        plan = engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")
        self.assertEqual(plan["baselineType"], "DEMAND_UNKNOWN")

    def test_unknown_and_no_demand_ignore_accidental_bands(self):
        """
        Proves:
        UNKNOWN or NO_DEMAND status with accidental bands present
        -> bands are ignored, returning empty bands []
        """
        engine_no_demand = DecisionEngine({
            "demandProfile": {
                "status": "NO_DEMAND",
                "bands": [{"start": "15:00", "end": "20:00", "demand": 50.0}]
            }
        })
        self.assertEqual(engine_no_demand.demand_status, "NO_DEMAND")
        self.assertEqual(engine_no_demand.demand_bands, [])

        engine_unknown = DecisionEngine({
            "demandProfile": {
                "status": "UNKNOWN",
                "bands": [{"start": "15:00", "end": "20:00", "demand": 50.0}]
            }
        })
        self.assertEqual(engine_unknown.demand_status, "UNKNOWN")
        self.assertEqual(engine_unknown.demand_bands, [])

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
        self.assertEqual(plan["candidateUtility"], 0.0) # Zero synthetic demand
        self.assertEqual(plan["incrementalBenefit"], 0.0) # Zero capacity benefit
        self.assertGreater(plan["score"], 30.0) # Passes minimumUsefulScore gate

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
        # Verify 04:00 candidate is actually generated
        candidates = self.engine.generate_candidates(state)
        cand_04_times = [c.strftime("%H:%M") for c in candidates]
        self.assertIn("04:00", cand_04_times)

        # Verify candidate 04:00 fails readiness semantic condition
        cand_04_dt = self.engine.parse_time("2026-09-18T04:00:00+08:00")
        eval_res = self.engine.evaluate_readiness_benefit(cand_04_dt, state)
        self.assertFalse(eval_res["isMeaningful"])
        self.assertEqual(eval_res["resetAdvanceMinutes"], 0.0)

        # Verify deterministic NO_ACTION
        plan = self.engine.plan_next_action(state)
        self.assertEqual(plan["decision"], "NO_ACTION")

    def test_readiness_safety_hard_gates(self):
        """
        Safety constraints:
        - weeklyBlocked -> NO_ACTION
        - fiveHourWindowStatus == 'BLOCKED' -> NO_ACTION
        - fiveHourWindowStatus == 'AMBIGUOUS' -> NO_ACTION (risk penalty fails score gate)
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

        # 3. AMBIGUOUS window (300 risk penalty drives totalScore below minimumUsefulScore)
        s_ambig = json.loads(json.dumps(base_state))
        s_ambig["quota"]["fiveHourWindowStatus"] = "AMBIGUOUS"
        self.assertEqual(self.engine.plan_next_action(s_ambig)["decision"], "NO_ACTION")

        # 4. wakeToRunAvailable False during sleep
        s_no_wake = json.loads(json.dumps(base_state))
        s_no_wake["device"]["wakeToRunAvailable"] = False
        self.assertEqual(self.engine.plan_next_action(s_no_wake)["decision"], "NO_ACTION")

        # 5. Inside active window until 08:00 (encloses 06:00 warmup)
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

if __name__ == "__main__":
    unittest.main()
