#requires -Version 5.1
<#
.SYNOPSIS
  Verify #1206 -- the arming of the coder's LOCAL offline docset lookup (tools/search_docs.py).

.DESCRIPTION
  tools/search_docs.py has been installed as an opencode tool since 2026-07-24 and has answered
  "I am dormant" to every request the coder has ever made, because BLARAI_RESEARCH_DOCS was set
  NOWHERE outside docs and tests. state/research-usage.jsonl records 212 lookups, every one of
  them from `plan_grounding` (blarai's 14B planner) and not one from `search_docs_cli`.

  DURABILITY is the acceptance bar (operator, 2026-07-30): a fix must survive many uses, device
  reboots and complex projects. So the arming does NOT travel by environment inheritance. It lives
  in a committed file -- research_docs in configs/fleet-driver.json -- and tools/search_docs.py
  RE-READS that file at the point of use on every call. A process that never met this launcher (an
  already-running session, a crash relaunch, the first run after a reboot) resolves the same answer
  from the same file, because there is no ambient state to have lost. The environment can only ever
  take the capability AWAY (an operator emergency stop), never grant it.

    Get-ResearchArmingVerdict  PURE decision (config in -> armed/reason out), unit-tested here.
    Set-CoderResearchEnv       pre-spawn seam. It does NOT grant the capability; it banks the
                               per-spawn arming record, pins BLARAI_REPO/_PYTHON from the manifest,
                               clears a stale truthy value and propagates a deliberate stop.
    Restore-CoderResearchEnv   puts the process back.

  The tool-side gate (resolve_arming) and its own mutation coverage live in
  tools/tests/test_search_docs.py -- including the clean-process tests that are the reboot proof.

  Every scenario below kills a specific wrong implementation:
    A1-A2  the manifest's boolean true arms it; false does not
    A3-A7  DENY-BY-DEFAULT truth table: absent key / "true" string / 1 / null config all mean OFF
    B1-B3  the AMBIENT hole: a stray truthy BLARAI_RESEARCH_DOCS never arms anything
    C1-C5  the seam clears a stale value, pins the substrate when armed, restores afterwards, and
           PRESERVES an explicit operator stop (a launcher that tidies a kill away has defeated it)
    D1-D4  the arming LEDGER is written on every path with the fields a later session needs
    J      the launcher's verdict and the tool's own resolve_arming AGREE across the truth table --
           two implementations of one predicate would otherwise diverge invisibly, the ledger
           saying one thing while the coder experienced another
    E1-E4  WIRING (the built-but-called-by-nothing failure): both spawn functions call the seam
           before their Start-Process, and both restore afterwards -- asserted against the source
    F1-F2  Get-FleetDriverConfig parses research_docs strictly and fail-safes to OFF
    G1-G2  TOGGLE / mutation: with the dormancy gate removed, the dormant probe FAILS. This is the
           control that separates "correctly off" from "the test cannot see it".

  Offline + pure: no opencode, no model, no network, no coder spawn. PS 5.1 & 7 safe.
  Exit 0 if all pass, 1 on any failure. Run it normally - do NOT dot-source it.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

# A stand-in for the ConvertFrom-Json manifest (the real fleet-driver.json shape).
function New-DriverConfig {
    param($Research = $false, [string]$Python = '', [string]$BlarRoot = 'C:/Users/mrbla/blarai')
    [pscustomobject]@{
        driver = 'acp'; containment = 'off'; research_docs = $Research
        acp = [pscustomobject]@{ python = $Python; blarai_root = $BlarRoot; idle_sec = 600; max_steps = 45; spin_steps = 10 }
    }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("research-arming-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$ledger = Join-Path $sandbox 'research-arming.jsonl'
$libSrc = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fleet-lib.ps1'))

# Snapshot every variable this suite touches, so a failure mid-run cannot leave the console armed.
$snapDocs = $env:BLARAI_RESEARCH_DOCS
$snapRepo = $env:BLARAI_REPO
$snapPy = $env:BLARAI_RESEARCH_PYTHON
$snapLedger = $env:BLARAI_RESEARCH_ARMING_LOG
$snapCfg = $env:BLARAI_FLEET_DRIVER_CONFIG

try {
    Write-Host "== #1206 research-docs arming verification ==" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '-- A0. the SHIPPED manifest matches the ACKNOWLEDGED posture --' -ForegroundColor DarkCyan
    # The tripwire: this line must fail if a future change moves the capability without an LA
    # go-live + a battery-attribution window (#740 one-change-per-run) -- flipping it is
    # deliberate, never a drive-by.
    #
    # IT USED TO ASSERT THE LITERAL $false, AND THAT MADE IT A ONE-SHOT (2026-08-14). The LA
    # armed the capability in person on 2026-08-06 (ffe258a, "the capability stops being
    # furniture"). The tripwire fired, correctly -- and then stayed red for eight days,
    # announcing an authorized ceremony as a failure on every run. A red that can never go
    # green is not a tripwire; it is furniture, and it hides the next real one. #1384 is the
    # same shape one floor up: verify-fleet-driver.ps1 has asserted driver=='stdin' since the
    # acp go-live of 2026-07-11 and has been failing accurately, and unread, for a month.
    #
    # So the baseline is now DECLARED, with the change that authorized it. A drive-by flip
    # still fails -- it will not match this constant either -- but an acknowledged ceremony is
    # recorded here in the same motion that performs it, and the suite returns to green so the
    # NEXT unacknowledged change is visible. Moving this constant without an LA go-live and a
    # #740 attribution window is the thing it exists to prevent; the reviewer's question is
    # always "what authorized the new value", and the answer belongs on the line below.
    $ACKNOWLEDGED_RESEARCH_DOCS = $true   # armed 2026-08-06, LA in person, agentic ffe258a (#1206)
    Remove-Item Env:\BLARAI_FLEET_DRIVER_CONFIG -ErrorAction SilentlyContinue
    $shipped = Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh
    Assert ($shipped.research_docs -eq $ACKNOWLEDGED_RESEARCH_DOCS) `
        ("A0 shipped research_docs '$($shipped.research_docs)' == acknowledged " +
         "'$ACKNOWLEDGED_RESEARCH_DOCS' (ffe258a). If a divergence here was authorized, move the " +
         "baseline in the same commit and cite what authorized it -- otherwise it is a drive-by.")

    Write-Host ''
    Write-Host '-- A. the manifest is the authority (pure verdict) --' -ForegroundColor DarkCyan

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research $true)
    Assert ($v.Armed -eq $true) 'A1 research_docs=$true (JSON boolean) => ARMED'
    Assert ($v.Reason -match 'research_docs=true') 'A1 reason names the manifest key'

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research $false)
    Assert ($v.Armed -eq $false) 'A2 research_docs=$false => dormant'

    $cfg = New-DriverConfig; $cfg.PSObject.Properties.Remove('research_docs')
    $v = Get-ResearchArmingVerdict -Config $cfg
    Assert ($v.Armed -eq $false) 'A3 key ABSENT => dormant (deny-by-default)'
    Assert ($v.Reason -match '<absent>') 'A3 reason names the absent key'

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research 'true')
    Assert ($v.Armed -eq $false) 'A4 the STRING "true" => dormant (only a JSON boolean arms it)'

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research 1)
    Assert ($v.Armed -eq $false) 'A5 the number 1 => dormant'

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research 'yes')
    Assert ($v.Armed -eq $false) 'A6 an arbitrary truthy string => dormant'

    $v = Get-ResearchArmingVerdict -Config $null
    Assert ($v.Armed -eq $false) 'A7 NULL config (unreadable manifest) => dormant fail-safe'
    Assert ($v.Reason -match 'no fleet-driver manifest') 'A7 reason names the missing manifest'

    Write-Host ''
    Write-Host '-- B. a stray shell variable is not configuration --' -ForegroundColor DarkCyan

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research $false) -AmbientValue '1'
    Assert ($v.Armed -eq $false) 'B1 ambient BLARAI_RESEARCH_DOCS=1 + dormant manifest => still dormant'
    Assert ($v.AmbientCleared -eq $true) 'B1 the ambient value is reported as CLEARED'
    Assert ($v.Reason -match 'CLEARED a stale') 'B1 reason names the cleared ambient value'

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research $false) -AmbientValue '   '
    Assert ($v.AmbientCleared -eq $false) 'B2 whitespace-only ambient is not reported as a clear'

    $v = Get-ResearchArmingVerdict -Config (New-DriverConfig -Research $true) -AmbientValue '1'
    Assert ($v.Armed -eq $true) 'B3 an ambient value never changes an ARMED verdict'

    Write-Host ''
    Write-Host '-- C. the seam really mutates + restores the environment --' -ForegroundColor DarkCyan

    $env:BLARAI_RESEARCH_ARMING_LOG = $ledger
    # Write manifests through ConvertTo-Json, never string interpolation: a sandbox path
    # interpolated raw makes '\U' an invalid JSON escape, the parser fail-closes, and the
    # scenario silently tests the wrong thing (cost 10 minutes on 2026-07-30).
    $sandboxJsonPath = $sandbox -replace '\\', '/'
    function Write-Manifest {
        param([string]$Path, $Research, [string]$BlarRoot = 'C:/Users/mrbla/blarai')
        [pscustomobject]@{
            driver = 'acp'; containment = 'off'; research_docs = $Research
            acp = [pscustomobject]@{ python = ''; blarai_root = $BlarRoot }
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding UTF8
    }
    # Dormant manifest, with the hole pre-opened: a leaked value in this very console.
    $dormantCfg = Join-Path $sandbox 'driver-dormant.json'
    Write-Manifest -Path $dormantCfg -Research $false
    $env:BLARAI_FLEET_DRIVER_CONFIG = $dormantCfg
    $env:BLARAI_RESEARCH_DOCS = '1'          # a stale arming-era value in this very console
    $null = Get-FleetDriverConfig -Fresh
    $st = Set-CoderResearchEnv -DriverPath 'stdin' -WorkDir 'C:\wt\leg-a' -LogPath 'C:\logs\a.log'
    Assert ($st.Armed -eq $false) 'C1 dormant manifest => Set-CoderResearchEnv reports not armed'
    Assert ($null -eq $env:BLARAI_RESEARCH_DOCS) 'C1 a stale truthy BLARAI_RESEARCH_DOCS is REMOVED from the child environment'
    Restore-CoderResearchEnv -State $st
    Assert ($env:BLARAI_RESEARCH_DOCS -eq '1') 'C2 restore puts the caller''s original value back'

    $armedCfg = Join-Path $sandbox 'driver-armed.json'
    Write-Manifest -Path $armedCfg -Research $true -BlarRoot $sandboxJsonPath
    $env:BLARAI_FLEET_DRIVER_CONFIG = $armedCfg
    Remove-Item Env:\BLARAI_RESEARCH_DOCS -ErrorAction SilentlyContinue
    $null = Get-FleetDriverConfig -Fresh
    $st = Set-CoderResearchEnv -DriverPath 'acp' -WorkDir 'C:\wt\leg-b' -LogPath 'C:\logs\b.log'
    Assert ($st.Armed -eq $true) 'C3 armed manifest => Set-CoderResearchEnv reports armed'
    Assert ($null -eq $env:BLARAI_RESEARCH_DOCS) `
        'C3 arming does NOT travel by environment (the tool re-reads the manifest for itself)'
    Assert ($env:BLARAI_REPO -eq $sandboxJsonPath) 'C3 BLARAI_REPO is pinned from the manifest, not left to chance'
    Restore-CoderResearchEnv -State $st
    Assert (($null -eq $env:BLARAI_REPO) -or ($env:BLARAI_REPO -eq $snapRepo)) `
        'C4 restore drops the pin the caller did not have'

    # C5 -- the ONE direction an environment variable may still move the answer. An
    # operator kill must reach the coder's tools; a launcher that tidies it away has
    # defeated the stop.
    $env:BLARAI_FLEET_DRIVER_CONFIG = $armedCfg
    $env:BLARAI_RESEARCH_DOCS = '0'
    $null = Get-FleetDriverConfig -Fresh
    $st = Set-CoderResearchEnv -DriverPath 'stdin' -WorkDir 'C:\wt\leg-c' -LogPath 'C:\logs\c.log'
    Assert ($st.Armed -eq $false) 'C5 an explicit BLARAI_RESEARCH_DOCS=0 forces dormant against an ARMED manifest'
    Assert ($st.ForcedOff -eq $true) 'C5 the verdict names it an operator emergency stop'
    Assert ($env:BLARAI_RESEARCH_DOCS -eq '0') 'C5 the emergency stop is PRESERVED into the child, never cleared'
    Restore-CoderResearchEnv -State $st
    Remove-Item Env:\BLARAI_RESEARCH_DOCS -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '-- D. the arming is BANKED, not just decided --' -ForegroundColor DarkCyan

    Assert (Test-Path $ledger) 'D1 an arming record is appended for every spawn'
    $records = @(Get-Content $ledger | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert ($records.Count -eq 3) "D1 one record per spawn (got $($records.Count), expected 3)"
    Assert (($records | Where-Object { $_.workdir -eq 'C:\wt\leg-a' -and $_.armed -eq $false }).Count -eq 1) `
        'D2 the dormant stdin spawn banked armed=false'
    Assert (($records | Where-Object { $_.driver_path -eq 'acp' -and $_.armed -eq $true }).Count -eq 1) `
        'D2 the acp spawn banked armed=true'
    $r = $records | Where-Object { $_.driver_path -eq 'acp' } | Select-Object -First 1
    Assert ($r.iso -and $r.ts -and $r.reason -and $r.workdir -eq 'C:\wt\leg-b') `
        'D3 the record carries when / why / which worktree (answerable after the fact)'
    $forced = $records | Where-Object { $_.workdir -eq 'C:\wt\leg-c' } | Select-Object -First 1
    Assert ($forced -and $forced.armed -eq $false -and $forced.reason -match 'emergency stop') `
        'D4 an emergency-stopped run is banked as such, not as an ordinary dormant one'

    Write-Host ''
    Write-Host '-- E. WIRING: the seam is actually CALLED before each spawn --' -ForegroundColor DarkCyan
    # The recurring failure class is a control that exists and is reachable by nothing. Assert
    # against the source that BOTH spawn functions arm BEFORE their Start-Process and restore after.
    $stdinBody = [regex]::Match($libSrc, 'function Invoke-AgentRun\b[\s\S]*?\n\}\r?\n').Value
    $acpBody = [regex]::Match($libSrc, 'function Invoke-AcpCoderRun\b[\s\S]*?\n\}\r?\n').Value
    # Ordering is compared by POSITION against the FIRST Start-Process, not by a lazy regex: the
    # stdin path has two spawn branches (compiled exe / .cmd shim) and an arming call parked between
    # them would satisfy "somewhere before a Start-Process" while leaving the exe branch unarmed.
    # Both ends are anchored to the real STATEMENTS ('$researchEnv = ...' / '$p = Start-Process'):
    # this function's prose discusses Start-Process several lines above the arming call, and an
    # index check that matches a comment measures nothing (it read as a baseline failure first try).
    function Test-ArmsBeforeFirstSpawn {
        param([string]$Body)
        $arm = [regex]::Match($Body, '\$researchEnv\s*=\s*Set-CoderResearchEnv')
        $spawn = [regex]::Match($Body, '\$p\s*=\s*Start-Process')
        return $arm.Success -and $spawn.Success -and ($arm.Index -lt $spawn.Index)
    }
    Assert ($stdinBody -match "Set-CoderResearchEnv -DriverPath 'stdin'") 'E1 Invoke-AgentRun calls the arming seam'
    Assert (Test-ArmsBeforeFirstSpawn $stdinBody) `
        'E2 Invoke-AgentRun arms before its FIRST Start-Process (every spawn branch inherits the decision)'
    Assert ($acpBody -match "Set-CoderResearchEnv -DriverPath 'acp'") 'E3 Invoke-AcpCoderRun calls the arming seam'
    Assert (Test-ArmsBeforeFirstSpawn $acpBody) `
        'E3 Invoke-AcpCoderRun arms before its FIRST Start-Process'
    # Every early return in the ACP path must restore, or a bailed-out run leaks the arming sideways.
    $acpReturns = ([regex]::Matches($acpBody, 'falling back to stdin"\s*\}')).Count
    $acpRestores = ([regex]::Matches($acpBody, 'Restore-CoderResearchEnv')).Count
    Assert ($stdinBody -match 'Restore-CoderResearchEnv') 'E4 Invoke-AgentRun restores after the spawn'
    Assert ($acpRestores -ge 3) "E4 Invoke-AcpCoderRun restores on every exit path it arms past (found $acpRestores)"

    Write-Host ''
    Write-Host '-- F. the manifest parser itself --' -ForegroundColor DarkCyan

    $badCfg = Join-Path $sandbox 'driver-bad.json'
    '{ "driver": "acp", "research_docs": true,,, BROKEN' | Set-Content -Path $badCfg -Encoding UTF8
    $env:BLARAI_FLEET_DRIVER_CONFIG = $badCfg
    $parsed = Get-FleetDriverConfig -Fresh
    Assert ($parsed.research_docs -eq $false) 'F1 unparseable manifest => research_docs OFF (never arms on a broken file)'

    $strCfg = Join-Path $sandbox 'driver-string.json'
    '{ "driver": "acp", "containment": "off", "research_docs": "true", "acp": {} }' | Set-Content -Path $strCfg -Encoding UTF8
    $env:BLARAI_FLEET_DRIVER_CONFIG = $strCfg
    $parsed = Get-FleetDriverConfig -Fresh
    Assert ($parsed.research_docs -eq $false) 'F2 research_docs:"true" (string) parses to OFF'

    Write-Host ''
    Write-Host '-- G. TOGGLE: prove the probe FAILS when the gate is gone --' -ForegroundColor DarkCyan
    # C1 asserts "dormant". On its own that is indistinguishable from a probe that cannot see the
    # decision at all. Re-run the SAME probe against a copy of the verdict function with the
    # deny-by-default branch removed: it must now come back ARMED, i.e. the assertion has teeth.
    # This guards the LEDGER's honesty. The gate that actually grants the capability lives in
    # tools/search_docs.py resolve_arming and is mutation-covered by tools/tests/test_search_docs.py.
    $mutated = $libSrc -replace `
        '(?s)(function Get-ResearchArmingVerdict \{.*?\$trimmed = \(\[string\]\$AmbientValue\)\.Trim\(\))', `
        '$1
    if ($true) { return @{ Armed = $true; Reason = "MUTANT: gate removed"; AmbientCleared = $false; ForcedOff = $false } }'
    Assert ($mutated -ne $libSrc) 'G1 the mutation actually applied to the source under test'
    $mutFile = Join-Path $sandbox 'fleet-lib-mutant.ps1'
    [System.IO.File]::WriteAllText($mutFile, $mutated)
    $probe = @'
$ErrorActionPreference = 'Stop'
. "__LIB__"
$env:BLARAI_FLEET_DRIVER_CONFIG = "__CFG__"
$env:BLARAI_RESEARCH_ARMING_LOG = "__LEDGER__"
Remove-Item Env:\BLARAI_RESEARCH_DOCS -ErrorAction SilentlyContinue
$null = Get-FleetDriverConfig -Fresh
$st = Set-CoderResearchEnv -DriverPath 'stdin'
Write-Output ("ARMED=" + $st.Armed + " PINNED=" + ($null -ne $env:BLARAI_REPO))
'@
    $probeFile = Join-Path $sandbox 'probe.ps1'
    $mutLedger = Join-Path $sandbox 'mutant-arming.jsonl'
    $mkProbe = {
        param($lib)
        $probe.Replace('__LIB__', $lib).Replace('__CFG__', $dormantCfg).Replace('__LEDGER__', $mutLedger) |
            Set-Content -Path $probeFile -Encoding UTF8
        (& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $probeFile) -join ' '
    }
    $baseline = & $mkProbe (Join-Path $PSScriptRoot 'fleet-lib.ps1')
    $mutantOut = & $mkProbe $mutFile
    Assert ($baseline -match 'ARMED=False' -and $baseline -match 'PINNED=False') `
        "G2 baseline: the real gate keeps a dormant manifest dormant ($baseline)"
    Assert ($mutantOut -match 'ARMED=True' -and $mutantOut -match 'PINNED=True') `
        "G2 MUTANT: with the deny-by-default branch removed the SAME probe comes back armed ($mutantOut) -- the dormancy assertion is not vacuous"

    Write-Host ''
    Write-Host '-- H. REACHABILITY: the decision crosses a real process boundary --' -ForegroundColor DarkCyan
    # Everything above proves the variable is set in THIS process. The failure this whole ticket is
    # about is a control that exists and reaches nothing, so drive the REAL tools/search_docs.py as
    # a REAL child process under each posture, exactly as opencode's execFile does (redirected
    # stdout -- which is also the cp1252 pipe the CLI's ASCII-safe emit path exists for).
    #
    # The assertion is deliberately on `reason`, not on hits: reason='dormant' means the gate closed
    # before the index was opened, and anything else means the arming ARRIVED. That holds whether or
    # not the docset corpus happens to be staged on this box, so it never degrades into a skip.
    $cli = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\search_docs.py'
    $interp = if ($env:BLARAI_RESEARCH_PYTHON -and (Test-Path $env:BLARAI_RESEARCH_PYTHON)) { $env:BLARAI_RESEARCH_PYTHON }
              else { (Get-Command python -ErrorAction SilentlyContinue).Source }
    Assert ($cli -and (Test-Path $cli)) "H0 the CLI under test exists ($cli)"
    Assert ($interp -and (Test-Path $interp)) "H0 a python interpreter is resolvable for the child ($interp)"
    $childOut = Join-Path $sandbox 'child.json'
    $runChild = {
        param($manifest)
        $env:BLARAI_FLEET_DRIVER_CONFIG = $manifest
        $env:BLARAI_RESEARCH_USAGE_LOG = (Join-Path $sandbox 'child-usage.jsonl')  # never the real ledger
        $null = Get-FleetDriverConfig -Fresh
        $st = Set-CoderResearchEnv -DriverPath 'stdin' -WorkDir $sandbox -LogPath $childOut
        $proc = Start-Process -FilePath $interp -ArgumentList @($cli, '--json', 'json.dumps') `
            -NoNewWindow -PassThru -Wait -RedirectStandardOutput $childOut
        Restore-CoderResearchEnv -State $st
        $txt = (Get-Content $childOut -Raw -ErrorAction SilentlyContinue)
        try { return ($txt | ConvertFrom-Json) } catch { return [pscustomobject]@{ reason = "UNPARSEABLE: $txt"; exit = $proc.ExitCode } }
    }
    $dormantChild = & $runChild $dormantCfg
    Assert ($dormantChild.reason -eq 'dormant') `
        "H1 dormant manifest => the spawned CLI reports 'dormant' (got '$($dormantChild.reason)')"
    $armedChild = & $runChild $armedCfg
    Assert ($armedChild.reason -ne 'dormant') `
        "H2 armed manifest => the SAME spawned CLI is armed (got '$($armedChild.reason)') -- resolved from the manifest by the child itself, not handed to it"
    Assert ($null -ne $armedChild.available) `
        'H2 the child emitted a parseable JSON result over the redirected (cp1252) pipe'

    Write-Host ''
    Write-Host '-- J. the two implementations of the predicate AGREE --' -ForegroundColor DarkCyan
    # The arming question is now answered twice: here (to bank the ledger + pin BLARAI_REPO)
    # and inside tools/search_docs.py (which is what actually grants the capability). Two
    # implementations of one predicate is a divergence risk, and a divergence would be
    # invisible -- the ledger would say one thing while the coder experienced another.
    # Drive the SAME manifests through both and require the same verdict.
    $truthTable = @(
        @{ Label = 'boolean true';   Value = $true;   Armed = $true  },
        @{ Label = 'boolean false';  Value = $false;  Armed = $false },
        @{ Label = 'string "true"';  Value = 'true';  Armed = $false },
        @{ Label = 'number 1';       Value = 1;       Armed = $false },
        @{ Label = 'string "yes"';   Value = 'yes';   Armed = $false }
    )
    foreach ($case in $truthTable) {
        $cfgPath = Join-Path $sandbox ("agree-" + [Guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
        Write-Manifest -Path $cfgPath -Research $case.Value -BlarRoot $sandboxJsonPath
        $env:BLARAI_FLEET_DRIVER_CONFIG = $cfgPath
        Remove-Item Env:\BLARAI_RESEARCH_DOCS -ErrorAction SilentlyContinue
        $psArmed = (Get-ResearchArmingVerdict -Config (Get-FleetDriverConfig -Fresh)).Armed
        $child = & $runChild $cfgPath
        $cliArmed = ($child.reason -ne 'dormant') -and ($child.reason -ne 'unresolved')
        Assert (($psArmed -eq $case.Armed) -and ($cliArmed -eq $case.Armed)) `
            ("J research_docs = {0}: launcher={1} tool={2} (expected {3})" -f $case.Label, $psArmed, $cliArmed, $case.Armed)
    }
    # And the state neither side may collapse: an unreadable manifest is UNRESOLVED to the
    # tool, and merely not-armed to the launcher -- but never a confident "switched off".
    $gonePath = Join-Path $sandbox 'never-written.json'
    $env:BLARAI_FLEET_DRIVER_CONFIG = $gonePath
    $child = & $runChild $gonePath
    Assert ($child.reason -eq 'unresolved') `
        "J an unreadable manifest reports UNRESOLVED, not dormant (got '$($child.reason)')"
}
finally {
    # Restore the console exactly as found -- this suite arms things on purpose.
    foreach ($p in @(
        @{ N = 'BLARAI_RESEARCH_DOCS'; V = $snapDocs }, @{ N = 'BLARAI_REPO'; V = $snapRepo },
        @{ N = 'BLARAI_RESEARCH_PYTHON'; V = $snapPy }, @{ N = 'BLARAI_RESEARCH_ARMING_LOG'; V = $snapLedger },
        @{ N = 'BLARAI_FLEET_DRIVER_CONFIG'; V = $snapCfg }
    )) {
        if ($null -eq $p.V) { Remove-Item "Env:\$($p.N)" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$($p.N)" -Value $p.V -ErrorAction SilentlyContinue }
    }
    $script:_FleetDriverCfg = $null
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host 'FAILURES:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host '============================================================' -ForegroundColor Cyan
exit $(if ($script:Fail) { 1 } else { 0 })
