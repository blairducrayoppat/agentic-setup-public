#requires -Version 7.0
# verify-battery-report-scorecard-scan.ps1 — offline locks for the #1180 fix (2026-07-30).
#
# run-battery-night.ps1's postlude builds MORNING-REPORT.md by scanning $NightDir\scorecards
# for *.json. battery.py writes the AGGREGATE battery-summary.json into that same directory,
# so the sweep picked it up as a per-job scorecard. It has no job_id, and ao-ownership-lib.ps1
# puts StrictMode Latest in caller scope, so reading that missing member is a TERMINATING
# error -- caught, and reported as "unreadable scorecard: battery-summary.json".
#
# Nothing was ever unreadable. But that line is the ONLY way this report can announce that a
# night's evidence could not be read, and it fired on every night for weeks. A fail-loud
# control that cries wolf nightly is a fail-loud control that has been switched off by its
# own reader. That is what these locks protect.
#
# Same discipline as the sibling verifiers (verify-battery-native-error-scoping.ps1 /
# -pass-banking-freeze.ps1): AST-extract the LIVE block from the launcher and DRIVE it
# against fixtures. Never re-implement the logic here -- a re-implementation would pass
# while the launcher rotted.
#
#   S1  the enumeration excludes battery-summary.json by name.
#   S2  the loop tests job_id MEMBERSHIP (StrictMode-safe), not truthiness.
#   S3  the parse-failure path is distinguishable from the wrong-shape path.
#   B1  LIVE block, realistic night (2 real scorecards + battery-summary.json)
#       -> 2 job lines, no unreadable line, no skipped line.
#   B2  LIVE block, a genuinely corrupt .json -> exactly one UNREADABLE line naming it.
#   B3  LIVE block, valid JSON that is not a scorecard -> "skipped", NOT "unreadable".
#   B4  LIVE block, empty attribution -> the label is omitted, not rendered bare.
#   B5  LIVE block, populated attribution -> the label IS rendered.
#   C1  CONTROL: the PRE-#1180 shape, same clean fixture, DOES emit "unreadable scorecard"
#       -- without this the whole suite could pass against a fixture that never
#       exercised the bug (the toggle-test: the probe must fail when the lock is off).
#   T6  the #1181a banner keys on CONTAINMENT, not the branch name: a correctly pinned
#       night (detached HEAD, commit contained in main, clean tree) emits NO banner, while
#       an uncontained commit, a dirty tree and an unanswerable stamp each still do.
#   C3  CONTROL: the branch-NAME predicate DOES banner that same pinned night -- the third
#       instance of "a fail-loud control that fires every normal night is one already
#       switched off" (#1180's line; T7 in verify-battery-task-settings.ps1).
#   D1/D2  the driver's own commit reaches the morning report, and renders as NOT RECORDED
#       rather than vanishing when it cannot be read.
Set-StrictMode -Version Latest   # the launcher's postlude runs under this; so must the block
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)

# ---- extract the LIVE block: the $scorecards assignment + the foreach that consumes it ----
$scAssign = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$scorecards' }, $true))
$scLoop = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $n.Variable.Extent.Text -eq '$sc' }, $true))
if ($scAssign.Count -ne 1 -or $scLoop.Count -ne 1) {
    Write-Host "  [FAIL] could not isolate the scorecard scan (assign=$($scAssign.Count) loop=$($scLoop.Count))" -ForegroundColor Red
    Write-Host "`nRESULT: 0 passed, 1 failed (block not found — cannot drive behavior)"
    exit 1
}
$script:liveSrc = $scAssign[0].Extent.Text + "`n" + $scLoop[0].Extent.Text

# ---- S1/S2/S3: structural locks on the live source -------------------------------
Check "S1 the enumeration excludes battery-summary.json by name" `
    ($scAssign[0].Extent.Text -match "battery-summary\.json")
Check "S2 the loop tests job_id membership (StrictMode-safe), not truthiness" `
    ($scLoop[0].Extent.Text -match "PSObject\.Properties\.Name")
Check "S3 the parse-failure path is distinguishable from the wrong-shape path" `
    (($scLoop[0].Extent.Text -match "not valid JSON") -and ($scLoop[0].Extent.Text -match "no job_id"))

# ---- fixture builder: a night directory, seeded from LAST NIGHT'S REAL scorecards ----
function New-NightFixture {
    param([switch]$Corrupt, [switch]$NonScorecard, [string]$Attribution = "",
          [string]$Branch = "main", [string]$TreeState = "clean", [switch]$NoVersions,
          [switch]$Empty, [switch]$Partial, [string]$OnMain = "yes", [switch]$NoOnMain,
          [switch]$NoMode)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("nb-1180-{0}" -f [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'scorecards')
    $sd = Join-Path $dir 'scorecards'

    foreach ($j in @('B2','B4')) {
        $card = [ordered]@{
            job_id = $j; verdict = 'GREEN'; attribution = $Attribution
            wall_clock_s = 1399.5; notes = 'a note'
            evidence = [ordered]@{ mode = 'plan-graph'; guest_agreement = 'agree' }
        }
        if (-not $NoVersions) {
            $card['versions'] = [ordered]@{
                battery_runner = 'v1'; blarai = 'abc1234'
                blarai_branch = $Branch; blarai_tree = $TreeState
            }
            # -NoOnMain is the pre-#1181-fix scorecard shape: a stamp that carries the
            # branch name and cannot answer the containment question at all.
            if (-not $NoOnMain) { $card['versions']['blarai_on_main'] = $OnMain }
        }
        $card | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $sd "$j.scorecard.json")
    }
    # The aggregate the launcher was mistaking for a scorecard - shape-accurate: valid JSON,
    # no job_id, and a 'jobs' array. This is the file that caused #1180.
    ([ordered]@{ schema = 'battery-summary/v1'; total = 2
                 verdicts = [ordered]@{ GREEN = 2 }
                 jobs = @([ordered]@{ job_id = 'B2' }, [ordered]@{ job_id = 'B4' }) } |
        ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $sd 'battery-summary.json')

    if ($Corrupt)      { Set-Content -LiteralPath (Join-Path $sd 'B9.scorecard.json') -Value '{ "job_id": "B9", TRUNCATED' }
    if ($NonScorecard) { Set-Content -LiteralPath (Join-Path $sd 'probe-notes.json')  -Value '{ "kind": "notes", "text": "hello" }' }
    # The two shapes that ESCAPED the loop before containment was restored. Neither throws
    # at the parse: an empty file yields $null silently, and a partial card parses fine and
    # only dies on the first missing member. Both took the whole postlude with them.
    if ($Empty)        { Set-Content -LiteralPath (Join-Path $sd 'B7.scorecard.json') -Value '' -NoNewline }
    if ($Partial)      { Set-Content -LiteralPath (Join-Path $sd 'B8.scorecard.json') -Value '{ "job_id": "B8" }' }
    # A COMPLETE card whose evidence block carries no `mode`. This is not a damaged file --
    # it is what the driver writes for a job that stalls before the plan graph exists, and it
    # answers every question the report asks. Shape taken verbatim from B9's first ever run,
    # 2026-08-07, which reported as LOST while naming its own cause in `notes`.
    if ($NoMode) {
        ([ordered]@{
            job_id = 'B9'; verdict = 'STALLED'; attribution = 'HARNESS'
            wall_clock_s = 283.3; notes = 'approve did not fire EXECUTE: No response from the Assistant Orchestrator.'
            evidence = [ordered]@{ oracle_status = 'unknown'; failure_class = 'HARNESS-BUDGET' }
            versions = [ordered]@{ battery_runner = 'v1'; blarai = 'abc1234'
                                   blarai_branch = 'detached'; blarai_tree = 'clean'; blarai_on_main = 'yes' }
        } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $sd 'B9.scorecard.json')
    }
    $dir
}

function Invoke-ScanBlock {
    param([Parameter(Mandatory)][string]$NightDirPath, [Parameter(Mandatory)][string]$Src,
          [string]$NoteSrc, [string]$DriverSrc, [string]$DriverStamp = '')
    $NightDir = $NightDirPath
    $lines = @(); $verdicts = @{}
    $green = 0; $planEligible = 0; $flatQueue = 0; $modeUnknown = 0
    $measuredTree = $null; $measuredClean = $false
    . ([scriptblock]::Create($Src))
    if ($NoteSrc) { . ([scriptblock]::Create($NoteSrc)) }
    if ($DriverSrc) { . ([scriptblock]::Create($DriverSrc)) }
    [pscustomobject]@{ Lines = $lines; Verdicts = $verdicts; Green = $green
                       MeasuredTree = $measuredTree; MeasuredClean = $measuredClean }
}

# ---- extract the #1181 tree-note block (drives T1-T6) ----------------------------
$noteIf = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq '$measuredTree' }, $true))
$script:noteSrc = if ($noteIf.Count -eq 1) { $noteIf[0].Extent.Text } else { $null }

# ---- extract the #1181 driver-stamp block (drives D1-D2) -------------------------
$driverIf = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq '$DriverStamp' }, $true))
$script:driverSrc = if ($driverIf.Count -eq 1) { $driverIf[0].Extent.Text } else { $null }

# ---- B1: a realistic night -------------------------------------------------------
$f1 = New-NightFixture
$r1 = Invoke-ScanBlock -NightDirPath $f1 -Src $script:liveSrc
$jobLines = @($r1.Lines | Where-Object { $_ -match '^\* \*\*B[24]\*\*' })
Check "B1a realistic night: both job lines rendered (got $($jobLines.Count))" ($jobLines.Count -eq 2)
Check "B1b realistic night: NO 'unreadable' line" (-not ($r1.Lines -match 'UNREADABLE|unreadable'))
Check "B1c realistic night: NO 'skipped' line (the summary is excluded, not skipped)" (-not ($r1.Lines -match 'skipped'))
Check "B1d realistic night: verdicts collected for both jobs" ($r1.Verdicts.Count -eq 2)

# ---- B2: a genuinely corrupt scorecard -------------------------------------------
$f2 = New-NightFixture -Corrupt
$r2 = Invoke-ScanBlock -NightDirPath $f2 -Src $script:liveSrc
$unreadable = @($r2.Lines | Where-Object { $_ -match 'UNREADABLE' })
Check "B2a corrupt scorecard: exactly one UNREADABLE line (got $($unreadable.Count))" ($unreadable.Count -eq 1)
Check "B2b corrupt scorecard: the line names the file" ([bool]($unreadable -match 'B9\.scorecard\.json'))
Check "B2c corrupt scorecard: says evidence is LOST (the loud case stays loud)" ([bool]($unreadable -match 'LOST'))
Check "B2d corrupt scorecard: the healthy jobs still render" (@($r2.Lines | Where-Object { $_ -match '^\* \*\*B[24]\*\*' }).Count -eq 2)

# ---- B3: valid JSON that is not a scorecard --------------------------------------
$f3 = New-NightFixture -NonScorecard
$r3 = Invoke-ScanBlock -NightDirPath $f3 -Src $script:liveSrc
Check "B3a non-scorecard: reported as skipped, not unreadable" ([bool]($r3.Lines -match 'skipped') -and -not [bool]($r3.Lines -match 'UNREADABLE'))
Check "B3b non-scorecard: the line names the file" ([bool]($r3.Lines -match 'probe-notes\.json'))

# ---- B4/B5: the attribution label --------------------------------------------------
Check "B4 empty attribution: the bare label is NOT rendered" (-not [bool]($r1.Lines -match 'attribution:'))
$f5 = New-NightFixture -Attribution 'coder-brief #1179'
$r5 = Invoke-ScanBlock -NightDirPath $f5 -Src $script:liveSrc
Check "B5 populated attribution: the label IS rendered" ([bool]($r5.Lines -match 'attribution: coder-brief #1179'))

# ---- C1 CONTROL: the pre-#1180 shape must FAIL on the same clean fixture ----------
# Without this the suite could pass against a fixture that never reproduced the bug.
$preFixSrc = @'
$scorecards = Get-ChildItem "$NightDir\scorecards" -Filter "*.json" -ErrorAction SilentlyContinue
foreach ($sc in $scorecards) {
    try {
        $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json
        if ($d.job_id) { $verdicts[$d.job_id] = $d.verdict }
    } catch { $lines += "* unreadable scorecard: $($sc.Name)" }
}
'@
$rc = Invoke-ScanBlock -NightDirPath $f1 -Src $preFixSrc
Check "C1 control: the PRE-#1180 shape DOES emit 'unreadable scorecard' on the same clean night" `
    ([bool]($rc.Lines -match 'unreadable scorecard: battery-summary\.json'))

# ---- B6/B7 CONTAINMENT: one bad card must never cost the night's report -----------
# These two shapes ESCAPED the loop in the first cut of #1180, landed in the postlude catch
# at run-battery-night.ps1:885, and produced NO MORNING-REPORT.md and NO banking. Neither is
# caught by B2's corrupt fixture, because neither throws at the parse:
#   empty   -> '' | ConvertFrom-Json returns $null WITHOUT throwing; the next member read dies
#   partial -> valid JSON with job_id but no verdict; dies on the first unguarded read
# The lock advertised "corrupt scorecard" coverage it did not have. These are that coverage.
$f6 = New-NightFixture -Empty
$r6 = Invoke-ScanBlock -NightDirPath $f6 -Src $script:liveSrc
Check "B6a empty scorecard: the loop does NOT escape (healthy jobs still render)" `
    (@($r6.Lines | Where-Object { $_ -match '^\* \*\*B[24]\*\*' }).Count -eq 2)
Check "B6b empty scorecard: reported as lost evidence" ([bool]($r6.Lines -match 'UNREADABLE.*B7\.scorecard\.json'))

$f7 = New-NightFixture -Partial
$r7 = Invoke-ScanBlock -NightDirPath $f7 -Src $script:liveSrc
Check "B7a partial scorecard (job_id, no verdict): the loop does NOT escape" `
    (@($r7.Lines | Where-Object { $_ -match '^\* \*\*B[24]\*\*' }).Count -eq 2)
Check "B7b partial scorecard: reported as lost evidence, not silently dropped" `
    ([bool]($r7.Lines -match 'UNREADABLE.*B8\.scorecard\.json'))
# C2 CONTROL: prove B6/B7 are not vacuous by driving the SAME fixtures through the narrowed
# guard that shipped in the first cut. If this does not escape, the fixtures are not
# reproducing the regression and B6/B7 prove nothing.
$narrowedSrc = @'
$scorecards = Get-ChildItem "$NightDir\scorecards" -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'battery-summary.json' }
foreach ($sc in $scorecards) {
    $d = $null
    try { $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json }
    catch { $lines += "* !! UNREADABLE"; continue }
    if ($d.PSObject.Properties.Name -notcontains 'job_id') { continue }
    $verdicts[$d.job_id] = $d.verdict
}
'@
$escaped = $false
try { $null = Invoke-ScanBlock -NightDirPath $f6 -Src $narrowedSrc } catch { $escaped = $true }
Check "C2a control: the narrowed guard DOES escape on an empty scorecard" $escaped
$escaped = $false
try { $null = Invoke-ScanBlock -NightDirPath $f7 -Src $narrowedSrc } catch { $escaped = $true }
Check "C2b control: the narrowed guard DOES escape on a partial scorecard" $escaped


# ---- B8/C4: a COMPLETE card with no evidence.mode is not lost evidence -------------
# The launcher's own comment says "absent = mode-unknown" and the switch carries a `default`
# arm for it -- but under StrictMode the bare $d.evidence.mode THREW before reaching it, so
# the arm written for this case was unreachable by the only path that produces it. Measured
# 2026-08-07 on B9's first ever run: a card carrying verdict, attribution, failure_class and
# a notes field naming the exact cause was reported to the operator as LOST. This is the
# difference between a loud failure and a loud FALSEHOOD -- the second is worse, because it
# sends the reader looking for evidence that is sitting in the file the report disowned.
$f8 = New-NightFixture -NoMode
$r8 = Invoke-ScanBlock -NightDirPath $f8 -Src $script:liveSrc
Check "B8a no evidence.mode: the card RENDERS, it is not reported as lost" `
    ([bool]($r8.Lines -match '^\* \*\*B9\*\*'))
Check "B8b no evidence.mode: NO unreadable line for that card" `
    (-not [bool]($r8.Lines -match 'UNREADABLE.*B9\.scorecard\.json'))
Check "B8c no evidence.mode: the rendered line carries the REAL cause" `
    ([bool]($r8.Lines -match 'No response from the Assistant Orchestrator'))
Check "B8d no evidence.mode: the healthy jobs still render" `
    (@($r8.Lines | Where-Object { $_ -match '^\* \*\*B[24]\*\*' }).Count -eq 2)
# C4 CONTROL: drive the SAME fixture through the pre-fix bare read. If this does not throw,
# the fixture is not reproducing the regression and B8 proves nothing.
$bareModeSrc = @'
$scorecards = Get-ChildItem "$NightDir\scorecards" -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'battery-summary.json' }
foreach ($sc in $scorecards) {
    $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json
    if ($d.PSObject.Properties.Name -notcontains 'job_id') { continue }
    switch ($d.evidence.mode) { "plan-graph" { } "flat" { } default { } }
}
'@
$threw = $false
try { $null = Invoke-ScanBlock -NightDirPath $f8 -Src $bareModeSrc } catch { $threw = $true }
Check "C4 control: the pre-fix bare read DOES throw on the same fixture" $threw

foreach ($d in @($f6,$f7,$f8)) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }

# ---- T1-T4: the #1181 measured-tree note -----------------------------------------
# The night runs from the primary checkouts, so it measures whatever branch they were left
# on. These lock the report SAYING so — and, critically, lock "cannot tell" rendering as
# unknown rather than as clean.
Check "T1a the tree-note block is present in the launcher" ($null -ne $script:noteSrc)
if ($script:noteSrc) {
    $tClean = Invoke-ScanBlock -NightDirPath $f1 -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T1b clean main: the note names the tree" ([bool]($tClean.Lines -match 'measured tree.*main @ abc1234 \[clean; on main: yes\]'))
    Check "T1c clean main: NO warning banner" (-not [bool]($tClean.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))

    $fBranch = New-NightFixture -Branch 'feat/1170-coder-test-integrity' -OnMain 'no'
    $tBranch = Invoke-ScanBlock -NightDirPath $fBranch -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T2 unmerged branch: the warning banner fires" ([bool]($tBranch.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))
    Check "T2b unmerged branch: the banner is the FIRST line (it leads the report)" `
        ([bool]($tBranch.Lines[0] -match 'MEASURED AN UNMERGED OR DIRTY TREE'))

    $fDirty = New-NightFixture -Branch 'main' -TreeState 'dirty (65 paths)'
    $tDirty = Invoke-ScanBlock -NightDirPath $fDirty -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T3 main but dirty: the warning banner still fires" ([bool]($tDirty.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))

    # T5: scorecards disagreeing about the tree must not silently resolve to the first one.
    $fDis = New-NightFixture -Branch 'main'
    $sd = Join-Path $fDis 'scorecards'
    $b4 = Get-Content (Join-Path $sd 'B4.scorecard.json') -Raw | ConvertFrom-Json
    $b4.versions.blarai_branch = 'feat/something-else'
    $b4 | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $sd 'B4.scorecard.json')
    $tDis = Invoke-ScanBlock -NightDirPath $fDis -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T5a mid-night tree change: reported as DISAGREEMENT, not silently first-wins" `
        ([bool]($tDis.Lines -match 'DISAGREEMENT between jobs'))
    Check "T5b mid-night tree change: the warning banner fires" `
        ([bool]($tDis.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))
    Remove-Item -Recurse -Force $fDis -ErrorAction SilentlyContinue

    $fNone = New-NightFixture -NoVersions
    $tNone = Invoke-ScanBlock -NightDirPath $fNone -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T4a no stamp: reported as NOT RECORDED" ([bool]($tNone.Lines -match 'NOT RECORDED'))
    Check "T4b no stamp: does NOT claim clean (unknown must not read as clean)" `
        (-not [bool]($tNone.Lines -match '\[clean'))
    foreach ($d in @($fBranch,$fDirty,$fNone)) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }

    # ---- T6: THE CORRECTLY PINNED NIGHT MUST BE SILENT ---------------------------
    # The third instance of one class: a fail-loud control that fires on every normal night
    # is a control its reader has already switched off. #1180 was the "unreadable scorecard:
    # battery-summary.json" line, firing nightly for weeks; verify-battery-task-settings.ps1
    # T7 would have reported DRIFT nightly once the driver was pinned; this is the banner.
    #
    # A pinned measurement worktree is DETACHED by construction -- git refuses to check out
    # main in a second worktree -- so a banner keyed on `blarai_branch -eq 'main'` fires on
    # the night the pin first works and on every night after it. The property that actually
    # matters is CONTAINMENT: is the measured commit on main, and was the tree clean.
    $fPinned = New-NightFixture -Branch 'detached' -OnMain 'yes' -TreeState 'clean'
    $tPinned = Invoke-ScanBlock -NightDirPath $fPinned -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T6a a correctly pinned night (detached, contained in main, clean) emits NO banner" `
        (-not [bool]($tPinned.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))
    Check "T6b the pinned night still NAMES the tree, with the detached HEAD as provenance" `
        ([bool]($tPinned.Lines -match 'measured tree.*detached @ abc1234 \[clean; on main: yes\]'))

    # The converse half. Without it "no banner" could be true because the banner is dead.
    $fPinnedOff = New-NightFixture -Branch 'detached' -OnMain 'no' -TreeState 'clean'
    $tPinnedOff = Invoke-ScanBlock -NightDirPath $fPinnedOff -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T6c detached at a commit NOT contained in main: the banner DOES fire" `
        ([bool]($tPinnedOff.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))
    $fPinnedDirty = New-NightFixture -Branch 'detached' -OnMain 'yes' -TreeState 'dirty (3 paths)'
    $tPinnedDirty = Invoke-ScanBlock -NightDirPath $fPinnedDirty -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T6d contained in main but DIRTY: the banner DOES fire" `
        ([bool]($tPinnedDirty.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))
    # An older scorecard cannot answer the containment question. Unknown is not a pass.
    $fNoOnMain = New-NightFixture -Branch 'main' -NoOnMain
    $tNoOnMain = Invoke-ScanBlock -NightDirPath $fNoOnMain -Src $script:liveSrc -NoteSrc $script:noteSrc
    Check "T6e a stamp with no containment field: the banner fires (unknown is not a pass)" `
        ([bool]($tNoOnMain.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))
    Check "T6f a stamp with no containment field: rendered as unknown, not invented" `
        ([bool]($tNoOnMain.Lines -match 'on main: unknown'))

    # C3 CONTROL / toggle-test: the PRE-FIX predicate on the SAME pinned fixture MUST cry
    # wolf. Without it T6a would pass against a fixture that never reproduced the defect.
    $preBannerSrc = @'
$scorecards = Get-ChildItem "$NightDir\scorecards" -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'battery-summary.json' }
foreach ($sc in $scorecards) {
    $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json
    $v = $d.versions
    $thisTree = "{0} @ {1} [{2}]" -f $v.blarai_branch, $v.blarai, $v.blarai_tree
    if ($null -eq $measuredTree) {
        $measuredTree = $thisTree
        $measuredClean = ($v.blarai_branch -eq 'main' -and $v.blarai_tree -eq 'clean')
    }
}
'@
    $cPre = Invoke-ScanBlock -NightDirPath $fPinned -Src $preBannerSrc -NoteSrc $script:noteSrc
    Check "C3 control: the branch-NAME predicate DOES banner the same correctly pinned night" `
        ([bool]($cPre.Lines -match 'MEASURED AN UNMERGED OR DIRTY TREE'))

    foreach ($d in @($fPinned,$fPinnedOff,$fPinnedDirty,$fNoOnMain)) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
}

# ---- D1/D2: the driver tree is recorded too ---------------------------------------
# #1181's predicate is the state of BOTH trees. The scorecards carry the BlarAI one; the
# agentic commit that owns the job set, the admission gate, the budgets and the banking was
# recoverable only from a gitignored bootstrap log nothing points at.
Check "D1a the driver-stamp block is present in the launcher" ($null -ne $script:driverSrc)
if ($script:driverSrc) {
    $dHave = Invoke-ScanBlock -NightDirPath $f1 -Src $script:liveSrc -DriverSrc $script:driverSrc `
        -DriverStamp 'deadbee [on main: yes] from C:\Users\mrbla\agentic-battery-measured'
    Check "D1b a known driver commit is rendered into the report" `
        ([bool]($dHave.Lines -match 'driver tree .*agentic-setup deadbee \[on main: yes\]'))
    $dNone = Invoke-ScanBlock -NightDirPath $f1 -Src $script:liveSrc -DriverSrc $script:driverSrc -DriverStamp ''
    Check "D2 an unreadable driver commit renders as NOT RECORDED, never as absent" `
        ([bool]($dNone.Lines -match 'driver tree .*NOT RECORDED'))
}

foreach ($d in @($f1,$f2,$f3,$f5)) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "RESULT: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
