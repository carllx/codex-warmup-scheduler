"""
Regression Tests for Codex Warmup V2 Dynamic Scheduler (R1 - R5)
Tests actual production PowerShell components and integrations.
"""

import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone, timedelta

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLASSIFIER_PATH = os.path.join(REPO_ROOT, "src", "runtime", "RateLimitClassifier.psm1")
CONTROLLER_PATH = os.path.join(REPO_ROOT, "src", "scheduler", "controller.ps1")

def run_powershell(cmd):
    res = subprocess.run(
        ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
        shell=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=REPO_ROOT
    )
    return res.returncode, res.stdout, res.stderr

class TestRegressions(unittest.TestCase):

    def test_r1_primary_not_300m_secondary_is_300m(self):
        """
        R1: Primary window is not 300m (e.g. 60m), secondary is 300m.
        Must dynamically identify the 300m candidate, NOT assume primary == 300m.
        """
        now = datetime.now(timezone.utc)
        reset_time = now + timedelta(hours=3)
        reset_epoch = int(reset_time.timestamp())

        fixture = {
            "result": {
                "ordinaryUsageAllowed": True,
                "rateLimitsByLimitId": {
                    "codex": {
                        "primary": {
                            "limitId": "codex",
                            "windowDurationMins": 60,
                            "usedPercent": 10,
                            "resetsAt": int((now + timedelta(minutes=40)).timestamp())
                        },
                        "secondary": {
                            "limitId": "codex",
                            "windowDurationMins": 300,
                            "usedPercent": 25,
                            "resetsAt": reset_epoch
                        }
                    }
                }
            }
        }

        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as f:
            json.dump(fixture, f)
            fixture_path = f.name

        try:
            ps_cmd = (
                f"$payload = Get-Content -Raw '{fixture_path}' | ConvertFrom-Json; "
                f"Import-Module '{CLASSIFIER_PATH}' -Force; "
                f"$res = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload; "
                f"$res | ConvertTo-Json -Depth 5"
            )
            code, stdout, stderr = run_powershell(ps_cmd)
            self.assertEqual(code, 0, f"PowerShell failed: {stderr}")
            data = json.loads(stdout)

            self.assertEqual(data["OrdinaryUsageAllowed"], "TRUE")
            self.assertEqual(data["FiveHourWindowStatus"], "ACTIVE")
            self.assertEqual(data["ResetEpoch"], reset_epoch)
            self.assertTrue(data["CanEvaluateWarmup"])
            self.assertEqual(data["Identified5hWindow"]["windowDurationMins"], 300)
        finally:
            if os.path.exists(fixture_path):
                os.remove(fixture_path)

    def test_r2_sliding_resets_at_detected_ambiguous(self):
        """
        R2: Sliding resetsAt (usedPercent=0, resetsAt slides with clock -> AMBIGUOUS, CanEvaluateWarmup=false).
        """
        now = datetime.now(timezone.utc)
        probe1_reset = int((now + timedelta(minutes=299)).timestamp())
        probe2_reset = int((now + timedelta(minutes=300)).timestamp())

        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as f_cache:
            json.dump({"ResetEpoch": probe1_reset}, f_cache)
            cache_path = f_cache.name

        fixture = {
            "result": {
                "ordinaryUsageAllowed": True,
                "rateLimitsByLimitId": {
                    "codex": {
                        "primary": {
                            "limitId": "codex",
                            "windowDurationMins": 300,
                            "usedPercent": 0,
                            "resetsAt": probe2_reset
                        }
                    }
                }
            }
        }

        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as f:
            json.dump(fixture, f)
            fixture_path = f.name

        try:
            ps_cmd = (
                f"$payload = Get-Content -Raw '{fixture_path}' | ConvertFrom-Json; "
                f"$prev = Get-Content -Raw '{cache_path}' | ConvertFrom-Json; "
                f"Import-Module '{CLASSIFIER_PATH}' -Force; "
                f"$res = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload -PreviousProbe $prev; "
                f"$res | ConvertTo-Json -Depth 5"
            )
            code, stdout, stderr = run_powershell(ps_cmd)
            self.assertEqual(code, 0, f"PowerShell failed: {stderr}")
            data = json.loads(stdout)

            self.assertEqual(data["ResetAnchorStatus"], "SLIDING_OR_UNINITIALIZED")
            self.assertEqual(data["FiveHourWindowStatus"], "AMBIGUOUS")
            self.assertFalse(data["CanEvaluateWarmup"])
        finally:
            if os.path.exists(fixture_path):
                os.remove(fixture_path)
            if os.path.exists(cache_path):
                os.remove(cache_path)

    def test_r3_ordinary_usage_allowed_false_blocks_warmup(self):
        """
        R3: ordinaryUsageAllowed = false blocks warmup unconditionally (Hard Gate).
        """
        fixture = {
            "result": {
                "ordinaryUsageAllowed": False,
                "rateLimitsByLimitId": {
                    "codex": {
                        "primary": {
                            "limitId": "codex",
                            "windowDurationMins": 300,
                            "usedPercent": 10,
                            "resetsAt": int((datetime.now(timezone.utc) + timedelta(hours=2)).timestamp())
                        }
                    }
                }
            }
        }

        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as f:
            json.dump(fixture, f)
            fixture_path = f.name

        try:
            ps_cmd = (
                f"$payload = Get-Content -Raw '{fixture_path}' | ConvertFrom-Json; "
                f"Import-Module '{CLASSIFIER_PATH}' -Force; "
                f"$res = ConvertTo-NormalizedQuotaState -RateLimitResponse $payload; "
                f"$res | ConvertTo-Json -Depth 5"
            )
            code, stdout, stderr = run_powershell(ps_cmd)
            self.assertEqual(code, 0, f"PowerShell failed: {stderr}")
            data = json.loads(stdout)

            self.assertEqual(data["OrdinaryUsageAllowed"], "FALSE")
            self.assertEqual(data["FiveHourWindowStatus"], "BLOCKED")
            self.assertFalse(data["CanEvaluateWarmup"])
            self.assertIn("ordinaryUsageAllowed is false", data["Reason"])
        finally:
            if os.path.exists(fixture_path):
                os.remove(fixture_path)

    def test_r4_delayed_missed_run_probes_fresh_state_and_replans(self):
        """
        R4: Verify controller in -ShadowMode -DryRun performs fresh probe & replan, never blind execution.
        """
        cmd = f"& '{CONTROLLER_PATH}' -ShadowMode -DryRun"
        code, stdout, stderr = run_powershell(cmd)
        self.assertEqual(code, 0, f"Controller failed: {stderr}")
        self.assertIn("=== Codex Warmup V2 Controller Started ===", stdout)
        self.assertIn("Codex Runtime resolved", stdout)
        self.assertIn("Rate Limits Classified", stdout)
        self.assertIn("Invoking Decision Engine", stdout)
        self.assertIn("Decision Engine Result", stdout)
        self.assertIn("=== Codex Warmup V2 Controller Finished ===", stdout)

    def test_r5_named_mutex_concurrency_guard(self):
        """
        R5: Verify named mutex 'Global\\CodexWarmupV2Controller' prevents concurrent instances.
        """
        ps_script = f"""
        $mutex = New-Object System.Threading.Mutex($false, "Global\\CodexWarmupV2Controller")
        $hasLock = $mutex.WaitOne(0, $false)
        if ($hasLock) {{
            try {{
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "pwsh"
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"{CONTROLLER_PATH}`" -ShadowMode -DryRun"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $out = $p.StandardOutput.ReadToEnd()
                $p.WaitForExit()
                Write-Host $out
                Write-Host "SecondInstanceExitCode=$($p.ExitCode)"
            }} finally {{
                $mutex.ReleaseMutex()
            }}
        }} else {{
            Write-Host "CouldNotAcquireInitialLock"
        }}
        """
        code, stdout, stderr = run_powershell(ps_script)
        self.assertEqual(code, 0, f"Mutex test failed: {stderr}")
        self.assertIn("Another instance of CodexWarmupV2Controller is currently executing", stdout)
        self.assertIn("SecondInstanceExitCode=0", stdout)

if __name__ == "__main__":
    unittest.main()
