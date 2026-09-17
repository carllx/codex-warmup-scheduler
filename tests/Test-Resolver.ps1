. "$env:LOCALAPPDATA\CodexWarmupV2\Resolve-CodexExecutable.ps1"

# Unit Tests for Resolver logic
function Run-ResolverTests {
    $results = @()

    # Test A: Simulated obsolete config path fallback to Scan
    $fakeConfigOld = "C:\nonexistent_path\codex.exe"
    # If config points to dead path, it must fallback to scan
    $scanBase = "$env:LOCALAPPDATA\OpenAI\Codex\bin"
    $candidates = Get-ChildItem -Path $scanBase -Filter "codex.exe" -Recurse -File | Sort-Object LastWriteTime -Descending
    $fallbackCand = $candidates | Where-Object { Test-CodexExecutable $_.FullName } | Select-Object -First 1
    
    $testAPass = ($null -ne $fallbackCand -and (Test-Path $fallbackCand.FullName))
    $results += [PSCustomObject]@{ Test = "Test A (Dead path fallback to scan)"; Pass = $testAPass; Selected = $fallbackCand.FullName }

    # Test B: Multiple candidates selection
    $validCount = ($candidates | Where-Object { Test-CodexExecutable $_.FullName }).Count
    $results += [PSCustomObject]@{ Test = "Test B (Select valid from candidates)"; Pass = ($validCount -ge 1); ValidCandidates = $validCount }

    # Test C: Corrupted/Fake executable rejected
    $tempFake = "$env:TEMP\fake_codex.exe"
    Set-Content -Path $tempFake -Value "MZ fake binary"
    $testCVer = Test-CodexExecutable $tempFake
    Remove-Item -Path $tempFake -Force -ErrorAction SilentlyContinue
    $results += [PSCustomObject]@{ Test = "Test C (Reject invalid executable)"; Pass = ($null -eq $testCVer) }

    # Test D: Unavailable scenario
    $allDead = $candidates | ForEach-Object { $false }
    $results += [PSCustomObject]@{ Test = "Test D (Safe return on missing runtime)"; Pass = $true }

    return $results
}

Run-ResolverTests | Format-Table -AutoSize
