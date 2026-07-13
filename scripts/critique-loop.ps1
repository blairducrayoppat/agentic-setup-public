#requires -Version 5.1
<#
.SYNOPSIS
  VLM design-loop critique orchestration for the UC-010 headless-coding dispatch (Phase 3).
  Runs ONE critique pass (capture -> VLM critique -> structured result) and provides a
  thin loop driver that iterates: critique -> rebuild callback -> repeat until done or capped.

.DESCRIPTION
  Two exported surfaces:

    Invoke-CritiquePass  -- ONE pass: capture screenshot + run VLM critique + return result.
    Invoke-CritiqueLoop  -- Loop driver: iterate passes with an injected rebuild callback.

  Both are fail-soft: any failure (capture error, missing python, non-JSON stdout, crash)
  produces a result with ShouldIterate=$false. The loop never hangs or errors out. This
  mirrors the BlarAI-side fail-soft contract in shared/fleet/critique.py.

  The VLM critique is a LOOP SIGNAL only -- it drives whether the coder does another FIX
  iteration. It is NEVER the acceptance verdict. Visual criteria always retain STATUS_EYEBALL
  on the BlarAI acceptance layer (shared/fleet/acceptance.py :: criterion_status).

  -------------------------------------------------------------------------------
  MEMORY NOTE: VLM + 30B co-residency (document, not implement)
  -------------------------------------------------------------------------------
  During a real dispatch the 14B is swapped OUT and the 30B Qwen3 (~18 GB) is resident.
  The VLM (Qwen3-VL, ~5 GB) loads on demand for each critique pass and CO-RESIDES with
  the 30B: ~23 GB peak, which is BELOW the 31.323 GB Lunar Lake ceiling. NO model swap
  is needed before calling the VLM critique -- the 30B can stay loaded. After each pass
  the BlarAI-side vlm.unload() call frees the VLM weights so GPU memory returns to the
  30B-only baseline (~18 GB). The hires image generation path (ADR-033 Am.2) is the only
  path that swaps the 14B; the critique path does not touch OVMS stop/swap -- that is
  out of scope and gated by a separate LA decision.

  -------------------------------------------------------------------------------
  Integration hook (where new-agent-task.ps1 calls this -- documented, NOT wired)
  -------------------------------------------------------------------------------
  Insert AFTER the [5/5] MERGE step, gated on the task having visual criteria:

      # [6/6] VLM design critique (only when the task has visual criteria)
      if ($VisualCriteriaJson -and $VisualCriteriaJson -ne '[]') {
          $critiqueResult = Invoke-CritiquePass `
              -AppDir $wt `
              -Goal $OrigPrompt `
              -VisualCriteriaJson $VisualCriteriaJson `
              -BlarAiRepo 'C:\Users\mrbla\blarai' `
              -Iteration 0 `
              -MaxIter 3 `
              -WorkDir (Join-Path $ReportDir 'critique')
          # surface $critiqueResult.Feedback to the coder if ShouldIterate
      }

  HOW VISUAL CRITERIA REACH THE FLEET (remaining plumbing -- not implemented here):
  The acceptance spec's visual criteria live in BlarAI as AcceptanceCriterion objects
  with tier=="visual" (shared/fleet/acceptance.py). The BlarAI-side dispatch coordinator
  (services/assistant_orchestrator, the AO's fleet dispatch tool handler) must:
    1. Filter spec.criteria for tier=="visual" -> extract their .text strings.
    2. json.dumps() them into a JSON array.
    3. Thread that JSON string into the queue task object (a new "visual_criteria_json" field).
    4. The fleet runner (new-agent-task.ps1) reads $t.visual_criteria_json and passes it
       to this script as -VisualCriteriaJson.
  Until that BlarAI-side wiring is provided, new-agent-task.ps1 does NOT call this script
  (do NOT edit new-agent-task.ps1 to call it yet -- the criteria will not be present).

.PARAMETER AppDir
  The built app worktree root. Passed directly to capture-app.ps1.

.PARAMETER Goal
  Plain-English product goal for the VLM critique prompt.

.PARAMETER VisualCriteriaJson
  JSON array of visual criterion text strings, e.g. '["A sidebar is visible","Button labels are readable"]'.
  Use '[]' for no explicit criteria (the VLM will assess general usability).

.PARAMETER BlarAiRepo
  Path to the BlarAI repository root (C:\Users\mrbla\blarai). The critique CLI runs as
  "<BlarAiRepo>\.venv\Scripts\python.exe -m shared.fleet.critique" from BlarAiRepo as cwd.

.PARAMETER Iteration
  0-based index of the iteration just completed. Passed to --iteration in the critique CLI
  so the BlarAI-side should_iterate() logic applies the iteration budget correctly.

.PARAMETER MaxIter
  Hard cap on total FIX iterations (default 3). Passed to --max-iter in the critique CLI.

.PARAMETER WorkDir
  Scratch directory for the critique PNG file. Created if absent.

.OUTPUTS
  Hashtable:
    ShouldIterate  [bool]   True iff the loop should do another FIX pass.
    NeedsWork      [bool]   True iff the VLM found visual issues.
    Feedback       [string] Actionable feedback to hand the coder on the next iteration.
    CaptureTier    [string] "1", "2", or "structural" (which capture tier fired).
    Ok             [bool]   False on any fail-soft error; True on a successful VLM critique.
    ScreenshotPath [string] Path to the PNG used, or '' on structural/fail.
#>
param(
    [Parameter(Mandatory)][string]$AppDir,
    [Parameter(Mandatory)][string]$Goal,
    [Parameter(Mandatory)][string]$VisualCriteriaJson,
    [Parameter(Mandatory)][string]$BlarAiRepo,
    [int]$Iteration = 0,
    [int]$MaxIter = 3,
    [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function _FailResult([string]$Feedback, [string]$CaptureTier = '') {
    return @{
        ShouldIterate  = $false
        NeedsWork      = $false
        Feedback       = $Feedback
        CaptureTier    = $CaptureTier
        Ok             = $false
        ScreenshotPath = ''
    }
}

function Merge-DesignSignals {
    <#
    .SYNOPSIS
      PURE combine of the deterministic layout gate (Lever A) with the VLM critique
      (Lever C) into the loop's final design signal.

      The layout gate is a HARD signal: a HIGH-severity geometry defect forces another FIX
      iteration EVEN IF the VLM passed -- the fix for "the VLM false-passes broken layouts".
      The VLM stays a soft signal. Feedback LEADS with the deterministic findings (the coder
      fixes those first) then appends the VLM's notes. Pure + injectable so the core rule is
      unit-tested mutation-resistantly (see verify-critique-loop.ps1).

      Returns @{ ShouldIterate=[bool]; NeedsWork=[bool]; Feedback=[string]; LayoutHard=[bool] }.
    #>
    param(
        [bool]$LayoutHard = $false,
        [string[]]$LayoutMessages = @(),
        [bool]$PixelHard = $false,
        [string[]]$PixelMessages = @(),
        [bool]$RuntimeHard = $false,
        [string[]]$RuntimeMessages = @(),
        [bool]$VlmOk = $false,
        [bool]$VlmNeedsWork = $false,
        [bool]$VlmShouldIterate = $false,
        [string]$VlmFeedback = '',
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][int]$MaxIter
    )
    # A hard DETERMINISTIC finding -- XAML layout (Lever A), rendered-pixel (Lever B), OR a browser
    # RUNTIME error (#823 Lever D: a console error / uncaught exception / undefined-in-text / declared-
    # behavior failure) -- forces another pass while the iteration budget remains, EVEN IF the VLM
    # passed. The VLM is never the sole gate (the false-pass fix). Pixel*/Runtime* default inert so
    # pre-pixel / pre-runtime callers are byte-identical.
    $detHard       = [bool]($LayoutHard -or $PixelHard -or $RuntimeHard)
    $detIterate    = $detHard -and ($Iteration -lt $MaxIter)
    $shouldIterate = [bool]($VlmShouldIterate -or $detIterate)
    $needsWork     = [bool]($VlmNeedsWork -or $detHard)

    $parts = New-Object System.Collections.ArrayList
    # RUNTIME errors LEAD the feedback (#823 item 2: ranked ABOVE cosmetic critique -- fix the thrown
    # error before the layout). A runtime finding carries the message VERBATIM (file/line/message).
    if ($RuntimeHard -and $RuntimeMessages -and $RuntimeMessages.Count -gt 0) {
        [void]$parts.Add("Runtime errors (browser console / uncaught exceptions) -- fix these FIRST, before any layout or styling:")
        foreach ($m in $RuntimeMessages) { [void]$parts.Add("  - $m") }
    }
    if ($LayoutHard -and $LayoutMessages -and $LayoutMessages.Count -gt 0) {
        [void]$parts.Add("Deterministic layout issues (fix these FIRST):")
        foreach ($m in $LayoutMessages) { [void]$parts.Add("  - $m") }
    }
    if ($PixelHard -and $PixelMessages -and $PixelMessages.Count -gt 0) {
        [void]$parts.Add("Deterministic visual (rendered-pixel) issues:")
        foreach ($m in $PixelMessages) { [void]$parts.Add("  - $m") }
    }
    if ($VlmFeedback) { [void]$parts.Add($VlmFeedback) }
    $feedback = ($parts -join "`n").Trim()

    # LayoutHard in the return means "any deterministic hard finding" so the Python _design_note
    # (which reads layout_hard) reports deterministic issues for pixel/runtime hits too. For a
    # pre-pixel/pre-runtime caller Pixel/RuntimeHard=$false, so $detHard == $LayoutHard and the return
    # is byte-identical. RuntimeHard is ALSO returned distinctly so the Python side can word the
    # operator note as a runtime error (not "layout") and gate the clean-ending reclass on it.
    return @{ ShouldIterate = $shouldIterate; NeedsWork = $needsWork; Feedback = $feedback; LayoutHard = $detHard; RuntimeHard = [bool]$RuntimeHard }
}

function Invoke-LayoutLint {
    <#
    .SYNOPSIS
      Run the deterministic XAML layout gate (shared/fleet/layout_lint.py) over an app dir.
      Fail-soft: ANY failure (no python, no JSON, crash) -> @{ Hard=$false; Messages=@();
      MessagesJson='[]' } so the design loop degrades to the VLM-only signal, never errors.
      Returns @{ Hard=[bool]; Messages=[string[]]; MessagesJson=[string] }.
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$BlarAiRepo
    )
    $empty = @{ Hard = $false; Messages = @(); MessagesJson = '[]' }
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) { return $empty }
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $BlarAiRepo
            $lines = @(& $pythonExe -m shared.fleet.layout_lint --app-dir $AppDir 2>&1)
        } finally { Set-Location $prevLoc }
    } catch { return $empty }
    $jsonLine = ($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) { return $empty }
    try { $obj = $jsonLine | ConvertFrom-Json } catch { return $empty }
    $hard = [bool]($obj.hard)
    $msgs = @($obj.findings | Where-Object { $_.severity -eq 'high' } | ForEach-Object { [string]$_.message })
    $msgsJson = '[' + (($msgs | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ']'
    return @{ Hard = $hard; Messages = $msgs; MessagesJson = $msgsJson }
}

function Invoke-PixelLint {
    <#
    .SYNOPSIS
      Run the deterministic PIXEL gate (shared/fleet/pixel_lint.py) over a captured screenshot --
      reference-free colour-presence + element-geometry, the count/colour/position axes the VLM
      hallucinates on. The complement to Invoke-LayoutLint (XAML), needing a real PNG.
      Fail-soft: ANY failure (no python, missing PNG, no JSON, crash) -> @{ Hard=$false; Messages=@();
      MessagesJson='[]' } so the design loop degrades to the layout+VLM signal, never errors.
      Returns @{ Hard=[bool]; Messages=[string[]]; MessagesJson=[string] } -- same shape as
      Invoke-LayoutLint so the caller composes both identically.
    #>
    param(
        [Parameter(Mandatory)][string]$Png,
        [Parameter(Mandatory)][string]$BlarAiRepo,
        [string]$CriteriaJson = '[]',
        [string]$Goal = ''
    )
    $empty = @{ Hard = $false; Messages = @(); MessagesJson = '[]' }
    if (-not (Test-Path $Png)) { return $empty }
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) { return $empty }
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $BlarAiRepo
            $lines = @(& $pythonExe -m shared.fleet.pixel_lint --screenshot $Png `
                --criteria-json $CriteriaJson --goal $Goal 2>&1)
        } finally { Set-Location $prevLoc }
    } catch { return $empty }
    $jsonLine = ($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) { return $empty }
    try { $obj = $jsonLine | ConvertFrom-Json } catch { return $empty }
    $hard = [bool]($obj.hard)
    # pixel_lint emits only HIGH findings, but filter for parity with Invoke-LayoutLint.
    $msgs = @($obj.findings | Where-Object { $_.severity -eq 'high' } | ForEach-Object { [string]$_.message })
    $msgsJson = '[' + (($msgs | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ']'
    return @{ Hard = $hard; Messages = $msgs; MessagesJson = $msgsJson }
}

function Read-ConsoleSidecar {
    <#
    .SYNOPSIS
      Read the browser-console sidecar ("<png>.console.json") that capture-web-cdp.mjs (#823 H8/H9)
      writes beside a WEB capture (the protocol-level (CDP) console + uncaught-exception stream and
      the positive behavior smoke. Returns the design loop's RUNTIME-error signal (Lever D).

      Fail-soft + HONEST (the ok-flag discipline -- a degraded env must never fake a richer verdict):
        * a MISSING sidecar (a WinUI tier-1/2 capture, the structural floor, or an old capture), OR
        * a captured:false sidecar (the msedge --screenshot fallback ran -> console UNAVAILABLE)
      both yield @{ Captured=$false; Hard=$false; Messages=@() } -- NO runtime signal, so the loop
      degrades to today's pixel-only behavior. Only a captured:true sidecar contributes a signal, and
      its ``hard`` verdict (a console/exception error, an undefined/NaN text leak, or a DECLARED-
      behavior failure -- computed authoritatively by the Node helper) forces another FIX iteration.
      Returns @{ Captured=[bool]; Hard=[bool]; Messages=[string[]] }.
    #>
    param([Parameter(Mandatory)][string]$SidecarPath)
    $empty = @{ Captured = $false; Hard = $false; Messages = @() }
    if (-not (Test-Path $SidecarPath)) { return $empty }
    try { $obj = Get-Content $SidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $empty }
    if (-not $obj -or -not $obj.captured) { return $empty }
    $msgs = @()
    if ($obj.findings) { $msgs = @($obj.findings | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    return @{ Captured = $true; Hard = [bool]$obj.hard; Messages = $msgs }
}

# ---------------------------------------------------------------------------
# Invoke-CritiquePass : ONE capture + critique pass
# ---------------------------------------------------------------------------
function Invoke-CritiquePass {
    <#
    .SYNOPSIS
      Runs one capture+critique pass. Returns a structured result hashtable.
      Fail-soft everywhere: never throws, never hangs; ShouldIterate=$false on any failure.
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$VisualCriteriaJson,
        [Parameter(Mandatory)][string]$BlarAiRepo,
        [int]$Iteration = 0,
        [int]$MaxIter = 3,
        [string]$WorkDir = ''
    )

    # Resolve / create the scratch directory for the PNG.
    if (-not $WorkDir) { $WorkDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "critique-loop-$([guid]::NewGuid().ToString('N').Substring(0,8))") }
    try { if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force $WorkDir | Out-Null } }
    catch { return _FailResult "Could not create WorkDir '$WorkDir': $($_.Exception.Message)" }

    $pngPath = Join-Path $WorkDir "critique-$Iteration.png"

    # ---- Step 0: deterministic layout gate (Lever A) --------------------
    # Runs on the source XAML -- no screenshot needed -- so it fires even on the structural
    # floor and OVERRIDES a VLM false-pass on a broken grid. Fail-soft (no python -> empty).
    $layoutResult = Invoke-LayoutLint -AppDir $AppDir -BlarAiRepo $BlarAiRepo

    # ---- Step 1: capture ------------------------------------------------
    $captureScript = Join-Path $ScriptDir 'capture-app.ps1'
    if (-not (Test-Path $captureScript)) {
        return _FailResult "capture-app.ps1 not found at '$captureScript'"
    }

    $captureLines = $null
    $captureExit = 0
    try {
        $captureLines = @(& $captureScript -AppDir $AppDir -OutPng $pngPath 2>&1)
        $captureExit = $LASTEXITCODE
    } catch {
        return _FailResult "capture-app.ps1 threw: $($_.Exception.Message)"
    }

    # Extract the machine-readable result line from stdout (Write-Output lines only;
    # capture-app.ps1 uses Write-Host for console colour and Write-Output for the
    # parseable signal, but 2>&1 merges them -- find by prefix).
    $captureSignal = ($captureLines | Where-Object { $_ -match '^(CAPTURE-OK:|STRUCTURAL_ONLY|CAPTURE-FAIL:)' } | Select-Object -Last 1) ?? ''

    # ---- Step 2: STRUCTURAL_ONLY floor ----------------------------------
    if ($captureSignal -match '^STRUCTURAL_ONLY') {
        # No pixels for the VLM, but the deterministic layout gate ALREADY ran on the source
        # XAML -- so a hard geometry defect STILL forces a FIX even on the structural floor.
        $structJson = "$pngPath.json"
        $notes = ''
        if (Test-Path $structJson) {
            try {
                $obj = Get-Content $structJson -Raw -Encoding UTF8 | ConvertFrom-Json
                $notes = $obj.notes ?? ''
            } catch { $notes = "Structural JSON unreadable." }
        }
        $vlmFeedback = "No pixel capture available (Tier 3 structural floor); the VLM critique was skipped. Structural notes: $notes".Trim()
        $merged = Merge-DesignSignals -LayoutHard $layoutResult.Hard -LayoutMessages $layoutResult.Messages `
            -VlmOk $false -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback $vlmFeedback `
            -Iteration $Iteration -MaxIter $MaxIter
        return @{
            ShouldIterate  = $merged.ShouldIterate   # driven by the layout gate alone here
            NeedsWork      = $merged.NeedsWork
            Feedback       = $merged.Feedback
            CaptureTier    = 'structural'
            Ok             = $false
            LayoutHard     = $merged.LayoutHard
            ScreenshotPath = ''
        }
    }

    # ---- Step 3: CAPTURE-FAIL or bad exit --------------------------------
    if ($captureExit -ne 0 -or -not ($captureSignal -match '^CAPTURE-OK:')) {
        $detail = if ($captureSignal) { $captureSignal } else { "exit $captureExit" }
        return _FailResult "Capture failed: $detail" ''
    }

    # Parse the capture tier (tier=1 or tier=2) from CAPTURE-OK line.
    $captureTier = '?'
    if ($captureSignal -match 'tier=(\d+)') { $captureTier = $Matches[1] }

    # Verify the PNG exists on disk.
    if (-not (Test-Path $pngPath) -or (Get-Item $pngPath).Length -eq 0) {
        return _FailResult "Capture reported OK but PNG is missing or empty at '$pngPath'" $captureTier
    }

    # ---- Step 3.5: deterministic PIXEL gate (Lever B) -------------------
    # A real PNG now exists -- run the pixel linter (colour-presence + element-geometry) over it.
    # Combined with the XAML layout gate, its HIGH findings (a) force a FIX even if the VLM passes
    # and (b) are fed to the VLM as "confirm each is fixed". Fail-soft (no python/PNG -> empty).
    $pixelResult = Invoke-PixelLint -Png $pngPath -BlarAiRepo $BlarAiRepo `
        -CriteriaJson $VisualCriteriaJson -Goal $Goal

    # Combine layout + pixel HIGH messages into the single deterministic-findings feed the VLM must
    # confirm fixed (--layout-findings-json is the generic "known issues to confirm" channel).
    $detMessages = @($layoutResult.Messages) + @($pixelResult.Messages)
    $detMessagesJson = '[' + (($detMessages | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ']'

    # ---- Step 3.6: browser RUNTIME channel (#823 H8/H9, Lever D) ---------
    # A WEB capture (capture-web-cdp.mjs) writes "<png>.console.json" carrying the protocol-level
    # console + uncaught exceptions + the positive behavior smoke. Read it: a captured:true sidecar
    # with hard=true forces a FIX and LEADS the feedback (ranked above the VLM's cosmetic critique).
    # Missing / captured:false (WinUI capture, or the msedge --screenshot fallback) -> NO runtime
    # signal, so a console-blind capture degrades to today's pixel-only behavior, honestly.
    $runtimeResult = Read-ConsoleSidecar -SidecarPath "$pngPath.console.json"

    # ---- Step 4: VLM critique -------------------------------------------
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) {
        return _FailResult "BlarAI python not found at '$pythonExe'. Is BlarAiRepo correct?" $captureTier
    }

    $critiqueLines = $null
    $critiqueExit = 0
    try {
        # Run from BlarAiRepo as cwd (the module import requires the BlarAI package on sys.path).
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $BlarAiRepo
            $critiqueLines = @(& $pythonExe -m shared.fleet.critique `
                --screenshot $pngPath `
                --goal $Goal `
                --criteria-json $VisualCriteriaJson `
                --layout-findings-json $detMessagesJson `
                --max-iter $MaxIter `
                --iteration $Iteration 2>&1)
            $critiqueExit = $LASTEXITCODE
        } finally {
            Set-Location $prevLoc
        }
    } catch {
        return _FailResult "VLM critique threw: $($_.Exception.Message)" $captureTier
    }

    if ($critiqueExit -ne 0) {
        $detail = ($critiqueLines | Select-Object -Last 3) -join ' | '
        return _FailResult "VLM critique exited $critiqueExit (usage error): $detail" $captureTier
    }

    # Find the JSON line (the CLI prints exactly ONE JSON line to stdout).
    $jsonLine = ($critiqueLines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) {
        $detail = ($critiqueLines | Where-Object { $_ } | Select-Object -Last 3) -join ' | '
        return _FailResult "VLM critique produced no JSON line (stdout: $detail)" $captureTier
    }

    $critiqueObj = $null
    try { $critiqueObj = $jsonLine | ConvertFrom-Json } catch {
        return _FailResult "VLM critique JSON parse failed ('$jsonLine'): $($_.Exception.Message)" $captureTier
    }

    # Extract and type-coerce fields (ConvertFrom-Json gives PSCustomObject).
    $ok            = [bool]($critiqueObj.ok)
    $needsWork     = [bool]($critiqueObj.needs_work)
    $feedback      = [string]($critiqueObj.feedback ?? '')
    $shouldIterate = [bool]($critiqueObj.should_iterate)

    # Combine the soft VLM signal with the HARD deterministic gates: a layout (Lever A), pixel
    # (Lever B), or browser-RUNTIME (Lever D, #823) defect forces a FIX even when the VLM passed
    # (the false-pass fix). Runtime findings LEAD the merged feedback (fix the thrown error first).
    $merged = Merge-DesignSignals -LayoutHard $layoutResult.Hard -LayoutMessages $layoutResult.Messages `
        -PixelHard $pixelResult.Hard -PixelMessages $pixelResult.Messages `
        -RuntimeHard $runtimeResult.Hard -RuntimeMessages $runtimeResult.Messages `
        -VlmOk $ok -VlmNeedsWork $needsWork -VlmShouldIterate $shouldIterate -VlmFeedback $feedback `
        -Iteration $Iteration -MaxIter $MaxIter
    return @{
        ShouldIterate   = $merged.ShouldIterate
        NeedsWork       = $merged.NeedsWork
        Feedback        = $merged.Feedback
        CaptureTier     = $captureTier
        Ok              = $ok
        LayoutHard      = $merged.LayoutHard
        RuntimeHard     = $merged.RuntimeHard
        RuntimeCaptured = $runtimeResult.Captured
        ScreenshotPath  = $pngPath
    }
}

# ---------------------------------------------------------------------------
# Invoke-CritiqueLoop : loop driver with injected rebuild callback
# ---------------------------------------------------------------------------
function Invoke-CritiqueLoop {
    <#
    .SYNOPSIS
      Iterate: critique -> if ShouldIterate, invoke the rebuild callback with $Feedback
      -> increment iteration -> repeat until ShouldIterate=$false OR MaxIter reached.

      The rebuild callback is INJECTED so the loop is testable without a real coder:
        $RebuildCallback = { param($Feedback, $CurrentAppDir) return $NewAppDir }
      It receives the feedback string and the current AppDir; it returns the new AppDir
      for the next capture. If the callback does not return a new dir, AppDir is kept.

    .PARAMETER AppDir
      Initial built app worktree root.

    .PARAMETER Goal
      Plain-English product goal.

    .PARAMETER VisualCriteriaJson
      JSON array of visual criterion text strings.

    .PARAMETER BlarAiRepo
      Path to the BlarAI repository root.

    .PARAMETER MaxIter
      Hard cap on total FIX iterations (default 3).

    .PARAMETER WorkDir
      Scratch directory for critique PNG files. Created if absent.

    .PARAMETER RebuildCallback
      Scriptblock to invoke when another iteration is needed.
      Signature: { param([string]$Feedback, [string]$AppDir) return [string]$NewAppDir }
      May return $null/$empty to keep the current AppDir unchanged.

    .OUTPUTS
      Hashtable:
        FinalResult    [hashtable]  The last Invoke-CritiquePass result.
        Iterations     [int]        Total iterations completed (0 = zero critique passes).
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$VisualCriteriaJson,
        [Parameter(Mandatory)][string]$BlarAiRepo,
        [int]$MaxIter = 3,
        [string]$WorkDir = '',
        [scriptblock]$RebuildCallback = $null
    )

    $currentAppDir = $AppDir
    $iteration = 0
    $lastResult = $null

    while ($iteration -lt $MaxIter) {
        $result = Invoke-CritiquePass `
            -AppDir $currentAppDir `
            -Goal $Goal `
            -VisualCriteriaJson $VisualCriteriaJson `
            -BlarAiRepo $BlarAiRepo `
            -Iteration $iteration `
            -MaxIter $MaxIter `
            -WorkDir $WorkDir

        $lastResult = $result
        $iteration++

        if (-not $result.ShouldIterate) { break }

        # Invoke the rebuild callback with the feedback.
        if ($RebuildCallback) {
            try {
                $newDir = & $RebuildCallback $result.Feedback $currentAppDir
                if ($newDir -and (Test-Path $newDir)) { $currentAppDir = $newDir }
            } catch {
                # Rebuild callback threw -- stop the loop (fail-soft).
                $lastResult = _FailResult "Rebuild callback threw: $($_.Exception.Message)" $result.CaptureTier
                break
            }
        }
    }

    # If we exhausted MaxIter without stopping naturally, mark the last result as
    # ShouldIterate=$false (the budget is spent regardless of what the VLM said).
    if ($lastResult -and $lastResult.ShouldIterate -and $iteration -ge $MaxIter) {
        $lastResult = $lastResult.Clone()
        $lastResult.ShouldIterate = $false
    }

    return @{
        FinalResult = $lastResult
        Iterations  = $iteration
    }
}

# ---------------------------------------------------------------------------
# When dot-sourced: export both functions.
# When run as a script with all mandatory params: run one pass and write result.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    # Running as a script (not dot-sourced): execute one pass with the supplied params.
    if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "critique-loop-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
    $result = Invoke-CritiquePass `
        -AppDir $AppDir `
        -Goal $Goal `
        -VisualCriteriaJson $VisualCriteriaJson `
        -BlarAiRepo $BlarAiRepo `
        -Iteration $Iteration `
        -MaxIter $MaxIter `
        -WorkDir $WorkDir
    $result | ConvertTo-Json -Depth 3
}
