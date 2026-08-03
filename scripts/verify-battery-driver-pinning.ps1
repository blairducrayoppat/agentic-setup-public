#requires -Version 7.0
# verify-battery-driver-pinning.ps1 — offline locks for the #1181a driver pin (2026-07-30).
#
# #1181: the nightly battery does not measure main. The BlarAI half is pinned inside
# run-battery-night.ps1, but that script was itself being executed out of the PRIMARY
# agentic-setup checkout — a shared tree that sessions park on feature branches. On
# 2026-07-30 it sat on fix/1171-declared-surface, whose copy of the driver differed from
# main by -95/+18 lines. battery-bootstrap.ps1 is the indirection that fixes it, and these
# are its locks.
#
# Same discipline as the sibling verifiers (verify-battery-report-scorecard-scan.ps1 /
# -native-error-scoping.ps1): DRIVE THE REAL SCRIPT. Never re-implement its logic here — a
# re-implementation would pass while the bootstrap rotted. The behavioural cases below run
# the actual battery-bootstrap.ps1 against throwaway git repositories built by this file,
# with a stub driver standing in for run-battery-night.ps1 so the handoff is observable.
#
#   S1  the driver is invoked from the MEASURED tree, never from the primary.
#   S2  the state-root env var is exported before the driver is invoked.
#   S3  no failure path falls back to the primary checkout's driver.
#   S4  the run-battery-night.ps1 STATE reads use the state root, not $PSScriptRoot.
#   S5  the sibling-script (CODE) reads still use $PSScriptRoot, so they follow the pin.
#   B1  absent measured tree -> created, detached at main, driver invoked.
#   B2  the driver actually executed is the MEASURED tree's copy, not the primary's.
#   B3  the driver receives the PRIMARY checkout as its state root.
#   B4  measured tree behind main -> advanced to main before the handoff.
#   B5  measured tree DIRTY -> stand down, tree left byte-identical, morning report written.
#   B6  primary root that is really a linked worktree -> stand down.
#   B7  the driver's exit code is propagated, not swallowed.
#   B8  a driver that fails at LOAD (never reaches its own code) still leaves a stand-down
#       report -- the previous night's report must not be left standing.
#   B9  CONTROL: a driver that DID write its own report before dying keeps it.
#   C1  CONTROL / toggle-test: with the primary parked on a divergent branch, an UNPINNED
#       invocation runs the divergent driver while the pinned one runs main's. Without this
#       the whole suite could pass against a fixture where both trees were identical and
#       nothing was ever actually pinned.
#
# The BlarAI half of the pin is Sync-MeasuredTree, ~110 lines inside run-battery-night.ps1
# deciding whether the night happens at all, and nothing drove it. M1-M7 do, the same way:
# AST-extract the LIVE function and run it against throwaway git repositories.
#   M1  absent measured tree -> created, detached at main.
#   M2  behind main -> advanced.
#   M3  DIRTY -> refused, and left byte-identical (nothing is ever discarded there).
#   M4  a runtime root that is really a linked worktree -> refused.
#   M5  a runtime root with no models\ -> refused (the AO would have no weights).
#   M6  the two roots in DIFFERENT repositories -> refused.
#   M7  the contained-in-main belt: present, and the predicate proven to have teeth.
#   M8  git absent from PATH -> a stand-down, NOT a terminating error that escapes.
#
#   T8  the task-settings verifier's action check: the pinned form passes, the pre-pin form
#       passes only while the pinned bootstrap does not exist and FAILS once it does, and
#       an unrecognised target always fails.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$bootstrap = Join-Path $PSScriptRoot 'battery-bootstrap.ps1'
$launcher  = Join-Path $PSScriptRoot 'run-battery-night.ps1'
if (-not (Test-Path -LiteralPath $bootstrap)) {
    Write-Host "  [FAIL] battery-bootstrap.ps1 not found beside this verifier" -ForegroundColor Red
    Write-Host "`nRESULT: 0 passed, 1 failed"; exit 1
}
$bootSrc = Get-Content -LiteralPath $bootstrap -Raw
$launchSrc = Get-Content -LiteralPath $launcher -Raw

# ---- S1..S3: structural locks on the bootstrap ------------------------------------
$invokeLine = @($bootSrc -split "`n" | Where-Object { $_ -match '^\s*&\s*\$driver\s' })
Check "S1 the driver is invoked from the measured tree (`$driver = measured + rel path)" `
    (($bootSrc -match '\$driver\s*=\s*Join-Path\s+\$AgenticMeasured\s+\$DriverRelPath') -and $invokeLine.Count -eq 1)

$envIdx    = $bootSrc.IndexOf('$env:BLARAI_BATTERY_AGENTIC_STATE_ROOT = $AgenticPrimary')
$invokeIdx = $bootSrc.IndexOf('& $driver @driverArgs')
Check "S2 the state root is exported BEFORE the driver is invoked" `
    ($envIdx -gt 0 -and $invokeIdx -gt 0 -and $envIdx -lt $invokeIdx)

# The defect this replaces is a fallback that runs the primary's driver anyway. There must
# be exactly one invocation of a driver in the whole file, and it must be the measured one.
$anyPrimaryDriver = $bootSrc -match 'Join-Path\s+\$AgenticPrimary\s+\$DriverRelPath' -or
                    $bootSrc -match '&\s*.*\$AgenticPrimary.*run-battery-night'
Check "S3 no path invokes the PRIMARY checkout's driver (no silent fallback)" (-not $anyPrimaryDriver)

# ---- S4/S5: the state-vs-code split in the launcher --------------------------------
Check "S4 the launcher's campaign-config default resolves against the STATE root" `
    ($launchSrc -match '\$DefaultCampaignConfig\s*=\s*\(Resolve-Path\s+"\$AgenticStateRoot')
Check "S5 sibling CODE scripts still resolve via `$PSScriptRoot (so they follow the pin)" `
    (($launchSrc -match "Join-Path\s+\`$PSScriptRoot\s+'ao-ownership-lib\.ps1'") -and
     ($launchSrc -match '\$verifyTaskSettings\s*=\s*"\$PSScriptRoot'))

# S6 is a REGRESSION lock, not a design lock. verify-battery-task-settings.ps1 is CODE, so
# it follows the pin — but the campaign config it reads for T7 is STATE. Left resolving
# against $PSScriptRoot it found an empty state\ in the measured tree, failed closed, and
# reported the battery task as DRIFTED on a campaign that had not drifted. Measured: 6/1
# before this fix, 7/0 after. A conformance check that cries wolf nightly is one its reader
# learns to ignore — the #1180 lesson, one file over.
$taskSettings = Join-Path $PSScriptRoot 'verify-battery-task-settings.ps1'
$tsSrc = if (Test-Path -LiteralPath $taskSettings) { Get-Content -LiteralPath $taskSettings -Raw } else { '' }
Check "S6 the task-settings verifier reads its campaign config from the STATE root" `
    ([bool]($tsSrc -match 'BLARAI_BATTERY_AGENTIC_STATE_ROOT'))
Check "S7 the launcher hands it the DEFAULT campaign, not a side config" `
    ([bool]($launchSrc -match '-BlarRepo \$BlarRuntimeRoot -CampaignConfig \$DefaultCampaignConfig'))

# ---- fixtures: real git repositories ------------------------------------------------
function New-AgenticFixture {
    # A throwaway "primary agentic-setup": a real repo with main carrying a stub driver that
    # reports which tree it ran from and what state root it was handed.
    param([string]$DriverMarker = 'MAIN')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("bootpin-" + [guid]::NewGuid().ToString('N').Substring(0,10))
    New-Item -ItemType Directory -Force $root | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $root 'scripts') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $root 'state') | Out-Null
    $driver = @(
        'param([string]$CampaignConfig, [switch]$Now)',
        "Write-Output `"DRIVER_MARKER=$DriverMarker`"",
        'Write-Output "DRIVER_PATH=$PSCommandPath"',
        'Write-Output "STATE_ROOT=$env:BLARAI_BATTERY_AGENTIC_STATE_ROOT"',
        'Write-Output "CAMPAIGN=$CampaignConfig"',
        'Write-Output "NOW=$($Now.IsPresent)"',
        'exit 0'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $root 'scripts\run-battery-night.ps1') -Value $driver -Encoding utf8
    Push-Location $root
    try {
        git init -q -b main 2>&1 | Out-Null
        git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
        git -c user.email=v@x -c user.name=v commit -q -m "stub driver ($DriverMarker)" 2>&1 | Out-Null
    } finally { Pop-Location }
    return $root
}
function Invoke-Bootstrap {
    param([string]$Primary, [string]$Measured, [string]$CampaignConfig, [switch]$Now)
    $extra = @()
    if ($CampaignConfig) { $extra += @('-CampaignConfig', $CampaignConfig) }
    if ($Now)            { $extra += '-Now' }
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap `
        -AgenticPrimary $Primary -AgenticMeasured $Measured @extra 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
$cleanup = [System.Collections.Generic.List[string]]::new()

# ---- B1/B2/B3: the happy path ------------------------------------------------------
$p1 = New-AgenticFixture -DriverMarker 'MAIN'; $cleanup.Add($p1)
$m1 = "$p1-measured"; $cleanup.Add($m1)
$r1 = Invoke-Bootstrap -Primary $p1 -Measured $m1
Check "B1 absent measured tree is created and the driver runs" `
    (($r1.Out -match 'created tonight') -and ($r1.Out -match 'DRIVER_MARKER=MAIN'))
Check "B2 the driver that executed is the MEASURED tree's copy" `
    ([bool]($r1.Out -match [regex]::Escape($m1)))
Check "B3 the driver was handed the PRIMARY checkout as its state root" `
    ([bool]($r1.Out -match ("STATE_ROOT=" + [regex]::Escape($p1))))

# ---- B4: advance ---------------------------------------------------------------------
# Move main forward in the primary; the measured tree is now behind and must be advanced.
Push-Location $p1
try {
    Set-Content -LiteralPath (Join-Path $p1 'scripts\run-battery-night.ps1') `
        -Value ((Get-Content -LiteralPath (Join-Path $p1 'scripts\run-battery-night.ps1') -Raw) -replace 'MAIN', 'MAIN2') -Encoding utf8
    git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
    git -c user.email=v@x -c user.name=v commit -q -m "advance main" 2>&1 | Out-Null
} finally { Pop-Location }
$r4 = Invoke-Bootstrap -Primary $p1 -Measured $m1
Check "B4 a measured tree behind main is advanced before the handoff" `
    (($r4.Out -match 'advancing the pinned driver tree') -and ($r4.Out -match 'DRIVER_MARKER=MAIN2'))

# ---- B5: dirty measured tree is refused, and left untouched ---------------------------
$dirtyPath = Join-Path $m1 'scripts\run-battery-night.ps1'
Add-Content -LiteralPath $dirtyPath -Value "`n# someone's uncommitted experiment" -Encoding utf8
$hashBefore = (Get-FileHash -LiteralPath $dirtyPath -Algorithm SHA256).Hash
$r5 = Invoke-Bootstrap -Primary $p1 -Measured $m1
$hashAfter = (Get-FileHash -LiteralPath $dirtyPath -Algorithm SHA256).Hash
Check "B5a a DIRTY measured tree stands the night down" `
    (($r5.Out -match 'is DIRTY and was left untouched') -and ($r5.Out -notmatch 'DRIVER_MARKER='))
Check "B5b the dirty tree is left byte-identical (nothing discarded)" ($hashBefore -eq $hashAfter)
Check "B5c a plain-language morning report is written" `
    (Test-Path -LiteralPath (Join-Path $p1 'state\battery\MORNING-REPORT.md'))
# restore
Push-Location $m1; try { git checkout -- scripts/run-battery-night.ps1 2>&1 | Out-Null } finally { Pop-Location }

# ---- B6: a "primary" that is really a linked worktree ---------------------------------
$r6 = Invoke-Bootstrap -Primary $m1 -Measured "$p1-measured2"
Check "B6 a linked worktree passed as the primary stands the night down" `
    (($r6.Out -match 'not the primary agentic-setup checkout') -and ($r6.Out -notmatch 'DRIVER_MARKER='))

# ---- B7: exit-code propagation ---------------------------------------------------------
$p7 = New-AgenticFixture -DriverMarker 'EXIT'; $cleanup.Add($p7)
$m7 = "$p7-measured"; $cleanup.Add($m7)
Push-Location $p7
try {
    Set-Content -LiteralPath (Join-Path $p7 'scripts\run-battery-night.ps1') `
        -Value "param([string]`$CampaignConfig, [switch]`$Now)`nWrite-Output 'DRIVER_MARKER=EXIT'`nexit 42" -Encoding utf8
    git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
    git -c user.email=v@x -c user.name=v commit -q -m "failing driver" 2>&1 | Out-Null
} finally { Pop-Location }
$r7 = Invoke-Bootstrap -Primary $p7 -Measured $m7
Check "B7 the driver's exit code is propagated, not swallowed" ($r7.Code -eq 42)

# ---- C1: the toggle-test ---------------------------------------------------------------
# Park the primary on a divergent feature branch — the exact 2026-07-30 condition. The
# UNPINNED invocation (what the scheduled task used to do) must run the DIVERGENT driver;
# the pinned one must still run main's. If both ran the same thing, nothing is pinned and
# every check above would be vacuous.
$p8 = New-AgenticFixture -DriverMarker 'MAIN'; $cleanup.Add($p8)
$m8 = "$p8-measured"; $cleanup.Add($m8)
Push-Location $p8
try {
    git checkout -q -b feat/parked 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $p8 'scripts\run-battery-night.ps1') `
        -Value ((Get-Content -LiteralPath (Join-Path $p8 'scripts\run-battery-night.ps1') -Raw) -replace 'MAIN', 'PARKED_BRANCH') -Encoding utf8
    git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
    git -c user.email=v@x -c user.name=v commit -q -m "divergent work parked in the primary tree" 2>&1 | Out-Null
} finally { Pop-Location }

$unpinned = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $p8 'scripts\run-battery-night.ps1') 2>&1 | Out-String
Check "C1a CONTROL: the UNPINNED invocation runs the parked branch's driver (the defect is real)" `
    ([bool]($unpinned -match 'DRIVER_MARKER=PARKED_BRANCH'))
$r8 = Invoke-Bootstrap -Primary $p8 -Measured $m8
Check "C1b the PINNED invocation runs main's driver, not the parked branch's" `
    (($r8.Out -match 'DRIVER_MARKER=MAIN') -and ($r8.Out -notmatch 'PARKED_BRANCH'))

# ---- B8/B9: a driver that never reaches its own code -----------------------------------
# $HandedOff is set BEFORE `& $driver`, so it records this script's optimism about invoking
# the driver, not the driver reaching a line of its own. A driver that fails at LOAD -- a
# syntax error merged to agentic main, which merges nightly, or the file removed between the
# Test-Path and the invoke -- writes nothing, and a trap that deferred to "the driver owns
# the report" would leave MORNING-REPORT.md holding the PREVIOUS night. That is the stale
# report this whole path exists to prevent, reopened at the last three lines.
$p9 = New-AgenticFixture -DriverMarker 'BROKEN'; $cleanup.Add($p9)
$m9 = "$p9-measured"; $cleanup.Add($m9)
Push-Location $p9
try {
    # Unterminated string: this fails at PARSE, so not one statement of it ever executes.
    Set-Content -LiteralPath (Join-Path $p9 'scripts\run-battery-night.ps1') `
        -Value "param([string]`$CampaignConfig, [switch]`$Now)`nWrite-Output 'DRIVER_MARKER=BROKEN" -Encoding utf8
    git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
    git -c user.email=v@x -c user.name=v commit -q -m 'driver that does not parse' 2>&1 | Out-Null
} finally { Pop-Location }
$reportPath9 = Join-Path $p9 'state\battery\MORNING-REPORT.md'
# Seed a previous night's report, so "left stale" is observable rather than inferred from
# an absent file. This is the operator's actual morning surface.
New-Item -ItemType Directory -Force (Split-Path $reportPath9) | Out-Null
Set-Content -LiteralPath $reportPath9 -Value '# LAST NIGHT: everything was GREEN' -Encoding utf8
$r9 = Invoke-Bootstrap -Primary $p9 -Measured $m9
$report9 = if (Test-Path -LiteralPath $reportPath9) { Get-Content -LiteralPath $reportPath9 -Raw } else { '' }
Check "B8a a driver that fails at LOAD does not leave last night's report standing" `
    ($report9 -notmatch 'LAST NIGHT: everything was GREEN')
Check "B8b it says the launcher was started but reported nothing" `
    ([bool]($report9 -match 'stood down') -and [bool]($report9 -match 'started but stopped with an error'))
Check "B8c and it still exits non-zero (a launched-then-died driver is a failure)" ($r9.Code -ne 0)

# B9 CONTROL / the other half: a driver that DOES write its own report and then dies must
# keep it. Without this, B8 could be satisfied by a trap that clobbers every driver report.
$p10 = New-AgenticFixture -DriverMarker 'REPORTS'; $cleanup.Add($p10)
$m10 = "$p10-measured"; $cleanup.Add($m10)
Push-Location $p10
try {
    $reportingDriver = @(
        'param([string]$CampaignConfig, [switch]$Now)',
        'Write-Output "DRIVER_MARKER=REPORTS"',
        '$d = Join-Path $env:BLARAI_BATTERY_AGENTIC_STATE_ROOT "state\battery"',
        'New-Item -ItemType Directory -Force $d | Out-Null',
        'Set-Content -LiteralPath (Join-Path $d "MORNING-REPORT.md") -Value "# THE DRIVER OWN ACCOUNT" -Encoding utf8',
        'throw "died after reporting"'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $p10 'scripts\run-battery-night.ps1') -Value $reportingDriver -Encoding utf8
    git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
    git -c user.email=v@x -c user.name=v commit -q -m 'driver that reports then dies' 2>&1 | Out-Null
} finally { Pop-Location }
$r10 = Invoke-Bootstrap -Primary $p10 -Measured $m10
$report10 = Get-Content -LiteralPath (Join-Path $p10 'state\battery\MORNING-REPORT.md') -Raw
Check "B9 a driver that DID report before dying keeps its own account (the trap defers)" `
    ([bool]($report10 -match 'THE DRIVER OWN ACCOUNT'))

# C3 CONTROL / toggle-test for B8. Inject the PRE-FIX decision -- "past the handoff, assume
# the driver owns the report" -- into a copy of the real bootstrap and drive the SAME broken
# driver. The stale report must SURVIVE. Without this, B8a could be passing because the
# fixture never reproduced the defect rather than because the trap now catches it.
$preFixBoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bootpre-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
Set-Content -LiteralPath $preFixBoot -Encoding utf8 `
    -Value ($bootSrc -replace '\$already = Test-ReportWrittenTonight', '$already = $true')
$p11 = New-AgenticFixture -DriverMarker 'BROKEN2'; $cleanup.Add($p11)
$m11 = "$p11-measured"; $cleanup.Add($m11)
Push-Location $p11
try {
    Set-Content -LiteralPath (Join-Path $p11 'scripts\run-battery-night.ps1') `
        -Value "param([string]`$CampaignConfig, [switch]`$Now)`nWrite-Output 'DRIVER_MARKER=BROKEN2" -Encoding utf8
    git -c user.email=v@x -c user.name=v add scripts/run-battery-night.ps1 2>&1 | Out-Null
    git -c user.email=v@x -c user.name=v commit -q -m 'driver that does not parse' 2>&1 | Out-Null
} finally { Pop-Location }
$reportPath11 = Join-Path $p11 'state\battery\MORNING-REPORT.md'
New-Item -ItemType Directory -Force (Split-Path $reportPath11) | Out-Null
Set-Content -LiteralPath $reportPath11 -Value '# LAST NIGHT: everything was GREEN' -Encoding utf8
& pwsh -NoProfile -ExecutionPolicy Bypass -File $preFixBoot -AgenticPrimary $p11 -AgenticMeasured $m11 2>&1 | Out-Null
$report11 = Get-Content -LiteralPath $reportPath11 -Raw
Check "C3 control: the PRE-FIX trap DOES leave last night's report standing (the defect is real)" `
    ([bool]($report11 -match 'LAST NIGHT: everything was GREEN'))
Remove-Item -LiteralPath $preFixBoot -Force -ErrorAction SilentlyContinue

# ---- M1..M8: the BlarAI half of the pin, driven --------------------------------------
# Extract the LIVE functions rather than re-implementing them: a re-implementation would go
# on passing while run-battery-night.ps1 rotted, which is the failure this whole file exists
# to avoid one level up.
$launchAst = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)
function Get-LiveFunction([string]$Name) {
    $f = @($launchAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $Name }, $true))
    if ($f.Count -eq 1) { return $f[0].Extent.Text }
    return $null
}
$syncSrc = Get-LiveFunction 'Sync-MeasuredTree'
$gitReadSrc = Get-LiveFunction 'Invoke-GitRead'
Check "M0 Sync-MeasuredTree and Invoke-GitRead are isolatable from the launcher" `
    (($null -ne $syncSrc) -and ($null -ne $gitReadSrc))

if ($syncSrc -and $gitReadSrc) {
    # A throwaway "BlarAI installation": a primary checkout (its .git is a DIRECTORY) with
    # main, and the models\ directory Sync-MeasuredTree requires as proof of the weights.
    function New-BlarFixture {
        param([switch]$NoModels)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("blarpin-" + [guid]::NewGuid().ToString('N').Substring(0,10))
        New-Item -ItemType Directory -Force $root | Out-Null
        if (-not $NoModels) { New-Item -ItemType Directory -Force (Join-Path $root 'models') | Out-Null }
        Set-Content -LiteralPath (Join-Path $root 'runner.txt') -Value 'MAIN' -Encoding utf8
        Push-Location $root
        try {
            git init -q -b main 2>&1 | Out-Null
            git -c user.email=v@x -c user.name=v add runner.txt 2>&1 | Out-Null
            git -c user.email=v@x -c user.name=v commit -q -m 'main' 2>&1 | Out-Null
        } finally { Pop-Location }
        return $root
    }
    function Invoke-Sync {
        # Drives the REAL function. Write-Log is the one thing it needs from the launcher's
        # surrounding scope; everything else it derives from the roots it is handed.
        param([string]$RuntimeRoot, [string]$MeasuredRoot, [string]$PathOverride)
        $sb = [scriptblock]::Create(@"
function Write-Log([string]`$msg) { }
$gitReadSrc
$syncSrc
Sync-MeasuredTree -RuntimeRoot '$RuntimeRoot' -MeasuredRoot '$MeasuredRoot'
"@)
        if ($PSBoundParameters.ContainsKey('PathOverride')) {
            $prevPath = $env:PATH
            try { $env:PATH = $PathOverride; return (& $sb) } finally { $env:PATH = $prevPath }
        }
        return (& $sb)
    }

    $b1 = New-BlarFixture; $cleanup.Add($b1)
    $bm1 = "$b1-measured"; $cleanup.Add($bm1)
    $m1r = Invoke-Sync -RuntimeRoot $b1 -MeasuredRoot $bm1
    Check "M1a an absent measured tree is created and pinned" ($m1r.Ok -and $m1r.Created)
    Check "M1b the created tree is a LINKED worktree (its .git is a pointer file)" `
        (Test-Path -LiteralPath (Join-Path $bm1 '.git') -PathType Leaf)

    # M2: move main forward; the measured tree is behind and must be advanced.
    Set-Content -LiteralPath (Join-Path $b1 'runner.txt') -Value 'MAIN2' -Encoding utf8
    Push-Location $b1
    try {
        git -c user.email=v@x -c user.name=v commit -q -am 'advance main' 2>&1 | Out-Null
    } finally { Pop-Location }
    $m2r = Invoke-Sync -RuntimeRoot $b1 -MeasuredRoot $bm1
    Check "M2a a measured tree behind main is advanced" ($m2r.Ok -and -not $m2r.Created)
    Check "M2b the advance actually moved the working tree, not just the ref" `
        ((Get-Content -LiteralPath (Join-Path $bm1 'runner.txt') -Raw).Trim() -eq 'MAIN2')

    # M3: a dirty measured tree is refused, and left exactly as it was.
    $dirtyFile = Join-Path $bm1 'runner.txt'
    Add-Content -LiteralPath $dirtyFile -Value "`nsomeone's uncommitted experiment" -Encoding utf8
    $hashBefore = (Get-FileHash -LiteralPath $dirtyFile -Algorithm SHA256).Hash
    $m3r = Invoke-Sync -RuntimeRoot $b1 -MeasuredRoot $bm1
    $hashAfter = (Get-FileHash -LiteralPath $dirtyFile -Algorithm SHA256).Hash
    Check "M3a a DIRTY measured tree is REFUSED (stand-down, never a fallback)" `
        ((-not $m3r.Ok) -and ($m3r.Reason -match 'is DIRTY and was left untouched'))
    Check "M3b the dirty tree is left byte-identical (nothing is ever discarded)" ($hashBefore -eq $hashAfter)
    Push-Location $bm1; try { git checkout -- runner.txt 2>&1 | Out-Null } finally { Pop-Location }

    # M4: the runtime root must be the PRIMARY checkout - it is the only tree holding the
    # gitignored weights. Handing it a linked worktree is the catastrophic mix-up.
    $m4r = Invoke-Sync -RuntimeRoot $bm1 -MeasuredRoot "$b1-measured4"
    Check "M4 a linked worktree passed as the RUNTIME root is refused" `
        ((-not $m4r.Ok) -and ($m4r.Reason -match 'not the primary BlarAI checkout'))

    # M5: no models\ = an AO with no weights to load.
    $b5 = New-BlarFixture -NoModels; $cleanup.Add($b5)
    $m5r = Invoke-Sync -RuntimeRoot $b5 -MeasuredRoot "$b5-measured"
    Check "M5 a runtime root with no models\ is refused (no weights to boot on)" `
        ((-not $m5r.Ok) -and ($m5r.Reason -match 'no models'))

    # M6: two roots, two repositories. The measured tree is a real linked worktree, just of
    # somebody else's repo - so every earlier check passes and only the common-dir comparison
    # catches it.
    $b6 = New-BlarFixture; $cleanup.Add($b6)
    $bm6 = "$b6-foreign"; $cleanup.Add($bm6)
    Push-Location $b6
    try { git worktree add --detach $bm6 main 2>&1 | Out-Null } finally { Pop-Location }
    $m6r = Invoke-Sync -RuntimeRoot $b1 -MeasuredRoot $bm6
    Check "M6 a measured tree belonging to a DIFFERENT repository is refused" `
        ((-not $m6r.Ok) -and ($m6r.Reason -match 'belongs to a different repository'))

    # M7: the contained-in-main belt. It is deliberately unreachable through the steps above
    # -- `switch --detach <sha>` cannot land anywhere but <sha>, and <sha> came from
    # `rev-parse main` moments earlier -- so it is locked structurally, and the PREDICATE it
    # rests on is then proven against a known non-ancestor. A belt whose predicate is wrong
    # would pass a structural check and protect nothing.
    Check "M7a the pin checks containment in main with merge-base --is-ancestor" `
        ([bool]($syncSrc -match "merge-base', '--is-ancestor'"))
    Push-Location $b6
    try {
        git checkout -q -b feat/off-main 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $b6 'runner.txt') -Value 'OFF_MAIN' -Encoding utf8
        git -c user.email=v@x -c user.name=v commit -q -am 'off main' 2>&1 | Out-Null
        $offSha = (git rev-parse HEAD 2>&1 | Out-String).Trim()
        git merge-base --is-ancestor $offSha main 2>&1 | Out-Null
        $ancCode = $LASTEXITCODE
    } finally { Pop-Location }
    Check "M7b the predicate has teeth: an unmerged commit is NOT an ancestor of main" ($ancCode -ne 0)

    # M8: git missing from PATH raises CommandNotFoundException, which is TERMINATING even
    # with the native-exit preference scoped off. Uncaught it escapes the caller entirely,
    # so no stand-down report is written and the morning read still shows LAST night's
    # result. It must come back as a refusal like any other.
    $b8 = New-BlarFixture; $cleanup.Add($b8)
    $m8Ok = $false; $m8Threw = $false; $m8r = $null
    try { $m8r = Invoke-Sync -RuntimeRoot $b8 -MeasuredRoot "$b8-measured" -PathOverride 'C:\nonexistent-path-for-this-test' }
    catch { $m8Threw = $true }
    if ($null -ne $m8r) { $m8Ok = (-not $m8r.Ok) -and ($m8r.Reason -match 'git could not be run|could not read') }
    Check "M8 git absent from PATH is a stand-down, not a terminating error that escapes" `
        ((-not $m8Threw) -and $m8Ok)
}

# ---- T8: the scheduled task's ACTION is checked, and the ratchet works ----------------
# T1-T7 all described HOW the task runs; none described WHAT it runs. Re-registering the
# task with the pre-pin -File ...\agentic-setup\scripts\run-battery-night.ps1 would restore
# the entire #1181 defect while every check still reported "conform" (the 2026-07-09
# incident is proof this task does get re-registered by scripts nobody re-reads).
$taskVerifier = Join-Path $PSScriptRoot 'verify-battery-task-settings.ps1'
$tvAst = if (Test-Path -LiteralPath $taskVerifier) {
    [System.Management.Automation.Language.Parser]::ParseFile($taskVerifier, [ref]$null, [ref]$null)
} else { $null }
# @() wraps the WHOLE conditional, not the inner value (#1045): a one-element array returned
# from an `if` is UNROLLED on assignment, and a bare .Count on the scalar that falls out is a
# terminating error under the StrictMode this file runs with.
$t8Switch = @(if ($tvAst) {
    $tvAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.SwitchStatementAst] -and
        $n.Condition.Extent.Text -eq '$t8Class' }, $true)
})
$t8ClassFn = @(if ($tvAst) {
    $tvAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Get-T8Class' }, $true)
})
Check "T8a the action check and its classifier are present in the task-settings verifier" `
    (($t8Switch.Count -eq 1) -and ($t8ClassFn.Count -eq 1))

if ($t8Switch.Count -eq 1 -and $t8ClassFn.Count -eq 1) {
    # Drive the LIVE classifier + the LIVE decision, with Check shadowed so the verdict is
    # capturable. Offline: no scheduled task is read, created or touched.
    function Invoke-T8 {
        param([string]$Action, [string]$Pinned, [string]$Legacy, [bool]$PinnedPresent)
        $sb = [scriptblock]::Create(@"
`$verdict = `$null
function Check([string]`$n, [bool]`$ok) { `$script:t8verdict = `$ok }
function Section(`$t) { }
$($t8ClassFn[0].Extent.Text)
`$PinnedBootstrap = '$Pinned'
`$LegacyDriver = '$Legacy'
`$t8Action = '$Action'
`$t8PinnedPresent = `$$PinnedPresent
`$t8Class = Get-T8Class `$t8Action `$PinnedBootstrap `$LegacyDriver
$($t8Switch[0].Extent.Text)
[pscustomobject]@{ Class = `$t8Class; Ok = `$script:t8verdict }
"@)
        & $sb
    }
    $pinnedPath = 'C:\Users\mrbla\agentic-battery-measured\scripts\battery-bootstrap.ps1'
    $legacyPath = 'C:\Users\mrbla\agentic-setup\scripts\run-battery-night.ps1'
    $act = { param($p) "pwsh.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $p" }

    $t8a = Invoke-T8 -Action (& $act $pinnedPath) -Pinned $pinnedPath -Legacy $legacyPath -PinnedPresent $true
    Check "T8b the pinned bootstrap as the action PASSES" (($t8a.Class -eq 'pinned') -and $t8a.Ok)

    $t8b = Invoke-T8 -Action (& $act $legacyPath) -Pinned $pinnedPath -Legacy $legacyPath -PinnedPresent $false
    Check "T8c the pre-pin driver PASSES while the pinned bootstrap does not exist (no nightly false alarm)" `
        (($t8b.Class -eq 'legacy') -and $t8b.Ok)

    $t8c = Invoke-T8 -Action (& $act $legacyPath) -Pinned $pinnedPath -Legacy $legacyPath -PinnedPresent $true
    Check "T8d the pre-pin driver FAILS once the pinned bootstrap exists (the ratchet closes)" `
        (($t8c.Class -eq 'legacy') -and -not $t8c.Ok)

    $t8d = Invoke-T8 -Action (& $act 'C:\somewhere\else\other-runner.ps1') -Pinned $pinnedPath -Legacy $legacyPath -PinnedPresent $true
    Check "T8e an unrecognised action target always FAILS" (($t8d.Class -eq 'unrecognised') -and -not $t8d.Ok)
}

# ---- B10: the parameters actually REACH the driver ------------------------------------
# The bootstrap built its handoff with an ARRAY splat, which PowerShell passes POSITIONALLY,
# so -CampaignConfig <path> died with "A positional parameter cannot be found". Every
# side-config run stood down before the driver ran. No test caught it because Invoke-Bootstrap
# never passed a campaign config -- the line was unreachable from the suite. Found by the
# pre-repoint dry run instead, which is the wrong place to find it.
$pB = New-AgenticFixture -DriverMarker 'ARGS'; $cleanup.Add($pB)
$mB = "$pB-measured"; $cleanup.Add($mB)
$cfgB = Join-Path $pB 'state\side-campaign.json'
Set-Content -LiteralPath $cfgB -Value '{"campaign":"side"}' -Encoding utf8
$rB = Invoke-Bootstrap -Primary $pB -Measured $mB -CampaignConfig $cfgB -Now
Check "B10a -CampaignConfig binds by NAME and reaches the driver" `
    ([bool]($rB.Out -match ("CAMPAIGN=" + [regex]::Escape($cfgB))))
Check "B10b -Now binds as a switch and reaches the driver" ([bool]($rB.Out -match 'NOW=True'))
Check "B10c the driver ran at all (no positional-binding stand-down)" `
    (($rB.Out -match 'DRIVER_MARKER=ARGS') -and ($rB.Out -notmatch 'positional parameter'))

foreach ($d in $cleanup) {
    if (Test-Path -LiteralPath $d) {
        # Worktree admin entries first, so the repo is not left with dangling registrations.
        try { git -C $d worktree prune 2>&1 | Out-Null } catch { }
        Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "RESULT: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
