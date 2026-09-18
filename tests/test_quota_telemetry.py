"""
tests/test_quota_telemetry.py
Unit tests for non-content observational quota telemetry logging.
Proves:
1. One valid classifier result produces exactly one valid JSONL observation record.
2. Null usedPercent and optional fields are safely serialized as JSON null.
3. Telemetry write failure (e.g. read-only file/directory) does not throw or block execution.
4. Retention remains strictly bounded to max 5000 records (retains newest ~4000).
"""

import os
import sys
import json
import tempfile
import subprocess
import unittest

current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(current_dir)
module_path = os.path.join(project_root, "src", "runtime", "QuotaObservation.psm1")

class TestQuotaTelemetry(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.obs_file = os.path.join(self.temp_dir.name, "quota_observations.jsonl")

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_pwsh_command(self, pwsh_script):
        cmd = ["pwsh", "-NoProfile", "-Command", pwsh_script]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc

    def test_one_valid_classifier_result_produces_one_jsonl_observation(self):
        """
        Proves: One valid classifier result produces exactly one valid JSONL observation record
        matching the minimal schema (no prompt/content telemetry).
        """
        pwsh_script = f"""
        Import-Module '{module_path}' -Force
        $cls = [PSCustomObject]@{{
            ObservedAt             = '2026-09-19T06:26:34+08:00'
            FiveHourWindowStatus   = 'ACTIVE'
            ResetAnchorStatus      = 'FIXED'
            ResetAt                = '2026-09-19T11:26:33+08:00'
            ResetEpoch             = 1789788393
            WeeklyBlocked          = $false
            OrdinaryUsageAllowed   = 'TRUE'
            Identified5hWindow     = [PSCustomObject]@{{ usedPercent = 42.5 }}
            IdentifiedWeeklyWindow = [PSCustomObject]@{{ usedPercent = 15.0 }}
        }}
        Write-QuotaObservation -Classification $cls -RuntimeVersion 'codex-cli 0.154.0' -ObservationsPath '{self.obs_file}'
        """
        res = self.run_pwsh_command(pwsh_script)
        self.assertEqual(res.returncode, 0, f"PowerShell failed: {res.stderr}")
        self.assertTrue(os.path.exists(self.obs_file))

        with open(self.obs_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
        self.assertEqual(len(lines), 1)

        record = json.loads(lines[0].strip())
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual(record["observedAt"], "2026-09-19T06:26:34+08:00")
        self.assertEqual(record["fiveHourStatus"], "ACTIVE")
        self.assertEqual(record["fiveHourUsedPercent"], 42.5)
        self.assertEqual(record["resetAt"], "2026-09-19T11:26:33+08:00")
        self.assertEqual(record["resetEpoch"], 1789788393)
        self.assertEqual(record["resetAnchorStatus"], "FIXED")
        self.assertEqual(record["weeklyUsedPercent"], 15.0)
        self.assertFalse(record["weeklyBlocked"])
        self.assertEqual(record["ordinaryUsageAllowed"], "TRUE")
        self.assertEqual(record["codexRuntimeVersion"], "codex-cli 0.154.0")

    def test_null_used_percent_safely_serialized(self):
        """
        Proves: When usedPercent is $null (e.g. uninitialized / sliding anchor),
        it is safely serialized as JSON null, avoiding synthetic values.
        """
        pwsh_script = f"""
        Import-Module '{module_path}' -Force
        $cls = [PSCustomObject]@{{
            ObservedAt             = '2026-09-19T05:00:06+08:00'
            FiveHourWindowStatus   = 'AMBIGUOUS'
            ResetAnchorStatus      = 'SLIDING_OR_UNINITIALIZED'
            ResetAt                = $null
            ResetEpoch             = $null
            WeeklyBlocked          = $false
            OrdinaryUsageAllowed   = 'TRUE'
            Identified5hWindow     = [PSCustomObject]@{{ usedPercent = $null }}
            IdentifiedWeeklyWindow = $null
        }}
        Write-QuotaObservation -Classification $cls -RuntimeVersion $null -ObservationsPath '{self.obs_file}'
        """
        res = self.run_pwsh_command(pwsh_script)
        self.assertEqual(res.returncode, 0, f"PowerShell failed: {res.stderr}")

        with open(self.obs_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
        self.assertEqual(len(lines), 1)

        record = json.loads(lines[0].strip())
        self.assertIsNone(record["fiveHourUsedPercent"])
        self.assertIsNone(record["weeklyUsedPercent"])
        self.assertIsNone(record["resetAt"])
        self.assertIsNone(record["resetEpoch"])
        self.assertIsNone(record["codexRuntimeVersion"])
        self.assertEqual(record["fiveHourStatus"], "AMBIGUOUS")

    def test_telemetry_write_failure_does_not_block(self):
        """
        Proves: If write fails (e.g. invalid / unwritable path),
        Write-QuotaObservation catches the error and exits cleanly without throwing.
        """
        invalid_path = "Z:\\nonexistent_dir_12345\\impossible_file.jsonl"
        pwsh_script = f"""
        $ErrorActionPreference = 'Stop'
        Import-Module '{module_path}' -Force
        $cls = [PSCustomObject]@{{
            FiveHourWindowStatus = 'INACTIVE'
            OrdinaryUsageAllowed = 'TRUE'
            WeeklyBlocked        = $false
        }}
        Write-QuotaObservation -Classification $cls -RuntimeVersion 'test' -ObservationsPath '{invalid_path}'
        Write-Output 'TELEMETRY_CALL_COMPLETED'
        """
        res = self.run_pwsh_command(pwsh_script)
        self.assertEqual(res.returncode, 0)
        self.assertIn("TELEMETRY_CALL_COMPLETED", res.stdout)

    def test_retention_remains_bounded(self):
        """
        Proves: When observations exceed 5000 lines, retention prunes
        down to the newest ~4000 records.
        """
        # Pre-seed file with 5001 lines
        with open(self.obs_file, "w", encoding="utf-8") as f:
            for i in range(1, 5002):
                f.write(json.dumps({"schemaVersion": 1, "index": i}) + "\n")

        pwsh_script = f"""
        Import-Module '{module_path}' -Force
        $cls = [PSCustomObject]@{{
            ObservedAt           = '2026-09-19T07:00:00+08:00'
            FiveHourWindowStatus = 'INACTIVE'
            WeeklyBlocked        = $false
            OrdinaryUsageAllowed = 'TRUE'
        }}
        # Trigger one more write which should detect line count > 5000 and retain newest 4000
        Write-QuotaObservation -Classification $cls -RuntimeVersion 'test' -ObservationsPath '{self.obs_file}'
        """
        res = self.run_pwsh_command(pwsh_script)
        self.assertEqual(res.returncode, 0, f"PowerShell failed: {res.stderr}")

        with open(self.obs_file, "r", encoding="utf-8") as f:
            lines = f.readlines()

        self.assertLessEqual(len(lines), 4001)
        self.assertGreaterEqual(len(lines), 3999)

        # Confirm that oldest records were dropped and newest records remain
        first_remaining = json.loads(lines[0].strip())
        self.assertGreater(first_remaining.get("index", 9999), 1000)

if __name__ == "__main__":
    unittest.main()
