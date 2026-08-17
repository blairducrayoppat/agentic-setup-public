#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the critique-loop.ps1 module (capture + VLM critique orchestration).
  All tests run with STUBBED capture and python -- no real GUI, no VLM, no network.

.DESCRIPTION
  Tests:
    CP* -- Invoke-CritiquePass: single pass contract (capture + critique)
    CL* -- Invoke-CritiqueLoop: loop driver contract (iteration + rebuild callback)
    FS* -- Fail-soft paths (capture fail, python missing, non-JSON stdout)
    WI* -- Wiring / interface assertions (parameter names, output shape)

  Exit 0 if all passed, 1 otherwise.

.EXAMPLE
  .\verify-critique-loop.ps1
      Fast, deterministic unit suite. Safe to run any time, even without OVMS/BlarAI.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

# Dot-source critique-loop.ps1 to get Invoke-CritiquePass + Invoke-CritiqueLoop.
. "$ScriptDir\critique-loop.ps1" -AppDir 'STUB' -Goal 'STUB' -VisualCriteriaJson '[]' -BlarAiRepo 'STUB' -ErrorAction SilentlyContinue 2>$null
# Note: dot-sourcing with mandatory params set causes the script body to run, but the
# functions ARE defined. We silence the one-pass execution noise above via 2>$null.
# The key check is that the functions exist after the dot-source.

# Dot-source fleet-lib.ps1 for the auto-FIX helpers (Add-VisualFeedback + Invoke-VisualFixPass).
. "$ScriptDir\fleet-lib.ps1"

# ---- Mini test framework (same style as verify-retry.ps1 and verify-capture.ps1) ----
$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }

function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg) {
    if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" }
}
function Assert-False($Cond, $Msg) {
    if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" }
}
function Assert-Contains($Haystack, $Needle, $Msg) {
    if ([string]$Haystack -match [regex]::Escape($Needle)) { _pass $Msg }
    else { _fail "$Msg (did not find '$Needle' in '$Haystack')" }
}

# ---------------------------------------------------------------------------
# Stub infrastructure
# ---------------------------------------------------------------------------
# We override capture-app.ps1 and python.exe behaviour by injecting fake
# scriptblocks into Invoke-CritiquePass's environment via temporary script files
# written into a scratch dir that is prepended to PATH. This lets us exercise
# the real orchestration logic while keeping the test hermetic.

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "verify-clp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force $scratch | Out-Null

# Fake BlarAI repo dir (just needs to exist for path-checks in the function).
$fakeBlarAI = Join-Path $scratch 'blarai'
New-Item -ItemType Directory -Force $fakeBlarAI | Out-Null
$fakePythonDir = Join-Path $fakeBlarAI '.venv\Scripts'
New-Item -ItemType Directory -Force $fakePythonDir | Out-Null

# Fake AppDir (empty -- capture is stubbed, so the dir just needs to exist).
$fakeAppDir = Join-Path $scratch 'app'
New-Item -ItemType Directory -Force $fakeAppDir | Out-Null

# WorkDir for PNG output.
$workDir = Join-Path $scratch 'work'
New-Item -ItemType Directory -Force $workDir | Out-Null

# ---------------------------------------------------------------------------
# Helper: write stub scripts into $scratch and patch Invoke-CritiquePass to
# call those instead of the real ones. Because PowerShell resolves script paths
# inside functions at call-time, we use a thin WRAPPER that replaces the
# capture-app.ps1 path check and python.exe check with explicit test overrides.
#
# Approach: define Invoke-CritiquePassStubbed -- a copy of the logic that accepts
# explicit -CaptureStub and -CritiqueStub scriptblocks in place of the real processes.
# This keeps the test hermetic without touching the real Invoke-CritiquePass.
# ---------------------------------------------------------------------------

function Invoke-CritiquePassStubbed {
    <#
    Stubbed version of Invoke-CritiquePass for unit testing. Accepts:
      -CaptureStub   scriptblock -> returns @(lines); sets $script:stubCaptureExit
      -CritiqueStub  scriptblock -> returns @(lines); sets $script:stubCritiqueExit
    All other parameters mirror Invoke-CritiquePass.
    #>
    param(
        [string]$AppDir = '',
        [string]$Goal = 'test goal',
        [string]$VisualCriteriaJson = '[]',
        [string]$BlarAiRepo = '',
        [int]$Iteration = 0,
        [int]$MaxIter = 3,
        [string]$WorkDir = '',
        [scriptblock]$CaptureStub = $null,
        [scriptblock]$CritiqueStub = $null,
        # Control stub exit codes externally via these params.
        [int]$CaptureExitCode = 0,
        [int]$CritiqueExitCode = 0,
        # Lever A: injected deterministic layout-gate result (mirrors Invoke-LayoutLint).
        [bool]$LayoutHard = $false,
        [string[]]$LayoutMessages = @()
    )

    if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetTempPath() }
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force $WorkDir | Out-Null }
    $pngPath = Join-Path $WorkDir "critique-$Iteration.png"

    # ---- Capture stub ----
    $captureLines = @()
    $captureExit = $CaptureExitCode
    if ($CaptureStub) {
        try { $captureLines = @(& $CaptureStub $pngPath) } catch { return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="CaptureStub threw: $($_.Exception.Message)"; CaptureTier=''; Ok=$false; ScreenshotPath='' } }
    } else {
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback='No capture stub provided'; CaptureTier=''; Ok=$false; ScreenshotPath='' }
    }

    $captureSignal = ($captureLines | Where-Object { $_ -match '^(CAPTURE-OK:|STRUCTURAL_ONLY|CAPTURE-FAIL:)' } | Select-Object -Last 1) ?? ''

    if ($captureSignal -match '^STRUCTURAL_ONLY') {
        $structJson = "$pngPath.json"
        $notes = ''
        if (Test-Path $structJson) {
            try { $obj = Get-Content $structJson -Raw -Encoding UTF8 | ConvertFrom-Json; $notes = $obj.notes ?? '' } catch { $notes = 'unreadable' }
        }
        $ms = Merge-DesignSignals -LayoutHard $LayoutHard -LayoutMessages $LayoutMessages -VlmOk $false -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback ("No pixel capture available (Tier 3 structural floor). Structural notes: $notes".Trim()) -Iteration $Iteration -MaxIter $MaxIter
        return @{ ShouldIterate=$ms.ShouldIterate; NeedsWork=$ms.NeedsWork; Feedback=$ms.Feedback; CaptureTier='structural'; Ok=$false; LayoutHard=$ms.LayoutHard; ScreenshotPath='' }
    }

    if ($captureExit -ne 0 -or -not ($captureSignal -match '^CAPTURE-OK:')) {
        $detail = if ($captureSignal) { $captureSignal } else { "exit $captureExit" }
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="Capture failed: $detail"; CaptureTier=''; Ok=$false; ScreenshotPath='' }
    }

    $captureTier = '?'
    if ($captureSignal -match 'tier=(\d+)') { $captureTier = $Matches[1] }

    if (-not (Test-Path $pngPath) -or (Get-Item $pngPath).Length -eq 0) {
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="PNG missing after reported-OK capture"; CaptureTier=$captureTier; Ok=$false; ScreenshotPath='' }
    }

    # ---- Critique stub ----
    if (-not $CritiqueStub) {
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback='No critique stub provided'; CaptureTier=$captureTier; Ok=$false; ScreenshotPath='' }
    }
    $critiqueLines = @()
    $critiqueExit = $CritiqueExitCode
    try { $critiqueLines = @(& $CritiqueStub $pngPath $Goal $VisualCriteriaJson $Iteration $MaxIter) } catch {
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="CritiqueStub threw: $($_.Exception.Message)"; CaptureTier=$captureTier; Ok=$false; ScreenshotPath='' }
    }

    if ($critiqueExit -ne 0) {
        $detail = ($critiqueLines | Select-Object -Last 3) -join ' | '
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="VLM critique exited ${critiqueExit}: $detail"; CaptureTier=$captureTier; Ok=$false; ScreenshotPath='' }
    }

    $jsonLine = ($critiqueLines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) {
        $detail = ($critiqueLines | Where-Object { $_ } | Select-Object -Last 3) -join ' | '
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="No JSON line from critique stub (stdout: $detail)"; CaptureTier=$captureTier; Ok=$false; ScreenshotPath='' }
    }

    $obj = $null
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        return @{ ShouldIterate=$false; NeedsWork=$false; Feedback="JSON parse failed: $($_.Exception.Message)"; CaptureTier=$captureTier; Ok=$false; ScreenshotPath='' }
    }

    $ms = Merge-DesignSignals -LayoutHard $LayoutHard -LayoutMessages $LayoutMessages -VlmOk ([bool]$obj.ok) -VlmNeedsWork ([bool]$obj.needs_work) -VlmShouldIterate ([bool]$obj.should_iterate) -VlmFeedback ([string]($obj.feedback ?? '')) -Iteration $Iteration -MaxIter $MaxIter
    return @{
        ShouldIterate  = $ms.ShouldIterate
        NeedsWork      = $ms.NeedsWork
        Feedback       = $ms.Feedback
        CaptureTier    = $captureTier
        Ok             = [bool]($obj.ok)
        LayoutHard     = $ms.LayoutHard
        ScreenshotPath = $pngPath
    }
}

# ---------------------------------------------------------------------------
# Stubbed loop driver (mirrors Invoke-CritiqueLoop but uses Invoke-CritiquePassStubbed)
# ---------------------------------------------------------------------------
function Invoke-CritiqueLoopStubbed {
    param(
        [string]$AppDir = '',
        [string]$Goal = 'test goal',
        [string]$VisualCriteriaJson = '[]',
        [string]$BlarAiRepo = '',
        [int]$MaxIter = 3,
        [string]$WorkDir = '',
        [scriptblock]$RebuildCallback = $null,
        # Stubbed critique scriptblocks (array: one per iteration, cycling on last if exhausted).
        [scriptblock[]]$CritiqueStubs = @(),
        [scriptblock]$CaptureStub = $null
    )

    $currentAppDir = $AppDir
    $iteration = 0
    $lastResult = $null
    $stubIdx = 0

    while ($iteration -lt $MaxIter) {
        $critiqueStub = if ($stubIdx -lt $CritiqueStubs.Count) { $CritiqueStubs[$stubIdx] } elseif ($CritiqueStubs.Count -gt 0) { $CritiqueStubs[-1] } else { { '{}' } }
        $stubIdx++

        $result = Invoke-CritiquePassStubbed `
            -AppDir $currentAppDir `
            -Goal $Goal `
            -VisualCriteriaJson $VisualCriteriaJson `
            -BlarAiRepo $BlarAiRepo `
            -Iteration $iteration `
            -MaxIter $MaxIter `
            -WorkDir $WorkDir `
            -CaptureStub $CaptureStub `
            -CritiqueStub $critiqueStub

        $lastResult = $result
        $iteration++

        if (-not $result.ShouldIterate) { break }

        if ($RebuildCallback) {
            try {
                $newDir = & $RebuildCallback $result.Feedback $currentAppDir
                if ($newDir -and (Test-Path $newDir)) { $currentAppDir = $newDir }
            } catch {
                $lastResult = @{ ShouldIterate=$false; NeedsWork=$false; Feedback="Rebuild callback threw: $($_.Exception.Message)"; CaptureTier=$result.CaptureTier; Ok=$false; ScreenshotPath='' }
                break
            }
        }
    }

    if ($lastResult -and $lastResult.ShouldIterate -and $iteration -ge $MaxIter) {
        $lastResult = $lastResult.Clone()
        $lastResult.ShouldIterate = $false
    }

    return @{ FinalResult = $lastResult; Iterations = $iteration }
}

# ---------------------------------------------------------------------------
# Stub helpers: write a real 1x1 PNG into the path so the size-check passes.
# ---------------------------------------------------------------------------
function Write-MinimalPng([string]$Path) {
    # Smallest valid PNG: 1x1 white pixel (68 bytes).
    $bytes = [byte[]](
        0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, # PNG signature
        0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52, # IHDR chunk length + type
        0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, # width=1, height=1
        0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53, # bit depth=8, color=RGB, CRC...
        0xDE,0x00,0x00,0x00,0x0C,0x49,0x44,0x41, # IDAT chunk
        0x54,0x08,0xD7,0x63,0xF8,0xFF,0xFF,0xFF,
        0xFF,0xFF,0x03,0x00,0x05,0xFE,0x02,0xFE,
        0xDC,0xCC,0x59,0xE7,0x00,0x00,0x00,0x00,
        0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82  # IEND chunk
    )
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

$captureOkStub = {
    param($PngPath)
    Write-MinimalPng $PngPath
    "CAPTURE-OK: $PngPath 1x1 tier=1"
}

$captureOkTier2Stub = {
    param($PngPath)
    Write-MinimalPng $PngPath
    "CAPTURE-OK: $PngPath 1x1 tier=2"
}

$captureStructuralStub = {
    param($PngPath)
    $jsonPath = "$PngPath.json"
    '{"notes":"seed_only=true","seed_only":true,"has_image_assets":false}' | Set-Content $jsonPath -Encoding UTF8
    "STRUCTURAL_ONLY"
    "  JSON: $jsonPath"
}

$captureFailStub = {
    param($PngPath)
    "CAPTURE-FAIL: App.exe not found"
}

function Make-CritiqueJsonStub([bool]$NeedsWork, [bool]$ShouldIterate, [string]$Feedback = '') {
    $json = @{ ok = $true; needs_work = $NeedsWork; feedback = $Feedback; should_iterate = $ShouldIterate } | ConvertTo-Json -Compress
    return [scriptblock]::Create("'$json'")
}

$critiqueNeedsWorkStub   = Make-CritiqueJsonStub -NeedsWork $true  -ShouldIterate $true  -Feedback "Button labels too small."
$critiquePassStub        = Make-CritiqueJsonStub -NeedsWork $false -ShouldIterate $false -Feedback "All criteria met."
$critiqueNonJsonStub     = { "not json at all" }
$critiqueMissingPythonWd = { "{'ok':false}" }  # test the No-JSON path

# =============================================================================
Section 'CP* -- Invoke-CritiquePassStubbed: basic one-pass contract'

# CP1: capture OK + critique needs_work=true/should_iterate=true -> correct result.
$r = Invoke-CritiquePassStubbed -Goal 'Test app' -VisualCriteriaJson '["Sidebar visible"]' `
    -WorkDir $workDir -CaptureStub $captureOkStub -CritiqueStub $critiqueNeedsWorkStub -Iteration 0 -MaxIter 3
Assert-True  $r.ShouldIterate  'CP1 needs_work=true/should_iterate=true -> ShouldIterate is True'
Assert-True  $r.NeedsWork      'CP1 NeedsWork is True'
Assert-True  $r.Ok             'CP1 Ok is True'
Assert-Eq    '1' $r.CaptureTier 'CP1 CaptureTier is "1" (tier=1 capture)'
Assert-True  ($r.ScreenshotPath -ne '') 'CP1 ScreenshotPath is non-empty'
Assert-Contains $r.Feedback 'Button labels' 'CP1 Feedback contains the VLM feedback text'

# CP2: capture OK + critique needs_work=false/should_iterate=false -> loop stops.
$r2 = Invoke-CritiquePassStubbed -Goal 'Test app' -VisualCriteriaJson '[]' `
    -WorkDir $workDir -CaptureStub $captureOkStub -CritiqueStub $critiquePassStub -Iteration 0 -MaxIter 3
Assert-False $r2.ShouldIterate 'CP2 needs_work=false -> ShouldIterate is False'
Assert-False $r2.NeedsWork     'CP2 NeedsWork is False'
Assert-True  $r2.Ok            'CP2 Ok is True on a pass'

# CP3: tier=2 capture reports correctly.
$r3 = Invoke-CritiquePassStubbed -Goal 'Test' -VisualCriteriaJson '[]' `
    -WorkDir $workDir -CaptureStub $captureOkTier2Stub -CritiqueStub $critiquePassStub -Iteration 1 -MaxIter 3
Assert-Eq '2' $r3.CaptureTier 'CP3 tier=2 capture -> CaptureTier is "2"'
Assert-True  $r3.Ok            'CP3 Ok on tier=2 capture + passing critique'

# =============================================================================
Section 'CP* -- Invoke-CritiquePassStubbed: STRUCTURAL_ONLY floor'

# CP4: STRUCTURAL_ONLY -> ShouldIterate is always False (floor never forces iteration).
$r4 = Invoke-CritiquePassStubbed -Goal 'Test' -VisualCriteriaJson '[]' `
    -WorkDir $workDir -CaptureStub $captureStructuralStub -CritiqueStub $critiqueNeedsWorkStub -Iteration 0 -MaxIter 3
Assert-False $r4.ShouldIterate 'CP4 STRUCTURAL_ONLY -> ShouldIterate is False (floor never forces iteration)'
Assert-False $r4.NeedsWork     'CP4 STRUCTURAL_ONLY -> NeedsWork is False'
Assert-False $r4.Ok            'CP4 STRUCTURAL_ONLY -> Ok is False (no VLM critique ran)'
Assert-Eq    'structural' $r4.CaptureTier 'CP4 STRUCTURAL_ONLY -> CaptureTier is "structural"'
Assert-Contains $r4.Feedback 'structural floor' 'CP4 Feedback mentions structural floor'

# =============================================================================
Section 'FS* -- Fail-soft paths'

# FS1: capture fails (CAPTURE-FAIL line) -> ShouldIterate=$false, no throw.
$r5 = Invoke-CritiquePassStubbed -Goal 'Test' -VisualCriteriaJson '[]' `
    -WorkDir $workDir -CaptureStub $captureFailStub -CritiqueStub $critiqueNeedsWorkStub `
    -CaptureExitCode 0 -Iteration 0 -MaxIter 3
Assert-False $r5.ShouldIterate 'FS1 CAPTURE-FAIL line -> ShouldIterate=$false (fail-soft)'
Assert-False $r5.Ok            'FS1 CAPTURE-FAIL line -> Ok=$false'
Assert-Contains $r5.Feedback 'Capture failed' 'FS1 Feedback explains the capture failure'

# FS2: critique returns non-JSON stdout -> ShouldIterate=$false.
$r6 = Invoke-CritiquePassStubbed -Goal 'Test' -VisualCriteriaJson '[]' `
    -WorkDir $workDir -CaptureStub $captureOkStub -CritiqueStub $critiqueNonJsonStub -Iteration 0 -MaxIter 3
Assert-False $r6.ShouldIterate 'FS2 non-JSON critique stdout -> ShouldIterate=$false (fail-soft)'
Assert-False $r6.Ok            'FS2 non-JSON critique stdout -> Ok=$false'

# FS3: capture stub that does NOT write the PNG (test the missing-PNG path).
# Use a fresh WorkDir so no prior test wrote a PNG at the same path.
$fs3WorkDir = Join-Path $scratch 'work-fs3'
New-Item -ItemType Directory -Force $fs3WorkDir | Out-Null
$captureLiesStub = { param($PngPath); "CAPTURE-OK: $PngPath 0x0 tier=1" }  # claims OK but writes nothing
$r7 = Invoke-CritiquePassStubbed -Goal 'Test' -VisualCriteriaJson '[]' `
    -WorkDir $fs3WorkDir -CaptureStub $captureLiesStub -CritiqueStub $critiqueNeedsWorkStub -Iteration 0 -MaxIter 3
Assert-False $r7.ShouldIterate 'FS3 missing PNG after reported-OK capture -> ShouldIterate=$false (fail-soft)'
Assert-False $r7.Ok            'FS3 missing PNG -> Ok=$false'

# FS4: critique JSON but missing python (simulated by passing a stub that exits 1).
$r8 = Invoke-CritiquePassStubbed -Goal 'Test' -VisualCriteriaJson '[]' `
    -WorkDir $workDir -CaptureStub $captureOkStub -CritiqueStub { 'ERROR: bad usage' } `
    -CritiqueExitCode 1 -Iteration 0 -MaxIter 3
Assert-False $r8.ShouldIterate 'FS4 critique exit=1 (usage error) -> ShouldIterate=$false (fail-soft)'
Assert-False $r8.Ok            'FS4 critique exit=1 -> Ok=$false'

# =============================================================================
Section 'CL* -- Invoke-CritiqueLoopStubbed: loop driver contract'

# CL1: needs_work for 2 iterations then PASS -> loop runs exactly 3 times and stops.
$rebuildLog = New-Object System.Collections.ArrayList
$rebuildCb = { param($Feedback, $AppDir); [void]$rebuildLog.Add("rebuild:$Feedback"); return $AppDir }
$loopR1 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '[]' -MaxIter 3 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiqueNeedsWorkStub, $critiqueNeedsWorkStub, $critiquePassStub) `
    -RebuildCallback $rebuildCb
Assert-Eq 3 $loopR1.Iterations 'CL1 needs_work x2 then PASS -> exactly 3 iterations'
Assert-False $loopR1.FinalResult.ShouldIterate 'CL1 final result ShouldIterate is False'
Assert-True  $loopR1.FinalResult.Ok             'CL1 final result Ok is True (VLM passed on iter 3)'
Assert-Eq 2 $rebuildLog.Count                   'CL1 rebuild callback was invoked exactly 2 times'

# CL2: always needs_work, MaxIter=2 -> loop stops AT MaxIter even if needs_work stays True.
$rebuildLog2 = New-Object System.Collections.ArrayList
$rebuildCb2 = { param($Feedback, $AppDir); [void]$rebuildLog2.Add('rebuild'); return $AppDir }
# CritiqueStubs has one entry; the loop driver cycles on it (always needs_work).
$loopR2 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '[]' -MaxIter 2 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiqueNeedsWorkStub) `
    -RebuildCallback $rebuildCb2
Assert-Eq 2 $loopR2.Iterations 'CL2 MaxIter=2, always needs_work -> stops at MaxIter (exactly 2 iterations)'
Assert-False $loopR2.FinalResult.ShouldIterate 'CL2 ShouldIterate forced to False at MaxIter cap'

# CL3: first pass PASS immediately -> exactly 1 iteration, rebuild never called.
$rebuildLog3 = New-Object System.Collections.ArrayList
$rebuildCb3 = { param($Feedback, $AppDir); [void]$rebuildLog3.Add('rebuild'); return $AppDir }
$loopR3 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '[]' -MaxIter 3 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiquePassStub) `
    -RebuildCallback $rebuildCb3
Assert-Eq 1 $loopR3.Iterations 'CL3 first pass PASS -> exactly 1 iteration (no rebuild)'
Assert-Eq 0 $rebuildLog3.Count 'CL3 rebuild callback never called when first pass is PASS'

# CL4: STRUCTURAL_ONLY -> stops at iteration 1, rebuild never called.
$loopR4 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '[]' -MaxIter 3 `
    -WorkDir $workDir -CaptureStub $captureStructuralStub `
    -CritiqueStubs @($critiqueNeedsWorkStub)  # stub doesn't matter; structural stops first
Assert-Eq 1 $loopR4.Iterations 'CL4 STRUCTURAL_ONLY -> stops at 1 iteration'
Assert-Eq 'structural' $loopR4.FinalResult.CaptureTier 'CL4 final result is structural'
Assert-False $loopR4.FinalResult.ShouldIterate 'CL4 STRUCTURAL_ONLY -> ShouldIterate=$false'

# CL5: rebuild callback receives correct feedback string.
$receivedFeedback = @()
$feedbackCaptureCb = { param($Feedback, $AppDir); $script:receivedFeedback += $Feedback; return $AppDir }
$loopR5 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '[]' -MaxIter 3 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiqueNeedsWorkStub, $critiquePassStub) `
    -RebuildCallback $feedbackCaptureCb
Assert-Eq 1 $script:receivedFeedback.Count 'CL5 rebuild callback received the feedback exactly once'
Assert-Contains ($script:receivedFeedback[0]) 'Button labels' 'CL5 rebuild callback received the VLM feedback text'

# =============================================================================
Section 'WI* -- Interface / wiring assertions'

$src = Get-Content "$ScriptDir\critique-loop.ps1" -Raw

# WI1: Mandatory parameters present.
Assert-True ([regex]::IsMatch($src, '\[Parameter\(Mandatory\)\]\[string\]\$AppDir')) `
    'WI1 critique-loop.ps1 has Mandatory -AppDir'
Assert-True ([regex]::IsMatch($src, '\[Parameter\(Mandatory\)\]\[string\]\$Goal')) `
    'WI2 critique-loop.ps1 has Mandatory -Goal'
Assert-True ([regex]::IsMatch($src, '\[Parameter\(Mandatory\)\]\[string\]\$VisualCriteriaJson')) `
    'WI3 critique-loop.ps1 has Mandatory -VisualCriteriaJson'
Assert-True ([regex]::IsMatch($src, '\[Parameter\(Mandatory\)\]\[string\]\$BlarAiRepo')) `
    'WI4 critique-loop.ps1 has Mandatory -BlarAiRepo'

# WI5: Both functions exported.
Assert-True ([regex]::IsMatch($src, 'function Invoke-CritiquePass\b')) `
    'WI5 critique-loop.ps1 defines Invoke-CritiquePass'
Assert-True ([regex]::IsMatch($src, 'function Invoke-CritiqueLoop\b')) `
    'WI6 critique-loop.ps1 defines Invoke-CritiqueLoop'

# WI7: Result object keys documented / present in code.
Assert-True ([regex]::IsMatch($src, 'ShouldIterate')) 'WI7 ShouldIterate key present in source'
Assert-True ([regex]::IsMatch($src, 'NeedsWork'))     'WI8 NeedsWork key present in source'
Assert-True ([regex]::IsMatch($src, 'CaptureTier'))   'WI9 CaptureTier key present in source'
Assert-True ([regex]::IsMatch($src, 'ScreenshotPath')) 'WI10 ScreenshotPath key present in source'

# WI11: capture-app.ps1 is called exactly once per pass (not double-invoked).
Assert-True ([regex]::IsMatch($src, "capture-app\.ps1")) `
    'WI11 critique-loop.ps1 references capture-app.ps1'

# WI12: STRUCTURAL_ONLY is handled (the floor case).
Assert-True ([regex]::IsMatch($src, 'STRUCTURAL_ONLY')) `
    'WI12 critique-loop.ps1 handles STRUCTURAL_ONLY floor'

# WI13: memory / co-residency comment is present.
Assert-True ([regex]::IsMatch($src, 'VLM.*30B co-residency|30B.*VLM.*co-resid')) `
    'WI13 critique-loop.ps1 contains the VLM+30B co-residency memory note'

# WI14: integration hook comment is present.
Assert-True ([regex]::IsMatch($src, 'new-agent-task\.ps1')) `
    'WI14 critique-loop.ps1 documents the new-agent-task.ps1 hook point'

# WI15: visual criteria plumbing note is present.
Assert-True ([regex]::IsMatch($src, 'visual_criteria_json|visual criteria')) `
    'WI15 critique-loop.ps1 documents the visual-criteria plumbing'

# WI16: fail-soft comment present.
Assert-True ([regex]::IsMatch($src, '[Ff]ail-soft')) `
    'WI16 critique-loop.ps1 documents the fail-soft contract'

# WI17: Invoke-CritiqueLoop accepts -RebuildCallback.
Assert-True ([regex]::IsMatch($src, '\[scriptblock\]\$RebuildCallback')) `
    'WI17 Invoke-CritiqueLoop has -RebuildCallback parameter'

# =============================================================================
Section 'GA* -- new-agent-task.ps1 hook: GATING (double-dormant by default)'
# The gating predicate in new-agent-task.ps1 is:
#   $_critiqueActive = $merged -and $EnableVisualCritique -and
#       $_visualTrimmed -and ($_visualTrimmed -ne '[]') -and (Test-Path $wt)
# We replicate it EXACTLY here as a pure function and prove every dormant case is a no-op,
# and that BOTH gates (toggle + criteria) must be open for the hook to fire.
function Test-CritiqueActive {
    param([bool]$Merged, [bool]$EnableVisualCritique, [string]$VisualCriteriaJson, [bool]$WtExists)
    $trimmed = "$VisualCriteriaJson".Trim()
    return ($Merged -and $EnableVisualCritique -and $trimmed -and ($trimmed -ne '[]') -and $WtExists)
}

# GA1: the happy path -- everything open -> ACTIVE.
Assert-True (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson '["Sidebar visible"]' -WtExists $true) `
    'GA1 merged + toggle ON + real criteria + worktree -> hook ACTIVE'

# GA2: toggle OFF -> no-op even with real criteria (the master opt-in gate).
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $false -VisualCriteriaJson '["Sidebar visible"]' -WtExists $true) `
    'GA2 toggle OFF -> hook NO-OP even with real visual criteria'

# GA3: no criteria field ('') -> no-op (the common non-visual task).
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson '' -WtExists $true) `
    'GA3 empty visual_criteria_json -> hook NO-OP (common non-visual task)'

# GA4: empty-array criteria ('[]') -> no-op.
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson '[]' -WtExists $true) `
    'GA4 "[]" visual_criteria_json -> hook NO-OP'

# GA5: whitespace-only criteria -> no-op (the .Trim() guard).
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson "   `t  " -WtExists $true) `
    'GA5 whitespace-only visual_criteria_json -> hook NO-OP (Trim guard)'

# GA6: whitespace-wrapped empty array ('  []  ') -> no-op (Trim then compare).
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson '  []  ' -WtExists $true) `
    'GA6 "  []  " visual_criteria_json -> hook NO-OP (Trim then != "[]")'

# GA7: not merged -> no-op (the merge must have succeeded; the critique is post-merge only).
Assert-False (Test-CritiqueActive -Merged $false -EnableVisualCritique $true -VisualCriteriaJson '["x criterion"]' -WtExists $true) `
    'GA7 not merged -> hook NO-OP (post-merge enhancement only)'

# GA8: worktree gone -> no-op (nothing to capture).
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson '["x criterion"]' -WtExists $false) `
    'GA8 worktree missing -> hook NO-OP (nothing to capture)'

# GA9 [kill]: BOTH gates required -- toggle ON but no criteria is still a no-op (proves the
# AND, not an OR, between the two gates).
Assert-False (Test-CritiqueActive -Merged $true -EnableVisualCritique $true -VisualCriteriaJson '[]' -WtExists $true) `
    'GA9 [kill] toggle ON + "[]" criteria -> still NO-OP (gates are AND, not OR)'

Section 'GA* -- new-agent-task.ps1 hook: source wiring assertions'
$nat = Get-Content "$ScriptDir\new-agent-task.ps1" -Raw

# GA10: the master opt-in switch exists and defaults OFF (a [switch] defaults to $false).
Assert-True ([regex]::IsMatch($nat, '\[switch\]\$EnableVisualCritique')) `
    'GA10 new-agent-task.ps1 has the -EnableVisualCritique master switch (defaults OFF)'

# RF11 [GO-LIVE 2026-06-25, operator-approved]: run-fleet.ps1 PASSES -EnableVisualCritique so a
# visual /dispatch fires the VLM design loop LIVE. The [6/6] hook still self-gates on
# visual_criteria_json being present, so non-visual tasks stay no-ops. This is the regression lock
# for the go-live flip -- if someone reverts it the loop silently goes dormant again on every dispatch.
$rf = Get-Content "$ScriptDir\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($rf, '\$params\.EnableVisualCritique\s*=\s*\$true')) `
    'RF11 [kill] run-fleet.ps1 sets $params.EnableVisualCritique = $true (VLM design loop LIVE on every visual dispatch)'

# RF12/RF13 [headless-build guard 2026-06-25]: the coder's `dotnet run` was launching the seeded WinUI
# app's no-args GUI, which HANGS (a window never exits) + pops a ".NET" runtime dialog -- a major cause
# of build timeouts. new-agent-task marks the dispatch headless; the seed App.xaml.cs refuses the no-args
# GUI launch when that flag is set (exit 0), while --test / --render-to-file / the operator launch stay live.
Assert-True ([regex]::IsMatch($nat, "BLARAI_HEADLESS_BUILD\s*=\s*'1'")) `
    'RF12 [kill] new-agent-task.ps1 sets $env:BLARAI_HEADLESS_BUILD=1 (marks the dispatch a headless build)'
$appcs = Get-Content "$ScriptDir\..\build-infra\winui\reference\App.xaml.cs" -Raw
Assert-True ([regex]::IsMatch($appcs, 'BLARAI_HEADLESS_BUILD') -and [regex]::IsMatch($appcs, '_renderOutputPath is null')) `
    'RF13 [kill] seed App.xaml.cs guards the no-args GUI launch on BLARAI_HEADLESS_BUILD (skips it for --render-to-file)'

# GA11: the $Goal + $VisualCriteriaJson params are present (the queue fields land here).
Assert-True ([regex]::IsMatch($nat, '\[string\]\$Goal\s*=')) `
    'GA11 new-agent-task.ps1 accepts -Goal (queue task $t.goal)'
Assert-True ([regex]::IsMatch($nat, '\[string\]\$VisualCriteriaJson\s*=')) `
    'GA12 new-agent-task.ps1 accepts -VisualCriteriaJson (queue task $t.visual_criteria_json)'

# GA13: -BlarAiRepo param with the env-override-then-default convention.
Assert-True ([regex]::IsMatch($nat, '\$BlarAiRepo\s*=\s*\$\(if \(\$env:BLARAI_REPO\)')) `
    'GA13 new-agent-task.ps1 -BlarAiRepo defaults to $env:BLARAI_REPO then the canonical path'

# GA14: the hook is placed AFTER the merge block (the [6/6] section appears after [5/5]).
$i5 = $nat.IndexOf('[5/5] Act on the verdicts')
$i6 = $nat.IndexOf('[6/6] VLM DESIGN CRITIQUE')
Assert-True ($i5 -gt 0) 'GA14a [5/5] merge step present'
Assert-True ($i6 -gt 0) 'GA14b [6/6] critique step present'
Assert-True ($i5 -lt $i6) 'GA14 [kill] the critique hook ([6/6]) is placed AFTER the merge step ([5/5])'

# GA15: the gating predicate in the SOURCE ANDs $merged + $_enableCritique + the criteria
# (not an OR), and $_enableCritique is itself the switch-OR-env-OR-flag master opt-in composite.
Assert-True ([regex]::IsMatch($nat, '\$_critiqueActive\s*=\s*\$merged\s*-and\s*\$_enableCritique\s*-and')) `
    'GA15 [kill] source gate ANDs $merged + $_enableCritique + criteria (not OR)'
Assert-True ([regex]::IsMatch($nat, '\$_enableCritique\s*=\s*\$EnableVisualCritique\s*-or')) `
    'GA15b [kill] $_enableCritique is the -EnableVisualCritique switch OR-ed with the env/flag opt-ins'
Assert-True ([regex]::IsMatch($nat, 'BLARAI_ENABLE_VISUAL_CRITIQUE')) `
    'GA15c the env-var opt-in (BLARAI_ENABLE_VISUAL_CRITIQUE) is part of the master gate'

# GA16: the hook calls Invoke-CritiqueLoop (the loop driver, not a re-implemented loop).
Assert-True ([regex]::IsMatch($nat, 'Invoke-CritiqueLoop\b')) `
    'GA16 the hook invokes Invoke-CritiqueLoop from critique-loop.ps1'

# GA17: MaxIter is small (a low single digit) per the requirement (auto-FIX uses 3 total passes).
Assert-True ([regex]::IsMatch($nat, 'Invoke-CritiqueLoop[\s\S]{0,500}-MaxIter [23]\b')) `
    'GA17 the hook passes a small -MaxIter (2 or 3) -- a bounded loop'

Section 'FB* -- new-agent-task.ps1 hook: FAIL-SOFT (error never changes the task result)'
# The hook wraps everything in try/catch; on ANY error it logs + continues, and the merge
# result ($merged / RESULT) is untouched. We model the hook's control flow exactly: a thrown
# error inside the try MUST NOT propagate, MUST NOT alter a pre-set $merged, and MUST leave a
# diagnostic in $critiqueSummary.
function Invoke-HookFailSoftModel {
    param([scriptblock]$LoopBody, [bool]$MergedIn)
    $merged = $MergedIn          # the merge already happened; the hook must not touch this
    $critiqueSummary = ''
    try {
        & $LoopBody              # stands in for the Invoke-CritiqueLoop call + summary build
        $critiqueSummary = 'ran'
    } catch {
        $critiqueSummary = "VLM critique hook errored (non-blocking, task result unchanged): $($_.Exception.Message)"
    }
    return @{ Merged = $merged; CritiqueSummary = $critiqueSummary }
}

# FB1: the loop THROWS -> no propagation, $merged unchanged (still True), summary records it.
$throwBody = { throw 'simulated VLM/capture explosion' }
$fb1 = Invoke-HookFailSoftModel -LoopBody $throwBody -MergedIn $true
Assert-True  $fb1.Merged 'FB1 a thrown error in the hook leaves $merged TRUE (task result unchanged)'
Assert-Contains $fb1.CritiqueSummary 'non-blocking' 'FB1 the error is recorded as non-blocking in the summary'
Assert-Contains $fb1.CritiqueSummary 'simulated VLM/capture explosion' 'FB1 the underlying error message is surfaced'

# FB2: the hook does NOT throw out of Invoke-HookFailSoftModel (no unhandled exception escapes).
$threwOut = $false
try { Invoke-HookFailSoftModel -LoopBody { throw 'boom' } -MergedIn $true | Out-Null } catch { $threwOut = $true }
Assert-False $threwOut 'FB2 the hook never lets an exception escape (the task cannot fail on a critique error)'

# FB3: a clean loop body leaves $merged True and records a normal summary.
$fb3 = Invoke-HookFailSoftModel -LoopBody { } -MergedIn $true
Assert-True $fb3.Merged 'FB3 a clean critique run leaves $merged TRUE'
Assert-Eq 'ran' $fb3.CritiqueSummary 'FB3 a clean run records a normal (non-error) summary'

# FB4: source-level proof the production hook is wrapped in try/catch with a non-blocking note.
Assert-True ([regex]::IsMatch($nat, '(?s)\[6/6\] VLM DESIGN CRITIQUE.*?try\s*\{.*?\}\s*catch\s*\{')) `
    'FB4 [kill] the production hook body is wrapped in try/catch'
Assert-True ([regex]::IsMatch($nat, 'MUST NOT fail the task|result unchanged|never change|NON-BLOCKING')) `
    'FB5 the production hook documents the non-blocking / result-unchanged contract'

# FB6: the worktree removal is DEFERRED until after the hook (so the built App.exe is still
# present to capture) -- assert the MERGE BLOCK (the span from "Act on the verdicts" up to the
# start of the [6/6] section) no longer removes the worktree inline, AND a deferred removal
# exists after the [6/6] block.
$mergeBlock = ''
$i5b = $nat.IndexOf('[5/5] Act on the verdicts')
$i6b = $nat.IndexOf('[6/6] VLM DESIGN CRITIQUE')
if ($i5b -ge 0 -and $i6b -gt $i5b) { $mergeBlock = $nat.Substring($i5b, $i6b - $i5b) }
$afterHook = if ($i6b -ge 0) { $nat.Substring($i6b) } else { '' }
Assert-False ([regex]::IsMatch($mergeBlock, 'worktree remove')) `
    'FB6a the inline merge block (before [6/6]) no longer removes the worktree (deferred past the hook)'
Assert-True ([regex]::IsMatch($afterHook, '(?s)if \(\$merged\) \{[\s\S]{0,200}worktree remove')) `
    'FB6b a deferred worktree removal exists AFTER the [6/6] hook'

Section 'SC* -- new-agent-task.ps1 hook: dot-source scope-clobber is neutralised'
# Dot-sourcing critique-loop.ps1 with throwaway args BINDS its param block in the caller's
# scope, OVERWRITING any same-named caller variables ($Goal/$VisualCriteriaJson/$AppDir/
# $BlarAiRepo). The production hook defends against this by pre-capturing the real values into
# $_-prefixed locals BEFORE the dot-source and using ONLY those afterward. This test reproduces
# the EXACT pattern and proves the real goal/criteria/repo survive the dot-source.
$SC_realGoal = 'Make the calculator look like a rocket'
$SC_realCriteria = '["A rocket motif is visible","Buttons are large and readable"]'
$SC_realRepo = $fakeBlarAI
# Pre-capture (mirrors the production hook).
$_visualTrimmed = "$SC_realCriteria".Trim()
$_critiqueGoal  = $SC_realGoal
$_blarAiRepo    = $SC_realRepo
# Now the clobbering dot-source (exactly as in new-agent-task.ps1).
. "$ScriptDir\critique-loop.ps1" -AppDir 'x' -Goal 'x' -VisualCriteriaJson '[]' -BlarAiRepo 'x' 2>$null
# Assert the dot-source DID clobber the bare names (proving the hazard is real)...
Assert-Eq 'x'  $Goal               'SC1 dot-source clobbers the bare $Goal (the hazard is real)'
Assert-Eq '[]' $VisualCriteriaJson 'SC2 dot-source clobbers the bare $VisualCriteriaJson (hazard real)'
# ...but the pre-captured copies the hook actually uses SURVIVE intact.
Assert-Eq $SC_realGoal     $_critiqueGoal  'SC3 [kill] the pre-captured goal survives the dot-source'
Assert-Eq $SC_realCriteria $_visualTrimmed 'SC4 [kill] the pre-captured criteria survive the dot-source'
Assert-Eq $SC_realRepo     $_blarAiRepo    'SC5 [kill] the pre-captured BlarAiRepo survives the dot-source'
# Source-level proof: the hook pre-captures into the $_-locals BEFORE the dot-source line.
$iPreCap = [regex]::Match($nat, '\$_critiqueGoal\s*=').Index
$iDotSrc = [regex]::Match($nat, '\.\s*"\$PSScriptRoot\\critique-loop\.ps1"').Index
Assert-True ($iPreCap -gt 0 -and $iDotSrc -gt 0 -and $iPreCap -lt $iDotSrc) `
    'SC6 [kill] the hook pre-captures $_critiqueGoal BEFORE the clobbering dot-source line'
# And the loop call uses the SURVIVING $_-locals, not the clobbered bare names.
Assert-True ([regex]::IsMatch($nat, 'Invoke-CritiqueLoop[\s\S]{0,300}-Goal \$critiqueGoal[\s\S]{0,200}-BlarAiRepo \$_blarAiRepo')) `
    'SC7 [kill] the loop call uses the pre-captured goal + $_blarAiRepo (un-clobbered)'

Section 'RF* -- run-fleet.ps1: queue fields are forwarded'
$rf = Get-Content "$ScriptDir\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($rf, '\$t\.goal[\s\S]{0,60}\$params\.Goal')) `
    'RF1 run-fleet.ps1 forwards $t.goal -> -Goal'
Assert-True ([regex]::IsMatch($rf, '\$t\.visual_criteria_json[\s\S]{0,80}\$params\.VisualCriteriaJson')) `
    'RF2 run-fleet.ps1 forwards $t.visual_criteria_json -> -VisualCriteriaJson'

# =============================================================================
Section 'AVF* -- Add-VisualFeedback: FIX-prompt composition (pure)'
$avf = Add-VisualFeedback -Prompt 'Build a calculator' -Feedback 'Buttons are too small; the score is low-contrast.'
Assert-Contains $avf 'Build a calculator' 'AVF1 keeps the original prompt'
Assert-Contains $avf '--- Visual design feedback to address ---' 'AVF2 adds the delimited feedback section (the FIX header)'
Assert-Contains $avf 'Buttons are too small' 'AVF3 includes the VLM feedback verbatim'
Assert-Contains $avf 'Do NOT start over' 'AVF4 carries the smallest-change / do-not-start-over discipline'
Assert-Eq 'X' (Add-VisualFeedback -Prompt 'X' -Feedback '') 'AVF5 empty feedback -> prompt UNCHANGED (true no-op)'
Assert-Eq 'X' (Add-VisualFeedback -Prompt 'X' -Feedback '   ') 'AVF6 whitespace feedback -> prompt UNCHANGED'

# =============================================================================
Section 'VF* -- Invoke-VisualFixPass: one FIX iteration (policy, all mechanisms stubbed)'

# VF1: happy path -- coder ok, commit yes, verify pass, merge clean -> APPLIED.
$vf1 = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false; ExitCode = 0 } } `
    -CommitFix { $true } -Verify { 'pass' } -ReMerge { $true }
Assert-True  $vf1.Applied 'VF1 coder-ok + commit + verify pass + clean merge -> Applied=$true'
Assert-Eq 'pass' $vf1.Verify 'VF1 surfaces the verify result'

# VF2: verify FAILS -> ABORT, re-merge NEVER attempted (the prior merged version is kept).
$script:vf2_mergeCalled = $false
$vf2 = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false } } `
    -CommitFix { $true } -Verify { 'fail' } -ReMerge { $script:vf2_mergeCalled = $true; $true }
Assert-False $vf2.Applied 'VF2 [kill] verify FAIL -> Applied=$false (never merge a broken rebuild)'
Assert-False $script:vf2_mergeCalled 'VF2 [kill] verify FAIL -> the re-merge is NEVER attempted'
Assert-Contains $vf2.Reason 'FAILED the verify gate' 'VF2 reason names the verify failure'

# VF3: re-merge CONFLICT -> fail-soft ABORT, prior version kept.
$vf3 = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false } } `
    -CommitFix { $true } -Verify { 'pass' } -ReMerge { $false }
Assert-False $vf3.Applied 'VF3 [kill] re-merge conflict/error -> Applied=$false (fail-soft abort)'
Assert-Contains $vf3.Reason 'did not apply cleanly' 'VF3 reason names the re-merge abort'

# VF4: coder NO-OP (no new commit) -> ABORT, verify+merge NEVER attempted.
$script:vf4_verifyCalled = $false
$vf4 = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false } } `
    -CommitFix { $false } -Verify { $script:vf4_verifyCalled = $true; 'pass' } -ReMerge { $true }
Assert-False $vf4.Applied 'VF4 coder no-op (no commit) -> Applied=$false'
Assert-False $script:vf4_verifyCalled 'VF4 [kill] no commit -> verify is NOT run (nothing to verify)'

# VF5*: coder TIMEOUT -> the work is JUDGED, not deleted (#1370).
#
# THIS ASSERTION WAS DELIBERATELY REVERSED on 2026-08-10. It previously read:
#
#     Assert-False $script:vf5_commitCalled 'VF5 [kill] coder timeout -> commit is NOT
#                                            attempted (no partial work)'
#
# and its comment called that "no partial work" — an intentional-sounding name for
# throwing away everything a bounded coder had written. MEASURED across two B9 runs:
# 35 fix cycles, 11 applied, 24 discarded, and ALL 24 were this branch. Not one was
# rejected on merit. `create-home-page` lost 3 of 3 on both runs, which is why the
# operator's placeholder front door (#1367) survived a whole night of a loop explicitly
# trying to fix it.
#
# A test pinned to a behaviour argues against fixing that behaviour, exactly as three
# tests pinned to the old DOOM_STALL_GRACE_S value kept a wrong window for a month
# (#1366). Rewritten rather than deleted, so the reversal is legible.
#
# The safety property is UNCHANGED and is asserted below: a bounded coder's rebuild that
# fails verify is still never merged. What changed is the default for interrupted work —
# from "assume it is worthless" to "ask the gate", which is what the base-candidate path
# has always said: "work kept, the gate decides the merge".

# VF5a: timeout + the coder DID write something + verify pass + clean merge -> APPLIED.
$script:vf5a_commitCalled = $false
$vf5a = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $true } } `
    -CommitFix { $script:vf5a_commitCalled = $true; $true } -Verify { 'pass' } -ReMerge { $true }
Assert-True  $script:vf5a_commitCalled 'VF5a [kill] coder timeout -> the commit IS attempted (a bounded coder is not an empty one)'
Assert-True  $vf5a.Applied 'VF5a timeout + real work + verify pass + clean merge -> Applied=$true (#1370)'
Assert-Contains $vf5a.Reason 'time-bounded' 'VF5a the record says the coder was bounded rather than hiding it'

# VF5b: timeout + the coder wrote NOTHING -> honest no-op, not a silent deletion.
$vf5b = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $true } } `
    -CommitFix { $false } -Verify { 'pass' } -ReMerge { $true }
Assert-False $vf5b.Applied 'VF5b timeout + nothing written -> Applied=$false'
Assert-Contains $vf5b.Reason 'produced no changes' 'VF5b names the REAL reason (empty), not the timeout'
Assert-Contains $vf5b.Reason 'time-bounded' 'VF5b still records that the coder was bounded'

# VF5c: timeout + the rebuild FAILS verify -> STILL never merged. The safety property that
# actually protects the operator is stage 3, not the old early return.
$script:vf5c_mergeCalled = $false
$vf5c = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $true } } `
    -CommitFix { $true } -Verify { 'fail' } -ReMerge { $script:vf5c_mergeCalled = $true; $true }
Assert-False $vf5c.Applied 'VF5c [kill] timeout + verify FAIL -> Applied=$false (a broken rebuild is still never merged)'
Assert-False $script:vf5c_mergeCalled 'VF5c [kill] timeout + verify FAIL -> the re-merge is NEVER attempted'

# VF6: a thrown mechanism is CAUGHT (never a task failure) -> ABORT.
$vf6 = Invoke-VisualFixPass -RunCoder { throw 'simulated coder crash' } `
    -CommitFix { $true } -Verify { 'pass' } -ReMerge { $true }
Assert-False $vf6.Applied 'VF6 a thrown mechanism is caught -> Applied=$false (no exception escapes)'
Assert-Contains $vf6.Reason 'simulated coder crash' 'VF6 the underlying error is surfaced in the reason'

# VF7: verify 'none' (gate could not run) does NOT block -> APPLIED (mirrors the merge gate: only 'fail' blocks).
$vf7 = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false } } `
    -CommitFix { $true } -Verify { 'none' } -ReMerge { $true }
Assert-True $vf7.Applied 'VF7 verify "none" (gate skipped) does NOT block -> Applied=$true (only "fail" blocks)'

# VF8: no exception ever escapes Invoke-VisualFixPass (even when every mechanism throws).
$vf8threw = $false
try { Invoke-VisualFixPass -RunCoder { throw 'a' } -CommitFix { throw 'b' } -Verify { throw 'c' } -ReMerge { throw 'd' } | Out-Null } catch { $vf8threw = $true }
Assert-False $vf8threw 'VF8 [kill] Invoke-VisualFixPass never lets an exception escape (the task cannot fail on a FIX error)'

# =============================================================================
Section 'IL* -- integrated auto-FIX loop: iteration counts + feedback threading'
# Drive Invoke-CritiqueLoop with a REAL auto-FIX-style callback (Invoke-VisualFixPass with
# stubbed mechanisms) + the stubbed critique, proving the loop iterates the right number of
# times, each FIX gets the LATEST feedback, and the loop stops on PASS / cap / abort.

# IL1: needs_work -> FIX -> PASS stops after the FIX+re-critique (2 critique passes, 1 FIX).
$script:il1_feedbacks = New-Object System.Collections.ArrayList
$il1Cb = {
    param($Feedback, $AppDir)
    [void]$script:il1_feedbacks.Add($Feedback)
    $r = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false } } -CommitFix { $true } -Verify { 'pass' } -ReMerge { $true }
    return $AppDir
}
$il1 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '["x criterion"]' -MaxIter 3 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiqueNeedsWorkStub, $critiquePassStub) `
    -RebuildCallback $il1Cb
Assert-Eq 2 $il1.Iterations 'IL1 needs_work -> FIX -> PASS: exactly 2 critique passes'
Assert-Eq 1 $script:il1_feedbacks.Count 'IL1 exactly 1 FIX iteration fired'
Assert-False $il1.FinalResult.ShouldIterate 'IL1 loop stopped (PASS on the re-critique)'
Assert-True  $il1.FinalResult.Ok 'IL1 final critique passed'

# IL2: always needs_work -> stops at MaxIter (bounded); FIX fires (MaxIter-1) times.
$script:il2_fixes = 0
$il2Cb = {
    param($Feedback, $AppDir)
    $script:il2_fixes++
    return $AppDir
}
$il2 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '["x criterion"]' -MaxIter 2 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiqueNeedsWorkStub) `
    -RebuildCallback $il2Cb
Assert-Eq 2 $il2.Iterations 'IL2 always-needs_work -> stops at MaxIter (2 critique passes)'
# The real CLI returns should_iterate = (iteration < max_iter), true throughout [0, MaxIter), so
# the FIX callback fires once PER critique pass while needs_work persists; the `while ($iteration
# -lt $MaxIter)` guard caps re-entry. With MaxIter=2 that is 2 FIX fires (bounded, never infinite).
Assert-Eq 2 $script:il2_fixes 'IL2 FIX fires once per pass while needs_work persists, capped at MaxIter (=2)'
Assert-False $il2.FinalResult.ShouldIterate 'IL2 ShouldIterate forced False at the cap (bounded)'

# IL3: each FIX gets the LATEST feedback (the feedback threads from critique -> callback).
$script:il3_feedbacks = New-Object System.Collections.ArrayList
$il3Cb = { param($Feedback, $AppDir); [void]$script:il3_feedbacks.Add($Feedback); return $AppDir }
# Two distinct needs_work feedbacks, then PASS.
$nw1 = Make-CritiqueJsonStub -NeedsWork $true -ShouldIterate $true -Feedback 'Round the corners.'
$nw2 = Make-CritiqueJsonStub -NeedsWork $true -ShouldIterate $true -Feedback 'Increase the title size.'
$il3 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '["x criterion"]' -MaxIter 3 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($nw1, $nw2, $critiquePassStub) `
    -RebuildCallback $il3Cb
Assert-Eq 2 $script:il3_feedbacks.Count 'IL3 two FIX iterations (needs_work x2 then PASS)'
Assert-Contains ($script:il3_feedbacks[0]) 'Round the corners' 'IL3 the FIRST FIX gets the first critique feedback'
Assert-Contains ($script:il3_feedbacks[1]) 'Increase the title size' 'IL3 the SECOND FIX gets the LATEST (second) critique feedback'

# IL4: a FIX that ABORTS (verify fail) still returns $AppDir; the loop re-critiques and remains bounded.
$script:il4_fixes = 0
$il4Cb = {
    param($Feedback, $AppDir)
    $script:il4_fixes++
    $r = Invoke-VisualFixPass -RunCoder { @{ TimedOut = $false } } -CommitFix { $true } -Verify { 'fail' } -ReMerge { $true }
    # Even on abort the callback returns the AppDir (the loop keeps the prior merged version + re-critiques).
    return $AppDir
}
$il4 = Invoke-CritiqueLoopStubbed -Goal 'Test' -VisualCriteriaJson '["x criterion"]' -MaxIter 2 `
    -WorkDir $workDir -CaptureStub $captureOkStub `
    -CritiqueStubs @($critiqueNeedsWorkStub) `
    -RebuildCallback $il4Cb
Assert-Eq 2 $il4.Iterations 'IL4 a FIX-abort still bounds the loop at MaxIter (no infinite loop)'
Assert-Eq 2 $script:il4_fixes 'IL4 the FIX callback ran each pass (capped at MaxIter=2); a FIX-abort never un-bounds the loop'

# =============================================================================
Section 'AF* -- new-agent-task.ps1 hook: auto-FIX wiring (source assertions)'
# (reuse $nat from the GA section above)
# AF1: the no-op rebuild callback is GONE; a real auto-FIX callback is wired.
Assert-False ([regex]::IsMatch($nat, '\$rebuildNoop\b')) `
    'AF1 [kill] the v1 no-op rebuild callback ($rebuildNoop) is removed'
Assert-True ([regex]::IsMatch($nat, '\$rebuildAutoFix\s*=')) `
    'AF2 a real auto-FIX rebuild callback ($rebuildAutoFix) is defined'

# AF3: the callback calls Invoke-VisualFixPass (the unit-tested policy) -- not a re-implemented loop.
Assert-True ([regex]::IsMatch($nat, 'Invoke-VisualFixPass\b')) `
    'AF3 the auto-FIX callback invokes Invoke-VisualFixPass'

# AF4: the FIX prompt is composed via Add-VisualFeedback off the ORIGINAL prompt.
Assert-True ([regex]::IsMatch($nat, 'Add-VisualFeedback -Prompt \$OrigPrompt -Feedback \$Feedback')) `
    'AF4 the FIX prompt = Add-VisualFeedback over $OrigPrompt + the VLM $Feedback'

# AF5: it REUSES the existing build machinery (Invoke-BuildWithRetry + Invoke-AgentRun), not a new coder run.
Assert-True ([regex]::IsMatch($nat, 'Invoke-VisualFixPass[\s\S]{0,400}Invoke-BuildWithRetry[\s\S]{0,200}Invoke-AgentRun')) `
    'AF5 [kill] the RunCoder mechanism reuses Invoke-BuildWithRetry + Invoke-AgentRun (existing [1/5] machinery)'

# AF6: it REUSES the existing verify gate (verify-project.ps1).
Assert-True ([regex]::IsMatch($nat, 'Invoke-VisualFixPass[\s\S]{0,1200}verify-project\.ps1')) `
    'AF6 the Verify mechanism reuses verify-project.ps1 (existing [3/5] gate)'

# AF7: the ReMerge mechanism merges the branch into the base AND aborts on conflict (merge --abort).
Assert-True ([regex]::IsMatch($nat, 'git -C \$Repo merge \$branch[\s\S]{0,200}merge --abort')) `
    'AF7 [kill] ReMerge does `git merge $branch` then `git merge --abort` on a non-clean result (keeps main intact)'

# AF8: the loop is bounded (MaxIter small) and uses the auto-FIX callback.
Assert-True ([regex]::IsMatch($nat, 'Invoke-CritiqueLoop[\s\S]{0,300}-MaxIter \d[\s\S]{0,120}-RebuildCallback \$rebuildAutoFix')) `
    'AF8 the loop passes a small -MaxIter and the $rebuildAutoFix callback'

# AF9: the callback ALWAYS returns the AppDir (so the loop re-captures), even on abort.
Assert-True ([regex]::IsMatch($nat, '\$rebuildAutoFix\s*=\s*\{[\s\S]{0,5000}return \$AppDir')) `
    'AF9 the auto-FIX callback returns $AppDir (the loop re-captures the rebuilt app)'

# AF10 [regression 2026-06-25]: the $rebuildAutoFix callback is a PLAIN scriptblock, NOT
# .GetNewClosure()'d. GetNewClosure() rebinds the block's FUNCTION lookup to GLOBAL, so when
# new-agent-task.ps1 runs nested (run-fleet -> & new-agent-task.ps1, two levels deep) the dot-sourced
# fleet-lib functions it calls (Add-VisualFeedback / Invoke-VisualFixPass / Invoke-BuildWithRetry /
# Invoke-AgentRun) become invisible -> "is not recognized" at runtime, skipping the entire auto-FIX.
# Caught live 2026-06-25; the in-scope one-level unit mocks never crossed that boundary.
# Match the CODE usage only (a closing brace immediately followed by .GetNewClosure()), never the
# prose mention of the term in the explanatory comment above the callback.
Assert-False ([regex]::IsMatch($nat, '\}\s*\.GetNewClosure\s*\(\s*\)')) `
    'AF10 [kill] no scriptblock in new-agent-task.ps1 is .GetNewClosure()d (the $rebuildAutoFix callback must stay plain -> nested function-visibility)'

Section 'CB* -- callback function-visibility across the nested-script boundary (GetNewClosure pitfall)'
# Behavioral proof of AF10: a function defined in a NESTED (&-invoked) script scope is visible to a
# PLAIN callback (which binds to that script scope) but NOT to a .GetNewClosure()'d one (which rebinds
# its function lookup to global). This is the exact two-level boundary the live fleet crosses.
$cbChild = Join-Path $scratch 'cb_nesting_probe.ps1'
@'
function Probe-NestedScopeFn { 'RESOLVED' }
function Invoke-LikeLoop { param([scriptblock]$cb) try { & $cb } catch { 'THREW:' + $_.Exception.Message } }
'plain='  + (Invoke-LikeLoop { Probe-NestedScopeFn })
'frozen=' + (Invoke-LikeLoop ({ Probe-NestedScopeFn }.GetNewClosure()))
'@ | Set-Content $cbChild -Encoding UTF8
# &-invoke the child so it runs NESTED (one & level under this -File harness), exactly like
# new-agent-task.ps1 under run-fleet. The child's function lands in the child's script scope.
$cbOut = (& $cbChild) -join "`n"
Assert-Contains $cbOut 'plain=RESOLVED' 'CB1 a PLAIN callback resolves a nested-script-scope function (the fix new-agent-task.ps1 uses)'
Assert-Contains $cbOut 'frozen=THREW'   'CB1 [kill] a .GetNewClosure() callback FAILS to resolve it (reproduces the live 2026-06-25 bug)'

# =============================================================================
Section 'MD* -- Merge-DesignSignals: the Lever A (layout) + Lever C (VLM) combination'
# The CORE of the false-pass fix: a HARD deterministic layout finding forces a FIX even
# when the soft VLM passed.

# MD1 [kill]: layout-hard OVERRIDES a VLM pass.
$md = Merge-DesignSignals -LayoutHard $true -LayoutMessages @('Display and Keypad overlap.') `
    -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-True  $md.ShouldIterate 'MD1 [kill] a hard layout finding forces a FIX even when the VLM PASSED (the false-pass fix)'
Assert-True  $md.NeedsWork     'MD1 needs_work is true when the layout gate is hard'
Assert-Contains $md.Feedback 'overlap' 'MD1 feedback carries the deterministic layout finding'
Assert-Contains $md.Feedback 'fix these FIRST' 'MD1 feedback leads with the layout issues'

# MD2: clean layout + VLM pass -> stop (do not nag a good layout).
$md = Merge-DesignSignals -LayoutHard $false -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-False $md.ShouldIterate 'MD2 clean layout + VLM pass -> stop'
Assert-False $md.NeedsWork     'MD2 needs_work false when both are clean'
Assert-Eq 'All criteria met.' $md.Feedback 'MD2 only the VLM feedback when layout is clean'

# MD3: VLM needs-work drives iteration even with a clean layout (Lever C alone still works).
$md = Merge-DesignSignals -LayoutHard $false -VlmOk $true -VlmNeedsWork $true -VlmShouldIterate $true -VlmFeedback 'Buttons too small.' -Iteration 0 -MaxIter 3
Assert-True  $md.ShouldIterate 'MD3 the VLM needs-work signal drives iteration with a clean layout'
Assert-Contains $md.Feedback 'Buttons too small' 'MD3 the VLM feedback is carried'

# MD4 [kill]: layout-hard but the iteration budget is spent -> NO iteration (bounded).
$md = Merge-DesignSignals -LayoutHard $true -LayoutMessages @('overlap') -VlmShouldIterate $false -VlmFeedback '' -Iteration 3 -MaxIter 3
Assert-False $md.ShouldIterate 'MD4 [kill] layout-hard does NOT iterate past the MaxIter budget (bounded)'
Assert-True  $md.NeedsWork     'MD4 needs_work still true at the cap (the defect is real even when we stop)'

# MD5 [kill]: messages WITHOUT LayoutHard never force iteration (Hard is the gate, not the count).
$md = Merge-DesignSignals -LayoutHard $false -LayoutMessages @('a low note') -VlmShouldIterate $false -VlmFeedback 'ok' -Iteration 0 -MaxIter 3
Assert-False $md.ShouldIterate 'MD5 [kill] messages without LayoutHard do not force iteration'
Assert-Eq 'ok' $md.Feedback 'MD5 layout messages are omitted from feedback when not hard'

# =============================================================================
Section 'MDP* -- Merge-DesignSignals: the Lever B (rendered-pixel) deterministic gate'
# The pixel gate is a SECOND deterministic lever (colour/geometry from the screenshot); like the
# layout gate, a hard pixel finding forces a FIX even when the soft VLM passed. PixelHard/
# PixelMessages default inert so every pre-pixel caller above is byte-identical.

# MDP1 [kill]: a hard PIXEL finding OVERRIDES a VLM pass (the colour/geometry false-pass fix).
$md = Merge-DesignSignals -LayoutHard $false -PixelHard $true -PixelMessages @('blue is essentially absent from the render.') `
    -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-True  $md.ShouldIterate 'MDP1 [kill] a hard pixel finding forces a FIX even when the VLM PASSED'
Assert-True  $md.NeedsWork     'MDP1 needs_work true when the pixel gate is hard'
Assert-True  $md.LayoutHard    'MDP1 returned LayoutHard means ANY deterministic hard (so Python _design_note reports pixel hits)'
Assert-Contains $md.Feedback 'essentially absent' 'MDP1 feedback carries the deterministic pixel finding'
Assert-Contains $md.Feedback 'rendered-pixel' 'MDP1 feedback labels the pixel section'

# MDP2 [kill]: pixel-hard but the iteration budget is spent -> NO iteration (bounded, like layout).
$md = Merge-DesignSignals -LayoutHard $false -PixelHard $true -PixelMessages @('blank') -VlmShouldIterate $false -VlmFeedback '' -Iteration 3 -MaxIter 3
Assert-False $md.ShouldIterate 'MDP2 [kill] pixel-hard does NOT iterate past the MaxIter budget (bounded)'
Assert-True  $md.NeedsWork     'MDP2 needs_work still true at the cap'

# MDP3 [kill]: pixel messages WITHOUT PixelHard never force iteration nor appear (Hard is the gate).
$md = Merge-DesignSignals -LayoutHard $false -PixelHard $false -PixelMessages @('a soft note') -VlmShouldIterate $false -VlmFeedback 'ok' -Iteration 0 -MaxIter 3
Assert-False $md.ShouldIterate 'MDP3 [kill] pixel messages without PixelHard do not force iteration'
Assert-Eq 'ok' $md.Feedback 'MDP3 pixel messages are omitted from feedback when not hard'

# MDP4 [kill]: BOTH layout-hard and pixel-hard -> feedback carries BOTH, layout section FIRST.
$md = Merge-DesignSignals -LayoutHard $true -LayoutMessages @('Display overlap.') -PixelHard $true -PixelMessages @('green absent.') `
    -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback '' -Iteration 0 -MaxIter 3
Assert-True  $md.ShouldIterate 'MDP4 either deterministic gate hard -> iterate'
Assert-Contains $md.Feedback 'Display overlap' 'MDP4 layout section present'
Assert-Contains $md.Feedback 'green absent' 'MDP4 pixel section present'
Assert-True ($md.Feedback.IndexOf('Display overlap') -lt $md.Feedback.IndexOf('green absent')) 'MDP4 [kill] layout issues lead, pixel issues follow'

# MDP5 [kill]: omitting ALL pixel params reproduces the pre-pixel behavior byte-for-byte.
$md = Merge-DesignSignals -LayoutHard $false -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-Eq 'All criteria met.' $md.Feedback 'MDP5 [kill] omitting pixel params reproduces the pre-pixel feedback exactly'
Assert-False $md.ShouldIterate 'MDP5 omitting pixel params -> unchanged stop behavior'

# =============================================================================
Section 'MDR* -- Merge-DesignSignals: the Lever D (browser RUNTIME) gate (#823 H8/H9)'
# The runtime gate is the fix for the pixel-BLINDNESS class (B5n2): a console error / uncaught
# exception the VLM cannot see forces a FIX and LEADS the feedback (ranked above the cosmetic
# critique). RuntimeHard/RuntimeMessages default inert so every pre-runtime caller above is
# byte-identical.

$_b5err = 'Uncaught exception: ReferenceError: sum is not defined (chart.js:10)'

# MDR1 [kill]: a hard RUNTIME finding OVERRIDES a VLM pass (the console-blindness false-pass fix).
$md = Merge-DesignSignals -LayoutHard $false -RuntimeHard $true -RuntimeMessages @($_b5err) `
    -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-True  $md.ShouldIterate 'MDR1 [kill] a hard runtime finding forces a FIX even when the VLM PASSED (the B5 shape)'
Assert-True  $md.NeedsWork     'MDR1 needs_work true when the runtime gate is hard'
Assert-True  $md.RuntimeHard   'MDR1 RuntimeHard is returned distinctly (so Python names it a runtime error, not layout)'
Assert-True  $md.LayoutHard    'MDR1 returned LayoutHard means ANY deterministic hard (runtime included)'
Assert-Contains $md.Feedback 'sum is not defined' 'MDR1 feedback carries the runtime error VERBATIM (file/line/message)'
Assert-Contains $md.Feedback 'Runtime errors' 'MDR1 feedback labels the runtime section'

# MDR2 [kill]: runtime findings LEAD -- ranked ABOVE layout, pixel, AND the VLM (fix the error first).
$md = Merge-DesignSignals -LayoutHard $true -LayoutMessages @('Display overlap.') `
    -PixelHard $true -PixelMessages @('green absent.') -RuntimeHard $true -RuntimeMessages @($_b5err) `
    -VlmOk $true -VlmNeedsWork $true -VlmShouldIterate $true -VlmFeedback 'Buttons too small.' -Iteration 0 -MaxIter 3
Assert-True ($md.Feedback.IndexOf('sum is not defined') -lt $md.Feedback.IndexOf('Display overlap')) 'MDR2 [kill] runtime leads layout'
Assert-True ($md.Feedback.IndexOf('Display overlap') -lt $md.Feedback.IndexOf('green absent')) 'MDR2 layout still precedes pixel'
Assert-True ($md.Feedback.IndexOf('green absent') -lt $md.Feedback.IndexOf('Buttons too small')) 'MDR2 the VLM (cosmetic) feedback is last'

# MDR3 [kill]: runtime-hard but the iteration budget is spent -> NO iteration (bounded).
$md = Merge-DesignSignals -LayoutHard $false -RuntimeHard $true -RuntimeMessages @('boom') -VlmShouldIterate $false -VlmFeedback '' -Iteration 3 -MaxIter 3
Assert-False $md.ShouldIterate 'MDR3 [kill] runtime-hard does NOT iterate past the MaxIter budget (bounded)'
Assert-True  $md.NeedsWork     'MDR3 needs_work still true at the cap (the error is real even when we stop)'

# MDR4 [kill]: runtime messages WITHOUT RuntimeHard never force iteration nor appear (Hard is the gate).
$md = Merge-DesignSignals -LayoutHard $false -RuntimeHard $false -RuntimeMessages @('a soft note') -VlmShouldIterate $false -VlmFeedback 'ok' -Iteration 0 -MaxIter 3
Assert-False $md.ShouldIterate 'MDR4 [kill] runtime messages without RuntimeHard do not force iteration'
Assert-Eq 'ok' $md.Feedback 'MDR4 runtime messages are omitted from feedback when not hard'
Assert-False $md.RuntimeHard 'MDR4 RuntimeHard false is returned when not hard'

# MDR5 [kill]: omitting ALL runtime params reproduces the pre-runtime behavior byte-for-byte.
$md = Merge-DesignSignals -LayoutHard $false -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-Eq 'All criteria met.' $md.Feedback 'MDR5 [kill] omitting runtime params reproduces the pre-runtime feedback exactly'
Assert-False $md.ShouldIterate 'MDR5 omitting runtime params -> unchanged stop behavior'
Assert-False $md.RuntimeHard 'MDR5 RuntimeHard defaults false when the param is omitted'

# =============================================================================
Section 'RCS* -- Read-ConsoleSidecar: the browser-runtime sidecar reader (#823, honest degraded)'
$rcsDir = Join-Path $scratch 'rcs'
New-Item -ItemType Directory -Force $rcsDir | Out-Null

# RCS1 [kill]: a MISSING sidecar -> no runtime signal (WinUI capture / structural floor / old capture).
$r = Read-ConsoleSidecar -SidecarPath (Join-Path $rcsDir 'nope.console.json')
Assert-False $r.Captured 'RCS1 [kill] missing sidecar -> Captured=$false'
Assert-False $r.Hard     'RCS1 missing sidecar -> Hard=$false'
Assert-Eq 0 $r.Messages.Count 'RCS1 missing sidecar -> no messages'

# RCS2 [kill]: a captured:false sidecar (the msedge --screenshot fallback) -> HONEST no-signal.
$s2 = Join-Path $rcsDir 's2.console.json'
'{"captured":false,"error":"cdp unavailable","console":[],"pageErrors":[],"findings":["ignored because captured=false"]}' | Set-Content $s2 -Encoding UTF8
$r = Read-ConsoleSidecar -SidecarPath $s2
Assert-False $r.Captured 'RCS2 [kill] captured:false (pixel-only fallback) -> Captured=$false (never fakes a verdict)'
Assert-False $r.Hard     'RCS2 captured:false -> Hard=$false'
Assert-Eq 0 $r.Messages.Count 'RCS2 captured:false -> findings ignored (no runtime signal)'

# RCS3 [kill]: a captured:true + hard:true sidecar -> the verbatim finding rides the signal (the B5 catch).
$s3 = Join-Path $rcsDir 's3.console.json'
('{"captured":true,"hard":true,"errorCount":2,"findings":[' +
 '"' + $_b5err + '","Rendered text contains \"undefined\""]}') | Set-Content $s3 -Encoding UTF8
$r = Read-ConsoleSidecar -SidecarPath $s3
Assert-True  $r.Captured 'RCS3 [kill] captured:true -> Captured=$true'
Assert-True  $r.Hard     'RCS3 hard:true -> Hard=$true (forces a FIX)'
Assert-Contains ($r.Messages -join ' | ') 'sum is not defined' 'RCS3 the verbatim runtime finding is carried'

# RCS4 [kill]: a captured:true + hard:false sidecar (a clean page) -> the zero-error PASS signal.
$s4 = Join-Path $rcsDir 's4.console.json'
'{"captured":true,"hard":false,"errorCount":0,"findings":[]}' | Set-Content $s4 -Encoding UTF8
$r = Read-ConsoleSidecar -SidecarPath $s4
Assert-True  $r.Captured 'RCS4 captured:true clean -> Captured=$true (belt: console channel ran)'
Assert-False $r.Hard     'RCS4 [kill] zero console errors -> Hard=$false (a PASS signal, no forced fix)'
Assert-Eq 0 $r.Messages.Count 'RCS4 clean page -> no runtime findings'

# RCS5 [kill]: garbled JSON -> fail-soft to no-signal (never throws).
$s5 = Join-Path $rcsDir 's5.console.json'
'{not valid json at all' | Set-Content $s5 -Encoding UTF8
$r = Read-ConsoleSidecar -SidecarPath $s5
Assert-False $r.Captured 'RCS5 [kill] garbled sidecar JSON -> Captured=$false (fail-soft, never throws)'
Assert-False $r.Hard     'RCS5 garbled sidecar -> Hard=$false'

# =============================================================================
Section 'LA* -- layout gate forces a FIX through the full critique pass (Lever A integration)'

# LA1 [kill]: the VLM PASSES but the layout gate is HARD -> the pass returns ShouldIterate=$true.
$la = Invoke-CritiquePassStubbed -BlarAiRepo $fakeBlarAI -AppDir $fakeAppDir -WorkDir $workDir -Iteration 0 -MaxIter 3 `
    -CaptureStub $captureOkStub -CritiqueStub $critiquePassStub `
    -LayoutHard $true -LayoutMessages @('Display and Keypad overlap.')
Assert-True  $la.ShouldIterate 'LA1 [kill] a hard layout finding forces a FIX even when the VLM passed (end-to-end pass)'
Assert-True  $la.LayoutHard    'LA1 LayoutHard is surfaced on the pass result'
Assert-Contains $la.Feedback 'overlap' 'LA1 the layout finding reaches the coder feedback'

# LA2 [kill]: the STRUCTURAL FLOOR (no pixels) + hard layout STILL forces a FIX.
$la = Invoke-CritiquePassStubbed -BlarAiRepo $fakeBlarAI -AppDir $fakeAppDir -WorkDir $workDir -Iteration 0 -MaxIter 3 `
    -CaptureStub $captureStructuralStub -LayoutHard $true -LayoutMessages @('Grid.Row 5 is out of range.')
Assert-True  $la.ShouldIterate 'LA2 [kill] the layout gate fires on the structural floor (no pixels needed)'
Assert-Contains $la.Feedback 'out of range' 'LA2 structural-floor feedback carries the layout finding'

# LA3: structural floor + CLEAN layout -> the floor stays quiet (prior behavior preserved).
$la = Invoke-CritiquePassStubbed -BlarAiRepo $fakeBlarAI -AppDir $fakeAppDir -WorkDir $workDir -Iteration 0 -MaxIter 3 `
    -CaptureStub $captureStructuralStub -LayoutHard $false
Assert-False $la.ShouldIterate 'LA3 structural floor + clean layout -> no iteration (floor stays quiet)'

# LA4: VLM needs_work + clean layout -> still iterates (the merge is non-destructive to Lever C).
$la = Invoke-CritiquePassStubbed -BlarAiRepo $fakeBlarAI -AppDir $fakeAppDir -WorkDir $workDir -Iteration 0 -MaxIter 3 `
    -CaptureStub $captureOkStub -CritiqueStub $critiqueNeedsWorkStub -LayoutHard $false
Assert-True  $la.ShouldIterate 'LA4 VLM needs_work still drives iteration with a clean layout'

# =============================================================================
Section 'LL* -- Invoke-LayoutLint: fail-soft'
# The fake BlarAI repo has a .venv\Scripts dir but no python.exe -> fail-soft empty result.
$ll = Invoke-LayoutLint -AppDir $fakeAppDir -BlarAiRepo $fakeBlarAI
Assert-False $ll.Hard 'LL1 no python.exe -> Hard=$false (fail-soft, never errors)'
Assert-Eq '[]' $ll.MessagesJson 'LL1 no python -> MessagesJson is an empty JSON array'
Assert-Eq 0 @($ll.Messages).Count 'LL1 no python -> no messages'

# =============================================================================
Section 'PL* -- Invoke-PixelLint: fail-soft'
# Missing PNG -> empty result (python is never even invoked).
$pl = Invoke-PixelLint -Png (Join-Path $scratch 'no-such.png') -BlarAiRepo $fakeBlarAI
Assert-False $pl.Hard 'PL1 missing PNG -> Hard=$false (fail-soft, never errors)'
Assert-Eq '[]' $pl.MessagesJson 'PL1 missing PNG -> MessagesJson is an empty JSON array'
# PNG present but the fake repo has no python.exe -> fail-soft empty (same contract as Invoke-LayoutLint).
$fakePng = Join-Path $scratch 'present.png'
Set-Content -Path $fakePng -Value 'x' -NoNewline
$pl = Invoke-PixelLint -Png $fakePng -BlarAiRepo $fakeBlarAI
Assert-False $pl.Hard 'PL2 PNG present but no python.exe -> Hard=$false (fail-soft)'
Assert-Eq 0 @($pl.Messages).Count 'PL2 no python -> no messages'

# =============================================================================
Section 'LM* -- #1198: fail-soft is not fail-silent -- a lint that DID NOT RUN never reads as clean'
# THE DEFECT (#1198): both lints returned @{ Hard=$false; Messages=@() } on EVERY failure path, so a
# missing tool, an unreadable input and a crash were byte-identical to "ran, found nothing". A missing
# layout tool meant every deliverable on the node-web/web/winui surfaces reported a clean layout, forever,
# silently. These lock the distinction at the source -- Measured is the gate, never the message count.

# LM1 [kill]: the tool is absent -> UNMEASURED, with the cause carried.
$lm = Invoke-LayoutLint -AppDir $fakeAppDir -BlarAiRepo $fakeBlarAI
Assert-False ([bool]$lm.Measured) 'LM1 [kill] no interpreter -> Measured=$false (an absent lint cannot certify a layout)'
Assert-Eq 'unavailable' $lm.Status 'LM1 status is unavailable, NOT clean'
Assert-Contains $lm.Detail 'python' 'LM1 [kill] the cause is carried, so the operator can see WHY it did not run'
Assert-False ([bool]$lm.Hard) 'LM1 an unmeasured lint forces nothing (it found no defect -- it found nothing)'

# LM2 [kill]: same for the pixel lint, both of its pre-flight refusals.
$lm = Invoke-PixelLint -Png (Join-Path $scratch 'no-such.png') -BlarAiRepo $fakeBlarAI
Assert-False ([bool]$lm.Measured) 'LM2 [kill] missing PNG -> Measured=$false (nothing was rendered to examine)'
Assert-Eq 'unavailable' $lm.Status 'LM2 status is unavailable, NOT clean'
$lm = Invoke-PixelLint -Png $fakePng -BlarAiRepo $fakeBlarAI
Assert-False ([bool]$lm.Measured) 'LM2b [kill] PNG present but no interpreter -> Measured=$false'
Assert-Contains $lm.Detail 'python' 'LM2b the cause is carried'

# LM3: the caveat renderer is PURE and says the one thing that matters, in both degraded shapes.
$cv = Format-DesignLintCaveat -Lint 'layout' -Measured $false -Status 'unavailable' -Detail 'no BlarAI python interpreter at X'
Assert-Contains $cv 'DID NOT RUN'   'LM3 an unavailable lint is reported as DID NOT RUN'
Assert-Contains $cv 'UNEXAMINED'    'LM3 [kill] and names the axis as UNEXAMINED'
Assert-Contains $cv 'not a clean one' 'LM3 [kill] and refuses the clean reading in words'
$cv = Format-DesignLintCaveat -Lint 'pixel' -Measured $false -Status 'not-applicable' -Detail 'no screenshot was captured'
Assert-Contains $cv 'NOTHING TO EXAMINE' 'LM3b a not-applicable lint is distinguished from a broken one'
Assert-Contains $cv 'rendered-pixel'     'LM3b and names which lint it is'
Assert-Eq '' (Format-DesignLintCaveat -Lint 'layout' -Measured $true) 'LM3c [kill] a MEASURED lint emits NO caveat (the channel is silent when everything reported)'

# LM4: a PARTIAL examination is its own fact -- files the lint could not parse are disclosed, not absorbed.
$cv = Format-DesignLintCaveat -Lint 'layout' -Measured $true -Unparsed @('Broken.xaml')
Assert-Contains $cv 'SKIPPED 1 file' 'LM4 [kill] a measured-but-partial lint still discloses what it skipped'
Assert-Contains $cv 'Broken.xaml'    'LM4 and names the file'
Assert-Contains $cv 'not a clean one' 'LM4 [kill] and refuses the clean reading for those files'

# =============================================================================
Section 'LMV* -- #1198: an UNMEASURED lint changes the REPORT, never the VERDICT'
# The deliberate call (ticket item 4). Unmeasured must not silently become a hard failure -- forcing a FIX
# lap over an absent measurement spends the iteration budget re-running the coder against nothing, and
# asserts a defect was found when none was. Nor may it be silence. So it rides its own channel.

$mMeasured = Merge-DesignSignals -LayoutHard $false -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false `
    -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
$mAbsent = Merge-DesignSignals -LayoutHard $false -LayoutMeasured $false -LayoutStatus 'unavailable' `
    -LayoutDetail 'no BlarAI python interpreter at X' -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false `
    -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
Assert-False $mAbsent.ShouldIterate 'LMV1 [kill] an UNMEASURED lint does NOT force a FIX lap (a broken tool must not burn the iteration budget)'
Assert-False $mAbsent.NeedsWork     'LMV1 [kill] nor does it assert a defect was found -- none was'
Assert-Eq $mMeasured.Feedback $mAbsent.Feedback 'LMV1 [kill] the CODER-facing feedback is byte-identical (the coder cannot fix a missing interpreter)'
Assert-False ([bool]$mAbsent.LintsMeasured) 'LMV2 [kill] but LintsMeasured is FALSE, so the report can never call this examined'
Assert-Contains $mAbsent.CaveatText 'DID NOT RUN' 'LMV2 and the caveat channel carries the absence'
Assert-Contains $mAbsent.CaveatText 'python'      'LMV2 [kill] with the cause, not just the fact'

# LMV3 [kill]: omitting the #1198 params reproduces the prior behavior byte-for-byte (inert default).
Assert-True  ([bool]$mMeasured.LintsMeasured) 'LMV3 [kill] omitting the measured params -> LintsMeasured true (inert default, pre-#1198 callers unchanged)'
Assert-Eq '' $mMeasured.CaveatText            'LMV3 [kill] and NO caveat text (the channel is silent)'
Assert-Eq 0 @($mMeasured.Caveats).Count       'LMV3 and no caveat entries'

# LMV4: a HARD finding still overrides regardless -- the measured channel is orthogonal to the verdict.
$mHardAbsent = Merge-DesignSignals -LayoutHard $false -PixelHard $true -PixelMessages @('blue is absent.') `
    -LayoutMeasured $false -LayoutStatus 'unavailable' -LayoutDetail 'gone' `
    -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback '' -Iteration 0 -MaxIter 3
Assert-True $mHardAbsent.ShouldIterate 'LMV4 [kill] an unmeasured layout lint does not suppress a hard PIXEL finding'
Assert-Contains $mHardAbsent.Feedback 'blue is absent' 'LMV4 the real finding still reaches the coder'
Assert-False ([bool]$mHardAbsent.LintsMeasured) 'LMV4 and the absence is still disclosed alongside it'

# =============================================================================
Section 'LMR* -- #1198: the REAL layout lint, tested ON and toggled OFF (principle 12)'
# Principle 12: a control ships with a test proving it FIRES when engaged and a toggle proving the probe
# FAILS when the lock is off -- otherwise "secure" and "the test cannot reach it" are indistinguishable.
# These run the REAL shared/fleet/layout_lint.py over REAL crafted XAML through the REAL Invoke-LayoutLint.
$lmrRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' })
$lmrRoot = Join-Path $scratch 'lmr'
$lmrBroken = Join-Path $lmrRoot 'broken'; $lmrClean = Join-Path $lmrRoot 'clean'
$lmrNoXaml = Join-Path $lmrRoot 'web';    $lmrUnparse = Join-Path $lmrRoot 'unparse'
foreach ($d in @($lmrBroken, $lmrClean, $lmrNoXaml, $lmrUnparse)) { New-Item -ItemType Directory -Force $d | Out-Null }
$lmrNs = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
# A Grid with 2 rows and a child at Grid.Row=5 -> the grid-index-out-of-range HIGH rule.
Set-Content -Encoding UTF8 -Path (Join-Path $lmrBroken 'MainWindow.xaml') -Value @"
<Window $lmrNs>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
    <TextBlock x:Name="Display" Grid.Row="0" Text="0" />
    <Button x:Name="Keypad" Grid.Row="5" Content="7" />
  </Grid>
</Window>
"@
Set-Content -Encoding UTF8 -Path (Join-Path $lmrClean 'MainWindow.xaml') -Value @"
<Window $lmrNs>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
    <TextBlock x:Name="Display" Grid.Row="0" Text="0" />
    <Button x:Name="Keypad" Grid.Row="1" Content="7" />
  </Grid>
</Window>
"@
Set-Content -Encoding UTF8 -Path (Join-Path $lmrNoXaml 'index.html') -Value '<!doctype html><html><body>hi</body></html>'
Set-Content -Encoding UTF8 -Path (Join-Path $lmrUnparse 'MainWindow.xaml') -Value '<Window><Grid>'

$lmrOn = Invoke-LayoutLint -AppDir $lmrBroken -BlarAiRepo $lmrRepo
if ($lmrOn.Measured) {
    # ---- the control ON: the real module, the real defect, a real verdict --------------------------
    Assert-Eq 'findings' $lmrOn.Status "LMR1 [kill] the REAL lint FIRES on a real geometry defect (status findings)"
    Assert-True ([bool]$lmrOn.Hard) 'LMR1 and reports it hard'
    Assert-Contains ($lmrOn.Messages -join ' | ') 'Grid.Row=5' 'LMR1 the real finding is carried verbatim'
    Assert-Eq 1 $lmrOn.FilesScanned 'LMR1 and the file count is real'

    $lmrClean1 = Invoke-LayoutLint -AppDir $lmrClean -BlarAiRepo $lmrRepo
    Assert-True ([bool]$lmrClean1.Measured) 'LMR2 a sound layout is MEASURED...'
    Assert-Eq 'clean' $lmrClean1.Status    'LMR2 [kill] ...and reads clean -- so clean and unmeasured are now distinguishable in the same run'
    Assert-Eq '' (Format-DesignLintCaveat -Lint 'layout' -Measured $lmrClean1.Measured -Unparsed $lmrClean1.Unparsed) `
        'LMR2 a genuinely clean lint prints no caveat (no crying wolf)'

    # The node-web / web surfaces the ticket names: zero XAML is NOT a clean layout, it is no layout.
    $lmrWeb = Invoke-LayoutLint -AppDir $lmrNoXaml -BlarAiRepo $lmrRepo
    Assert-False ([bool]$lmrWeb.Measured) 'LMR3 [kill] zero .xaml files -> UNMEASURED, not clean (the node-web/web surface case)'
    Assert-Eq 'not-applicable' $lmrWeb.Status 'LMR3 and it is not-applicable, distinguishable from a broken tool'
    Assert-Eq 0 $lmrWeb.FilesScanned 'LMR3 the real count is zero'

    # An input the module could not read: LOW severity, so it never reaches Hard or the HIGH filter.
    $lmrUnp = Invoke-LayoutLint -AppDir $lmrUnparse -BlarAiRepo $lmrRepo
    Assert-False ([bool]$lmrUnp.Measured) 'LMR4 [kill] a XAML file that will not parse -> UNMEASURED (it was scanned, never examined)'
    Assert-Contains $lmrUnp.Detail 'failed to read or parse' 'LMR4 and the cause is named'

    # ---- the TOGGLE OFF: same tree, same call, tool removed -> the probe must FAIL ------------------
    $lmrOff = Invoke-LayoutLint -AppDir $lmrBroken -BlarAiRepo (Join-Path $scratch 'no-such-blarai-root')
    Assert-False ([bool]$lmrOff.Measured) 'LMR5 [kill] TOGGLE: with the tool removed the SAME tree is UNMEASURED...'
    Assert-Eq 'unavailable' $lmrOff.Status 'LMR5 ...and unavailable, not clean'
    Assert-False ([bool]$lmrOff.Hard) 'LMR5 the real hard finding is GONE -- proving LMR1 measured something rather than asserting it'
    Assert-Eq 0 @($lmrOff.Messages).Count 'LMR5 and carries no findings'
} else {
    # shared/fleet/layout_lint.py is not reachable from this checkout. That is not a skip: it IS the
    # degraded path, and the property that matters is asserted HERE instead, so this section has teeth in
    # both environments and goes quiet in neither.
    Write-Host "  NOTE: shared/fleet/layout_lint.py is not runnable from $lmrRepo -- asserting the DEGRADED contract instead." -ForegroundColor Yellow
    Assert-False ([bool]$lmrOn.Measured) 'LMR1-alt [kill] an unreachable module -> Measured=$false, NEVER a clean layout'
    Assert-Eq 'unavailable' $lmrOn.Status 'LMR2-alt status is unavailable'
    Assert-True ([bool]$lmrOn.Detail) 'LMR3-alt [kill] and python own last words are carried, so the operator can see WHY'
    Assert-Contains (Format-DesignLintCaveat -Lint 'layout' -Measured $lmrOn.Measured -Detail $lmrOn.Detail -Status $lmrOn.Status) `
        'UNEXAMINED' 'LMR4-alt and the caveat says the layout is unexamined'
}

# =============================================================================
Section 'LMB* -- #1198: the tool is PRESENT but BROKEN (the degraded paths that actually ship)'
# "The tool is missing" is the EASY degraded path. The ones that ship broken are the tool that runs and
# returns garbage, exits non-zero, or writes bytes the parser rejects -- a sibling verification on
# 2026-07-30 found a live PowerShell/Python divergence caused by nothing but a UTF-8 BOM, invisible to a
# test whose fixture came from `Set-Content -Encoding UTF8` (no BOM under pwsh 7, BOM under 5.1). So
# these drive the REAL Invoke-LayoutLint against a REAL python process running a CONTROLLED module, and
# demand the same answer from every shape of misbehaviour: UNMEASURED, never clean.
$lmbRoot = Join-Path $scratch 'fakerepo'
$realPy  = Join-Path $lmrRepo '.venv\Scripts\python.exe'
if (Test-Path $realPy) {
    New-Item -ItemType Directory -Force (Join-Path $lmbRoot '.venv\Scripts') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $lmbRoot 'shared\fleet') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $lmbRoot 'app') | Out-Null
    Copy-Item $realPy (Join-Path $lmbRoot '.venv\Scripts\python.exe') -Force
    $realCfg = Join-Path $lmrRepo '.venv\pyvenv.cfg'
    if (Test-Path $realCfg) { Copy-Item $realCfg (Join-Path $lmbRoot '.venv\pyvenv.cfg') -Force }
    Set-Content -Encoding UTF8 -Path (Join-Path $lmbRoot 'shared\__init__.py') -Value ''
    Set-Content -Encoding UTF8 -Path (Join-Path $lmbRoot 'shared\fleet\__init__.py') -Value ''
    # A stand-in for the real module whose MISBEHAVIOUR is selected by an env var. Written through an
    # explicit no-BOM encoder, so this fixture's own encoding cannot silently become the thing under test.
    $lmbMod = @'
import os, sys, json
mode = os.environ.get("FAKE_LINT_MODE", "ok")
payload = {"findings": [{"rule": "grid-index-out-of-range", "severity": "high",
                         "message": "A REAL HARD FINDING", "element": "X", "file": "MainWindow.xaml"}],
           "hard": True, "files_scanned": 1}
if mode == "ok":
    print(json.dumps(payload))
elif mode == "garbage":
    print("Traceback (most recent call last):")
    print("  ValueError: everything is fine actually")
elif mode == "exit1-with-json":
    print(json.dumps(payload)); sys.exit(1)
elif mode == "exit2-no-json":
    sys.stderr.write("ERROR: bad usage\n"); sys.exit(2)
elif mode == "bom":
    sys.stdout.buffer.write(b"\xef\xbb\xbf" + json.dumps(payload).encode("utf-8") + b"\n")
elif mode == "utf16":
    sys.stdout.buffer.write(json.dumps(payload).encode("utf-16"))
elif mode == "empty":
    pass
'@
    [System.IO.File]::WriteAllText((Join-Path $lmbRoot 'shared\fleet\layout_lint.py'), $lmbMod,
        (New-Object System.Text.UTF8Encoding($false)))
    $lmbApp = Join-Path $lmbRoot 'app'
    $lmbPrev = $env:FAKE_LINT_MODE
    try {
        # LMB0: the fixture is REAL -- if the control cannot fire here, nothing below it has teeth.
        $env:FAKE_LINT_MODE = 'ok'
        $b = Invoke-LayoutLint -AppDir $lmbApp -BlarAiRepo $lmbRoot
        Assert-True ([bool]$b.Measured) 'LMB0 [kill] the controlled tool RUNS and is measured (a real process, not a stub)'
        Assert-Eq 'findings' $b.Status  'LMB0 and its hard finding is read'

        # Each of these is a tool that RAN. None may report a clean layout.
        foreach ($case in @(
            @{ Mode = 'garbage';       Msg = 'returns a traceback instead of JSON' }
            @{ Mode = 'exit2-no-json'; Msg = 'exits non-zero with no JSON' }
            @{ Mode = 'bom';           Msg = 'emits a UTF-8 BOM before its JSON (the sibling divergence)' }
            @{ Mode = 'utf16';         Msg = 'emits UTF-16 the parser cannot read' }
            @{ Mode = 'empty';         Msg = 'prints nothing at all' })) {
            $env:FAKE_LINT_MODE = $case.Mode
            $b = Invoke-LayoutLint -AppDir $lmbApp -BlarAiRepo $lmbRoot
            Assert-False ([bool]$b.Measured) "LMB [kill] a tool that $($case.Msg) -> UNMEASURED, never clean"
            Assert-Eq 'unavailable' $b.Status "LMB and its status is unavailable ($($case.Mode))"
            Assert-False ([bool]$b.Hard) "LMB and it forces nothing ($($case.Mode))"
            Assert-True ((Format-DesignLintCaveat -Lint 'layout' -Measured $b.Measured -Detail $b.Detail -Status $b.Status) -ne '') `
                "LMB and the operator gets a caveat ($($case.Mode))"
        }

        # LMB6: the ONE case that is deliberately measured. The verdict is the JSON on stdout, never the
        # exit code -- the same rule verify-coder-test-qa.ps1 X1 locks for the coder-QA scanner, whose
        # module exits 0 by design. A lint that PRINTED its verdict and then died still delivered one.
        $env:FAKE_LINT_MODE = 'exit1-with-json'
        $b = Invoke-LayoutLint -AppDir $lmbApp -BlarAiRepo $lmbRoot
        Assert-True ([bool]$b.Measured) 'LMB6 a tool that printed valid JSON and THEN exited non-zero is measured (the verdict is the JSON, never the exit code)'
        Assert-True ([bool]$b.Hard) 'LMB6 [kill] and its real finding is NOT discarded on the strength of an exit code'
    } finally {
        if ($null -eq $lmbPrev) { Remove-Item Env:\FAKE_LINT_MODE -ErrorAction SilentlyContinue }
        else { $env:FAKE_LINT_MODE = $lmbPrev }
    }
} else {
    Write-Host "  NOTE: no interpreter at $realPy -- the present-but-broken cases cannot be driven; asserting the absent-tool contract instead." -ForegroundColor Yellow
    $b = Invoke-LayoutLint -AppDir $fakeAppDir -BlarAiRepo $lmbRoot
    Assert-False ([bool]$b.Measured) 'LMB0-alt [kill] with no interpreter the lint is UNMEASURED, never clean'
}

# =============================================================================
Section 'VS* -- #1198: the REPORT the operator reads (Format-VisualCritiqueSummary, pure)'
# The ticket's own observable lives here: with the layout tool removed from PATH, the design-critique
# report must say the lint could not run, and the deliverable must not read as having a clean layout.
# The wording is a function precisely so that sentence is provable rather than merely present.

$vsClean = @{ CaptureTier = '1'; Ok = $true; NeedsWork = $false; Feedback = 'All criteria met.'
              LintsMeasured = $true; CaveatText = '' }
$vs = Format-VisualCritiqueSummary -Result $vsClean
Assert-Contains $vs 'visual criteria look satisfied' 'VS1 a fully-measured clean pass still reads as clean (no crying wolf)'

# VS0 [kill]: FIXTURE REALISM. On 2026-07-30 a sibling suite ran 1416 green over a live defect because
# its fixtures built a shape the production parser forbids. The hand-built results below are read by the
# REAL formatter, so every key they use must be a key the REAL producer actually emits -- otherwise these
# tests describe a result shape that cannot occur and prove nothing about the one that does.
$vsRealKeys = @((Invoke-CritiquePass -AppDir $fakeAppDir -Goal 'g' -VisualCriteriaJson '[]' `
    -BlarAiRepo (Join-Path $scratch 'no-such-blarai-root') -Iteration 0 -MaxIter 3 `
    -WorkDir (Join-Path $scratch 'vs0')).Keys)
foreach ($k in @('CaptureTier', 'Ok', 'NeedsWork', 'Feedback', 'LintsMeasured', 'CaveatText')) {
    Assert-True ($vsRealKeys -contains $k) "VS0 [kill] the fixtures' '$k' is a field Invoke-CritiquePass really emits (fixture realism, not a shape we invented)"
}

# VS2 is THE case. Same VLM verdict, same everything -- only the layout lint is missing.
$vsAbsentMerge = Merge-DesignSignals -LayoutHard $false -LayoutMeasured $false -LayoutStatus 'unavailable' `
    -LayoutDetail 'no BlarAI python interpreter at C:\nope\.venv\Scripts\python.exe' `
    -VlmOk $true -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback 'All criteria met.' -Iteration 0 -MaxIter 3
$vsAbsent = @{ CaptureTier = '1'; Ok = $true; NeedsWork = $false; Feedback = $vsAbsentMerge.Feedback
               LintsMeasured = $vsAbsentMerge.LintsMeasured; CaveatText = $vsAbsentMerge.CaveatText }
$vs = Format-VisualCritiqueSummary -Result $vsAbsent
Assert-True (-not ($vs -match 'visual criteria look satisfied')) 'VS2 [kill] THE OBSERVABLE: with the layout lint absent the report does NOT say the criteria look satisfied'
Assert-Contains $vs 'PARTIAL examination'       'VS2 [kill] it calls the examination partial'
Assert-Contains $vs 'has NOT been checked clean' 'VS2 [kill] and refuses the clean bill in words'
Assert-Contains $vs 'DID NOT RUN'                'VS2 and says the lint did not run'
Assert-Contains $vs 'python'                     'VS2 [kill] naming the cause, so the operator can fix the box'

# VS3: the caveat survives the OTHER branches too -- a needs-work report is still a partial one.
$vsNeeds = @{ CaptureTier = '1'; Ok = $true; NeedsWork = $true; Feedback = 'Buttons too small.'
              LintsMeasured = $false; CaveatText = 'DESIGN LINT: the XAML layout lint DID NOT RUN - gone.' }
$vs = Format-VisualCritiqueSummary -Result $vsNeeds -FixCount 2
Assert-Contains $vs 'Buttons too small' 'VS3 the VLM feedback is still carried'
Assert-Contains $vs 'DID NOT RUN'       'VS3 [kill] and the caveat rides the needs-work branch too'
Assert-Contains $vs '2 auto-fix'        'VS3 the fix count is preserved'

# VS4: and the structural floor + the fail-soft branch.
$vsStruct = @{ CaptureTier = 'structural'; Ok = $false; NeedsWork = $false; Feedback = 'Structural notes: x'
               LintsMeasured = $false; CaveatText = 'DESIGN LINT: the rendered-pixel lint had NOTHING TO EXAMINE - no screenshot.' }
$vs = Format-VisualCritiqueSummary -Result $vsStruct
Assert-Contains $vs 'structural floor' 'VS4 the structural-floor wording is preserved'
Assert-Contains $vs 'NOTHING TO EXAMINE' 'VS4 [kill] and the caveat rides it'
$vsFail = @{ CaptureTier = '1'; Ok = $false; NeedsWork = $false; Feedback = 'Capture failed: boom'
             LintsMeasured = $false; CaveatText = 'DESIGN LINT: the XAML layout lint DID NOT RUN - gone.' }
$vs = Format-VisualCritiqueSummary -Result $vsFail
Assert-Contains $vs 'unavailable / failed' 'VS5 the fail-soft wording is preserved'
Assert-Contains $vs 'DID NOT RUN'          'VS5 [kill] and the caveat rides it'

# VS6: a null result keeps its prior no-op wording (nothing to caveat, nothing to invent).
Assert-Contains (Format-VisualCritiqueSummary -Result $null) 'returned no result' 'VS6 a null result is unchanged'
# VS7: fix notes are carried (the pre-#1198 behavior this extraction must not have dropped).
Assert-Contains (Format-VisualCritiqueSummary -Result $vsClean -FixNotes @('FIX #1: applied')) 'FIX #1: applied' `
    'VS7 [kill] the fix notes still reach the report'
# VS8 [kill]: a measured PARTIAL lint (files skipped) also withholds the clean bill.
$vsPartial = @{ CaptureTier = '1'; Ok = $true; NeedsWork = $false; Feedback = 'ok'
                LintsMeasured = $true; CaveatText = 'DESIGN LINT: the XAML layout lint SKIPPED 1 file(s) it could not read or parse (X.xaml).' }
$vs = Format-VisualCritiqueSummary -Result $vsPartial
Assert-True (-not ($vs -match 'visual criteria look satisfied')) 'VS8 [kill] a lint that skipped files it could not parse also withholds the clean bill'
Assert-Contains $vs 'SKIPPED 1 file' 'VS8 and discloses what was skipped'

# =============================================================================
Section 'PE* -- #1198: the REAL Invoke-CritiquePass carries the absence to its caller'
# Reachability, not behavior-in-a-mock: the real entry point, on a box where the interpreter is absent.
$peWork = Join-Path $scratch 'pe'
$pe = Invoke-CritiquePass -AppDir $fakeAppDir -Goal 'g' -VisualCriteriaJson '[]' `
    -BlarAiRepo (Join-Path $scratch 'no-such-blarai-root') -Iteration 0 -MaxIter 3 -WorkDir $peWork
Assert-False ([bool]$pe.LintsMeasured) 'PE1 [kill] the REAL pass reports LintsMeasured=$false when the tools are absent'
Assert-Contains $pe.CaveatText 'UNEXAMINED' 'PE1 [kill] and carries the caveat text to its caller'
Assert-False $pe.ShouldIterate 'PE1 while still never forcing a FIX lap on an absent measurement'
Assert-True (-not ((Format-VisualCritiqueSummary -Result $pe) -match 'visual criteria look satisfied')) `
    'PE2 [kill] end to end: the report rendered from a REAL degraded pass never reads as a clean bill'

# =============================================================================
Section 'LW* -- source wiring: the real loop runs the layout gate + threads its findings'
$clp = Get-Content "$ScriptDir\critique-loop.ps1" -Raw
# LW1: Invoke-CritiquePass actually runs the deterministic layout gate.
Assert-True ([regex]::IsMatch($clp, 'Invoke-LayoutLint -AppDir \$AppDir -BlarAiRepo \$BlarAiRepo')) `
    'LW1 [kill] Invoke-CritiquePass runs the deterministic layout gate (Invoke-LayoutLint)'
# LW2: the VLM critique CLI receives the COMBINED deterministic findings (layout + pixel feed Lever C).
Assert-True ([regex]::IsMatch($clp, '--layout-findings-json \$detMessagesJson')) `
    'LW2 [kill] the critique CLI receives the combined deterministic findings (--layout-findings-json $detMessagesJson)'
# LW2b: that combined feed is layout messages + pixel messages (neither lever is dropped from the VLM prompt).
Assert-True ([regex]::IsMatch($clp, '\$detMessages = @\(\$layoutResult\.Messages\) \+ @\(\$pixelResult\.Messages\)')) `
    'LW2b [kill] the deterministic feed COMBINES layout + pixel messages'
# LW3: BOTH result branches combine via Merge-DesignSignals (the gate cannot be bypassed).
Assert-Eq 2 ([regex]::Matches($clp, 'Merge-DesignSignals -LayoutHard \$layoutResult\.Hard').Count) `
    'LW3 [kill] both the structural-floor and VLM-success branches combine via Merge-DesignSignals'
# LW4: the gate invokes the BlarAI layout_lint python module.
Assert-True ([regex]::IsMatch($clp, 'shared\.fleet\.layout_lint')) `
    'LW4 the loop invokes the shared.fleet.layout_lint module'
# LW5: Invoke-CritiquePass ALSO runs the deterministic PIXEL gate on the captured PNG (Lever B).
Assert-True ([regex]::IsMatch($clp, 'Invoke-PixelLint -Png \$pngPath -BlarAiRepo \$BlarAiRepo')) `
    'LW5 [kill] Invoke-CritiquePass runs the deterministic pixel gate (Invoke-PixelLint) on the PNG'
# LW6: the pixel gate's HARD signal is threaded into the merge (it cannot be silently dropped).
Assert-True ([regex]::IsMatch($clp, '-PixelHard \$pixelResult\.Hard -PixelMessages \$pixelResult\.Messages')) `
    'LW6 [kill] the pixel gate hard signal is threaded into Merge-DesignSignals'
# LW7: the gate invokes the BlarAI pixel_lint python module.
Assert-True ([regex]::IsMatch($clp, 'shared\.fleet\.pixel_lint')) `
    'LW7 the loop invokes the shared.fleet.pixel_lint module'
# LW8 (#1198): BOTH merge sites thread the layout lint's MEASURED-ness. A site that drops it silently
# restores the defect for that branch, and nothing else in this suite would notice.
Assert-Eq 2 ([regex]::Matches($clp, '-LayoutMeasured \$layoutResult\.Measured').Count) `
    'LW8 [kill] both merge sites thread the layout lint measured flag (dropping it at either one restores the defect)'
# LW9: and the pixel lint's, on the branch where it ran.
Assert-True ([regex]::IsMatch($clp, '-PixelMeasured \$pixelResult\.Measured')) `
    'LW9 [kill] the pixel gate measured flag is threaded into Merge-DesignSignals'
# LW10: the caveat text reaches the RESULT, or it never reaches the operator.
Assert-Eq 2 ([regex]::Matches($clp, 'CaveatText\s*=\s*\$merged\.CaveatText').Count) `
    'LW10 [kill] both pass-result branches surface the caveat text (built-but-wired-into-nothing check)'
Assert-Eq 2 ([regex]::Matches($clp, 'LintsMeasured\s*=\s*\$merged\.LintsMeasured').Count) `
    'LW10b [kill] and both surface LintsMeasured, which is what the report gates its clean bill on'
# LW11: the files the lint could not parse are threaded too (a scanned file is not an examined one).
Assert-Eq 2 ([regex]::Matches($clp, '-LayoutUnparsed \$layoutResult\.Unparsed').Count) `
    'LW11 [kill] both merge sites thread the unparsed-file list'

# LW12 (#1198): the LIVE caller renders it. new-agent-task.ps1 is where the operator's report is built;
# a caveat that stops at the result object is a control wired into nothing.
$natSrc = Get-Content "$ScriptDir\new-agent-task.ps1" -Raw
Assert-True ([regex]::IsMatch($natSrc, '\$critiqueSummary = Format-VisualCritiqueSummary -Result \$loop\.FinalResult')) `
    'LW12 [kill] the live [6/6] hook builds its summary through Format-VisualCritiqueSummary (the tested wording)'
Assert-True ([regex]::IsMatch($natSrc, '-FixNotes @\(\$script:fixNotes\) -FixCount \$script:fixCount')) `
    'LW12b the auto-FIX notes and count still reach the report'
Assert-True (-not ([regex]::IsMatch($natSrc, '\$critiqueSummary = "VLM critique: visual criteria look satisfied'))) `
    'LW13 [kill] the untested inline clean-bill string is GONE from new-agent-task.ps1 (it could bypass the caveat)'
Assert-True ([regex]::IsMatch($natSrc, '(?m)^VISUAL CRITIQUE|VISUAL CRITIQUE \(post-merge design signal')) `
    'LW14 the summary is written into the TASK REPORT the operator reads'

# =============================================================================
# Cleanup
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
Section 'UA* -- Resolve-UnservedAssetFindings: make a 404 ACTIONABLE (#1133)'
# THE INCIDENT (2026-07-27, run 20260727-215338-bd): the capture caught a 404 on
# header/header.styles.css, set hard=true, and surfaced it to the fix loop TWICE --
# and the loop committed five more lines of CSS INTO that unreachable file. The
# signal was never missing; the WORDING invited "improve the resource" instead of
# "the resource is not served". These lock the enrichment that says so.

$uaApp = Join-Path $env:TEMP ("ua-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $uaApp 'public') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $uaApp 'header') -Force | Out-Null
Set-Content -Path (Join-Path $uaApp 'header\header.styles.css') -Value '/* outside public */' -Encoding UTF8
$ua404 = 'Uncaught exception: Failed to load resource: the server responded with a status of 404 (Not Found) (http://127.0.0.1:3814/header/header.styles.css)'
$ua500 = 'Uncaught exception: Failed to load resource: the server responded with a status of 500 (Server Error) (http://127.0.0.1:3814/nope/missing.js)'

# UA1 [kill]: the incident's exact shape -- file exists, but outside the served root.
$ua1 = @(Resolve-UnservedAssetFindings -Messages @($ua404) -AppDir $uaApp)
Assert-Contains $ua1[0] 'NOT under the served directory' 'UA1 names the real cause (not served), not "failed to load"'
Assert-Contains $ua1[0] 'CANNOT CHANGE THE PAGE'         'UA1 [kill] forbids the exact mistake the loop made: editing the unreachable file'
Assert-Contains $ua1[0] 'returned 404'                   'UA1 reports the real status code'

# UA2: a path that exists nowhere gets a DIFFERENT, also-true diagnosis.
$ua2 = @(Resolve-UnservedAssetFindings -Messages @($ua500) -AppDir $uaApp)
Assert-Contains $ua2[0] 'nothing exists at that path' 'UA2 distinguishes absent-entirely from present-but-unserved'
Assert-Contains $ua2[0] 'returned 500'                'UA2 does not hardcode 404'

# UA3 [kill]: with no readable worktree we CANNOT tell the two apart, so we must not
# claim either. Verbatim passthrough -- an invented diagnosis is worse than none.
$ua3 = @(Resolve-UnservedAssetFindings -Messages @($ua404) -AppDir '')
Assert-Eq $ua404 $ua3[0] 'UA3 [kill] no worktree -> verbatim; never asserts a fact it did not check'
$ua4 = @(Resolve-UnservedAssetFindings -Messages @($ua404) -AppDir 'C:\does\not\exist')
Assert-Eq $ua404 $ua4[0] 'UA4 unreadable worktree -> verbatim passthrough'

# UA5: non-asset findings and browser noise are untouched (no signal is lost or reworded).
$ua5 = @(Resolve-UnservedAssetFindings -Messages @('Rendered text contains "undefined"') -AppDir $uaApp)
Assert-Eq 'Rendered text contains "undefined"' $ua5[0] 'UA5 a non-asset finding passes through verbatim'
$uaFav = 'Uncaught exception: Failed to load resource: the server responded with a status of 404 (Not Found) (http://127.0.0.1:3814/favicon.ico)'
$ua6 = @(Resolve-UnservedAssetFindings -Messages @($uaFav) -AppDir $uaApp)
Assert-Eq $uaFav $ua6[0] 'UA6 a missing favicon is browser noise, not a coder defect'

# UA7: empty input is empty output (the loop calls this unconditionally).
Assert-Eq 0 (@(Resolve-UnservedAssetFindings -Messages @() -AppDir $uaApp)).Count 'UA7 empty in -> empty out'

Remove-Item $uaApp -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  CRITIQUE LOOP: NOT VALIDATED - see [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  CRITIQUE LOOP: VALIDATED. All contracts correct; fail-soft proven; loop bounded.' -ForegroundColor Green
    exit 0
}
