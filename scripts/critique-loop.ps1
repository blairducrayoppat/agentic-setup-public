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
    [string]$WorkDir = '',
    # #1171: the intake-declared surface (build_plan.surface), threaded to the Tier-3
    # structural check so its not-applicable line states a fact, not a hypothesis.
    [string]$DeclaredSurface = ''
)
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

#: #1198 -- the statuses a deterministic design lint can return. A named set because the whole point of
#: this layer is that "the lint ran and found nothing" and "the lint did not run" are DIFFERENT FACTS, and
#: a caller that collapses them re-creates the defect one layer up.
$script:DesignLintStatuses = @('clean', 'findings', 'not-applicable', 'unavailable')

function New-DesignLintResult {
    <#
    .SYNOPSIS
      The empty/degraded design-lint result shape (#1198). Every field is present at every exit, so no
      caller ever reads a missing property as a zero. Measured=$false means NO VERDICT WAS OBTAINED --
      never "nothing found". Hard/Messages/MessagesJson keep their prior shape and prior inert values, so
      a caller that reads only those is unchanged.
    #>
    param([string]$Lint = 'layout', [string]$Status = 'unavailable', [string]$Detail = '')
    return @{
        Lint         = $Lint
        Status       = $Status
        Measured     = $false
        Detail       = $Detail
        Hard         = $false
        Messages     = @()
        MessagesJson = '[]'
        FilesScanned = 0
        # Files the lint opened but could NOT read or parse. They were scanned and NOT examined, which is
        # a third thing again: the lint ran, so Measured stays true for the files it did read, but these
        # ones are unexamined and must be disclosed rather than absorbed into the clean count.
        Unparsed     = @()
    }
}

function Format-DesignLintCaveat {
    <#
    .SYNOPSIS
      PURE (#1198): the operator-facing line for a design lint that produced NO verdict. Returns '' for a
      measured lint -- an empty string composes away to nothing, so the caveat channel is silent whenever
      every lever actually reported.

      The wording has exactly one job: stop an unexamined deliverable reading as an examined-and-clean one.
      It names the lint, the cause, and the axis that is therefore UNKNOWN -- and it never implies a defect
      was found, because none was. That distinction is the whole point.
    #>
    param(
        [Parameter(Mandatory)][string]$Lint,
        [bool]$Measured = $false,
        [string]$Detail = '',
        [string]$Status = '',
        [string[]]$Unparsed = @()
    )
    $label = if ($Lint -eq 'pixel') { 'rendered-pixel lint' } else { 'XAML layout lint' }
    $axis  = if ($Lint -eq 'pixel') { 'The rendered appearance' } else { 'The XAML layout' }
    if ($Measured) {
        # A PARTIAL examination is its own fact. The lint ran and reported on the files it could read, so
        # its findings stand -- but a file it could not parse is unexamined, and folding those into the
        # clean count is the same collapse at a smaller grain.
        if (@($Unparsed).Count -gt 0) {
            $names = (@($Unparsed) | Select-Object -First 5) -join ', '
            if (@($Unparsed).Count -gt 5) { $names = "$names, +$(@($Unparsed).Count - 5) more" }
            return ("DESIGN LINT: the $label SKIPPED $(@($Unparsed).Count) file(s) it could not read or parse " +
                    "($names). Those files are UNEXAMINED - an ABSENT measurement for them, not a clean one.")
        }
        return ''
    }
    $line = if ($Status -eq 'not-applicable') {
        "DESIGN LINT: the $label had NOTHING TO EXAMINE"
    } else {
        "DESIGN LINT: the $label DID NOT RUN"
    }
    if ($Detail) { $line = "$line - $Detail" }
    return "$line. $axis of this deliverable is UNEXAMINED - an ABSENT measurement, not a clean one."
}

function Format-SmokeContractCaveat {
    <#
    .SYNOPSIS
      PURE: the operator-facing line for the BEHAVIOR CONTRACT -- what the headless capture was told
      to exercise, and whether it managed to.

      Same job as Format-DesignLintCaveat, aimed at a different collapse. The capture's behavior
      smoke is either DECLARED (the plan named the control to use and the region that must change,
      and the coder was told to mark both) or HEURISTIC (nobody said, so the capture guessed at the
      first visible button and its failures are only a soft note). Those read identically in a green
      report, and for every web build before the plan-side writer existed only the second was ever
      possible -- silently. This states which one happened.

      Returns '' -- silence -- for the fully honest case (a contract was declared AND exercised) and
      for a surface where the question does not arise. A WEB run with no contract is NOT silence:
      "nothing was declared" is a real limitation on what the report can claim, and hiding it is how
      the heuristic passed for a check.

      APPLICABILITY IS LOAD-BEARING. This caveat feeds Get-DesignCritiqueNote, which withholds the
      clean bill whenever ANY caveat is present -- so a caveat that fires where it cannot apply is
      not a harmless extra line, it downgrades a correct verdict. A WinUI/desktop capture, the
      structural floor and the pixel-only fallback have no browser behavior smoke BY CONSTRUCTION;
      reporting their contract as "unexamined" would be the same mistake as calling a project with
      no XAML an unexamined layout (the #1140 shape). Only the web capture tier is applicable, and
      the caller knows which tier fired.
    #>
    param(
        [bool]$Declared = $false,
        [bool]$Measured = $false,
        [string]$Status = '',
        # Default $true keeps the function's standing inert contract intact: a caller supplying
        # nothing still gets '' via the Status/Declared check below, and an explicit $false is the
        # positive statement "this surface has no browser behavior smoke".
        [bool]$Applicable = $true
    )
    if (-not $Applicable) { return '' }
    # Inert default: a caller that supplies nothing at all (every pre-contract caller) gets ''.
    if (-not $Declared -and -not $Status) { return '' }
    if ($Declared -and $Measured) { return '' }
    if (-not $Declared) {
        if ($Status -eq 'unavailable') {
            return ("BEHAVIOR CONTRACT: the browser capture did not report on it, so it is UNKNOWN " +
                    "whether the product's main action was exercised - an ABSENT measurement, not a clean one.")
        }
        if ($Status -and $Status -ne 'not-declared') {
            return ("BEHAVIOR CONTRACT: a contract WAS present but could not be used ($Status), so the " +
                    "declared check DID NOT RUN and the capture guessed instead. Whether the product's " +
                    "main action works is UNEXAMINED - an ABSENT measurement, not a clean one.")
        }
        return ("BEHAVIOR CONTRACT: none was declared for this product, so the capture GUESSED at the " +
                "main action (first visible control) and any failure was only a note, never a finding. " +
                "Whether the intended action works is UNEXAMINED - an ABSENT measurement, not a clean one.")
    }
    # DECLARED but not measured. Splitting by status is load-bearing: these states have DIFFERENT
    # culprits and only one of them has a finding upstream, and a single sentence covering all of
    # them has to assert both facts about states where neither holds.
    if ($Status -eq 'action-hook-missing' -or $Status -eq 'result-hook-missing') {
        # The delivery's fault: the contract named hooks the coder was told to place and did not.
        # `behaviorHard` is true here, so the capture ALREADY raised it as a hard finding and this
        # line only records the reach -- pointing at feedback that is genuinely there.
        return ("BEHAVIOR CONTRACT: declared, but the capture could not exercise it ($Status) - the " +
                "delivery is missing the markers the coder was told to place, so the declared behavior " +
                "is UNEXAMINED. The finding itself is in the fix feedback above.")
    }
    if ($Status -eq 'unavailable') {
        # The CAPTURE's fault, not the delivery's: `unavailable` is what capture-web-cdp.mjs emits
        # when the evaluate block THREW after reading a valid spec. `behavior.ran` is false there,
        # so `behaviorHard` is false, NO finding was raised and NO note was pushed. Blaming the
        # delivery for missing markers and pointing at a finding above are both untrue -- and the
        # second is worse than a wrong diagnosis, because it sends a reader looking for text that
        # does not exist and reads its absence as "nothing serious".
        return ("BEHAVIOR CONTRACT: declared, but the browser capture itself failed before it could " +
                "exercise it ($Status) - a CAPTURE failure, not a defect in the delivery. No finding " +
                "was raised, and whether the product's main action works is UNEXAMINED - an ABSENT " +
                "measurement, not a clean one.")
    }
    # Any other status, including one this side does not recognise (the JS half renamed a constant,
    # a legacy producer). The DISCLOSURE still holds -- a contract existed and was not exercised --
    # so it is made; the CAUSE is not known here, so none is asserted and no upstream finding is
    # promised. Same distinction swap_ops.smoke_contract_disposition draws: refusing to make a claim
    # on evidence this side cannot parse is right, refusing to make a disclosure is not.
    return ("BEHAVIOR CONTRACT: declared, but the capture did not exercise it ($Status), so whether " +
            "the product's main action works is UNEXAMINED - an ABSENT measurement, not a clean one.")
}

function _FailResult([string]$Feedback, [string]$CaptureTier = '', $Layout = $null, $Pixel = $null) {
    # #1198: the design-lint fields are present on EVERY exit, so a consumer can never read their absence
    # as a measurement. Whichever lint has already reported by the time a pass fails is threaded in as its
    # REAL result -- an honesty channel that under-reports a lint that DID run is telling its own kind of
    # lie. A lint that never got to run is reported as exactly that, with the reason.
    $lay = $Layout
    if ($null -eq $lay) {
        $lay = New-DesignLintResult -Lint 'layout' -Detail 'this critique pass produced no layout verdict at all'
    }
    $pix = $Pixel
    if ($null -eq $pix) {
        $pix = New-DesignLintResult -Lint 'pixel' -Detail 'this critique pass produced no rendered-pixel verdict at all'
    }
    $caveats = @(
        (Format-DesignLintCaveat -Lint 'layout' -Measured ([bool]$lay.Measured) -Detail "$($lay.Detail)" -Status "$($lay.Status)")
        (Format-DesignLintCaveat -Lint 'pixel' -Measured ([bool]$pix.Measured) -Detail "$($pix.Detail)" -Status "$($pix.Status)")
    ) | Where-Object { $_ }
    return @{
        ShouldIterate  = $false
        NeedsWork      = $false
        Feedback       = $Feedback
        CaptureTier    = $CaptureTier
        Ok             = $false
        ScreenshotPath = ''
        LayoutMeasured = [bool]$lay.Measured
        LayoutStatus   = "$($lay.Status)"
        PixelMeasured  = [bool]$pix.Measured
        PixelStatus    = "$($pix.Status)"
        LintsMeasured  = ([bool]$lay.Measured -and [bool]$pix.Measured)
        Caveats        = @($caveats)
        CaveatText     = (@($caveats) -join "`n")
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

      #1198 -- an UNMEASURED lint rides its OWN channel. It changes what the report SAYS, never what the
      loop DECIDES: ShouldIterate/NeedsWork/Feedback are computed from the HARD signals alone, exactly as
      before, and the absence surfaces as Caveats/CaveatText/LintsMeasured.

      Returns @{ ShouldIterate=[bool]; NeedsWork=[bool]; Feedback=[string]; LayoutHard=[bool];
      RuntimeHard=[bool]; LayoutMeasured=[bool]; PixelMeasured=[bool]; LintsMeasured=[bool];
      Caveats=[string[]]; CaveatText=[string] }.
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
        # #1198: whether each deterministic lint actually OBTAINED a verdict, and why not when it did not.
        # Default $true = INERT, matching this function's standing contract that an unsupplied lever
        # contributes nothing (Pixel*/Runtime* do the same). The FAIL-CLOSED default lives where the fact
        # is produced -- New-DesignLintResult sets Measured=$false -- not here, where $false would mean
        # "every caller who omits it is declared unexamined" and would bury the real absences in noise.
        [bool]$LayoutMeasured = $true,
        [string]$LayoutDetail = '',
        [string]$LayoutStatus = '',
        # Layout only: the XAML gate reads many files and can fail to parse some of them. The pixel gate
        # reads one image and has no partial-examination state.
        [string[]]$LayoutUnparsed = @(),
        [bool]$PixelMeasured = $true,
        [string]$PixelDetail = '',
        [string]$PixelStatus = '',
        # The behavior-CONTRACT honesty channel. Same discipline as the lint caveats above: it
        # changes what the report SAYS, never what the loop DECIDES. Defaults are INERT (declared
        # =$false + status='' emits no caveat) so every pre-contract caller is byte-identical.
        [bool]$SmokeDeclared = $false,
        [bool]$SmokeMeasured = $false,
        [string]$SmokeStatus = '',
        # Whether the declared contract PASSED, not merely whether it ran. Default $false is the
        # inert one: a caller that supplies nothing affirms nothing, on any surface.
        [bool]$SmokePassed = $false,
        # Whether this capture surface HAS a browser behavior smoke at all (the web tier does; a
        # WinUI capture, the structural floor and the pixel-only fallback do not). $true is the
        # inert default; the caveat is suppressed outright when $false.
        [bool]$SmokeApplicable = $true,
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

    # #1198: an ABSENT measurement is REPORTED, never merged into the verdict, and never put in $feedback.
    #   * Not a hard signal: there is no finding to fix, so forcing a FIX lap would spend the iteration
    #     budget re-running the coder against nothing -- a broken tool would become a wrecked night, and a
    #     hard verdict asserts a defect was found when none was.
    #   * Not silence: silence is the defect -- a missing linter reading as a clean layout, forever.
    #   * Not in $feedback: $feedback is the coder's FIX prompt (Add-VisualFeedback). "The linter could not
    #     run" is not something the coder can act on; it would send the model chasing the harness.
    # So it rides its own channel to the OPERATOR, and ShouldIterate/NeedsWork/Feedback are untouched.
    $caveats = @(
        (Format-DesignLintCaveat -Lint 'layout' -Measured $LayoutMeasured -Detail $LayoutDetail -Status $LayoutStatus -Unparsed $LayoutUnparsed)
        (Format-DesignLintCaveat -Lint 'pixel' -Measured $PixelMeasured -Detail $PixelDetail -Status $PixelStatus)
        (Format-SmokeContractCaveat -Declared $SmokeDeclared -Measured $SmokeMeasured -Status $SmokeStatus -Applicable $SmokeApplicable)
    ) | Where-Object { $_ }

    # LayoutHard in the return means "any deterministic hard finding" so the Python _design_note
    # (which reads layout_hard) reports deterministic issues for pixel/runtime hits too. For a
    # pre-pixel/pre-runtime caller Pixel/RuntimeHard=$false, so $detHard == $LayoutHard and the return
    # is byte-identical. RuntimeHard is ALSO returned distinctly so the Python side can word the
    # operator note as a runtime error (not "layout") and gate the clean-ending reclass on it.
    return @{
        ShouldIterate  = $shouldIterate
        NeedsWork      = $needsWork
        Feedback       = $feedback
        LayoutHard     = $detHard
        RuntimeHard    = [bool]$RuntimeHard
        LayoutMeasured = [bool]$LayoutMeasured
        PixelMeasured  = [bool]$PixelMeasured
        # LintsMeasured names exactly what it covers -- the two deterministic LINTS. The browser-runtime
        # channel reports its own availability through Read-ConsoleSidecar's Captured flag.
        LintsMeasured  = ([bool]$LayoutMeasured -and [bool]$PixelMeasured)
        # The behavior contract reports separately from LintsMeasured, which names exactly the two
        # deterministic LINTS. Folding a third thing into that bool would make a true reading mean
        # three different things and an absence unattributable to any of them.
        SmokeDeclared  = [bool]$SmokeDeclared
        SmokeMeasured  = [bool]$SmokeMeasured
        SmokeStatus    = [string]$SmokeStatus
        # The pass/fail reading rides the SAME reporting channel and is equally inert here: it
        # changes what the RESULT line SAYS, never what this function DECIDES. A failed declared
        # contract already forced its fix laps through ``hard``; by the time anyone reads this the
        # laps are spent, and re-deciding on it would spend them twice.
        SmokePassed    = [bool]$SmokePassed
        Caveats        = @($caveats)
        CaveatText     = (@($caveats) -join "`n")
    }
}

function Invoke-LayoutLint {
    <#
    .SYNOPSIS
      Run the deterministic XAML layout gate (shared/fleet/layout_lint.py) over an app dir.

      FAIL-SOFT IS NOT FAIL-SILENT (#1198). The loop still degrades to the VLM-only signal and this never
      throws -- but the ABSENCE is now a readable fact instead of a clean-looking empty result:
        * no interpreter / crash / no JSON / unparseable JSON -> Status='unavailable', Measured=$false,
          Detail naming the cause (python's own last words where it had any).
        * a run that scanned ZERO .xaml files -> Status='not-applicable', Measured=$false. Zero files is
          not a clean layout; it is no layout examined. A node/web candidate lands here by construction,
          and so does a WinUI candidate whose XAML never reached the worktree -- both would read as
          "clean" if this were folded into the measured branch below.
      CALLERS GATE ON .Measured, NEVER ON .Messages.Count.
      Returns the New-DesignLintResult shape:
      @{ Lint; Status; Measured=[bool]; Detail; Hard=[bool]; Messages=[string[]]; MessagesJson; FilesScanned }.
    #>
    param(
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$BlarAiRepo
    )
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) {
        return (New-DesignLintResult -Lint 'layout' -Detail "no BlarAI python interpreter at $pythonExe")
    }
    $lines = @()
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $BlarAiRepo
            $lines = @(& $pythonExe -m shared.fleet.layout_lint --app-dir $AppDir 2>&1)
        } finally { Set-Location $prevLoc }
    } catch {
        return (New-DesignLintResult -Lint 'layout' -Detail "the layout lint could not be invoked: $($_.Exception.Message)")
    }
    $jsonLine = ($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) {
        $tail = ((@($lines | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | ')
        if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
        return (New-DesignLintResult -Lint 'layout' -Detail "the layout lint emitted no JSON (module missing, import error or crash): $tail")
    }
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        return (New-DesignLintResult -Lint 'layout' -Detail "the layout lint's output was not parseable JSON: $jsonLine")
    }
    $out = New-DesignLintResult -Lint 'layout'
    $out.FilesScanned = [int]$obj.files_scanned
    if ($out.FilesScanned -le 0) {
        $out.Status = 'not-applicable'
        $out.Detail = "no .xaml files under $AppDir, so this surface has no XAML layout to examine"
        return $out
    }
    # A file the module could not read or parse is reported as a LOW finding, which never reaches Hard and
    # never reaches the HIGH message filter below -- so without this it would land in the clean count as a
    # file that was examined and found sound. It was not examined at all.
    $out.Unparsed = @($obj.findings |
        Where-Object { $_.rule -eq 'unparseable' -or $_.rule -eq 'unreadable' } |
        ForEach-Object { [string]$_.file })
    if (@($out.Unparsed).Count -ge $out.FilesScanned) {
        $out.Status = 'not-applicable'
        $out.Detail = "all $($out.FilesScanned) .xaml file(s) under $AppDir failed to read or parse, so no layout was examined"
        return $out
    }
    $msgs = @($obj.findings | Where-Object { $_.severity -eq 'high' } | ForEach-Object { [string]$_.message })
    $out.Hard = [bool]($obj.hard)
    $out.Messages = $msgs
    $out.MessagesJson = '[' + (($msgs | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ']'
    $out.Measured = $true
    # Hard is the gate, not the count -- the same rule the merge applies to the messages themselves.
    $out.Status = if ($out.Hard) { 'findings' } else { 'clean' }
    return $out
}

function Invoke-PixelLint {
    <#
    .SYNOPSIS
      Run the deterministic PIXEL gate (shared/fleet/pixel_lint.py) over a captured screenshot --
      reference-free colour-presence + element-geometry, the count/colour/position axes the VLM
      hallucinates on. The complement to Invoke-LayoutLint (XAML), needing a real PNG.

      FAIL-SOFT IS NOT FAIL-SILENT (#1198). The loop still degrades to the layout+VLM signal and this never
      throws -- but every degraded path (missing PNG, no interpreter, crash, no JSON, unparseable JSON)
      returns Status='unavailable' + Measured=$false with a Detail naming the cause, so an unexamined
      render can no longer read as an examined-and-clean one. CALLERS GATE ON .Measured.
      Returns the New-DesignLintResult shape -- the same shape as Invoke-LayoutLint, so the caller
      composes both identically.

      KNOWN LIMIT OF THE MODULE'S OWN CONTRACT (#1221): shared/fleet/pixel_lint.py returns
      {"findings": [], "hard": false} for an image it could not DECODE, which is byte-identical to a clean
      render. This seam cannot distinguish those two, so a corrupt-but-non-empty PNG still reads as clean;
      closing that needs a measured/undecodable flag on the module's own output.
    #>
    param(
        [Parameter(Mandatory)][string]$Png,
        [Parameter(Mandatory)][string]$BlarAiRepo,
        [string]$CriteriaJson = '[]',
        [string]$Goal = ''
    )
    if (-not (Test-Path $Png)) {
        return (New-DesignLintResult -Lint 'pixel' -Detail "no screenshot on disk at $Png")
    }
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) {
        return (New-DesignLintResult -Lint 'pixel' -Detail "no BlarAI python interpreter at $pythonExe")
    }
    $lines = @()
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $BlarAiRepo
            $lines = @(& $pythonExe -m shared.fleet.pixel_lint --screenshot $Png `
                --criteria-json $CriteriaJson --goal $Goal 2>&1)
        } finally { Set-Location $prevLoc }
    } catch {
        return (New-DesignLintResult -Lint 'pixel' -Detail "the pixel lint could not be invoked: $($_.Exception.Message)")
    }
    $jsonLine = ($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) {
        $tail = ((@($lines | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | ')
        if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
        return (New-DesignLintResult -Lint 'pixel' -Detail "the pixel lint emitted no JSON (module missing, import error or crash): $tail")
    }
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        return (New-DesignLintResult -Lint 'pixel' -Detail "the pixel lint's output was not parseable JSON: $jsonLine")
    }
    $out = New-DesignLintResult -Lint 'pixel'
    # pixel_lint emits only HIGH findings, but filter for parity with Invoke-LayoutLint.
    $msgs = @($obj.findings | Where-Object { $_.severity -eq 'high' } | ForEach-Object { [string]$_.message })
    $out.Hard = [bool]($obj.hard)
    $out.Messages = $msgs
    $out.MessagesJson = '[' + (($msgs | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ']'
    $out.Measured = $true
    $out.Status = if ($out.Hard) { 'findings' } else { 'clean' }
    return $out
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
      The BEHAVIOR-CONTRACT honesty fields ride alongside. The capture's positive behavior smoke has
      two quite different clean readings -- "the plan declared what to exercise and it worked" and
      "nothing was declared, so a heuristic guessed" -- and until the plan-side writer existed only
      the second could ever occur, invisibly. SmokeDeclared/SmokeMeasured/SmokeStatus keep them
      apart. They are REPORTING only: the loop's decision still comes from ``hard``, exactly as
      before, because "no contract was declared" is not something the coder can fix.

      SmokePassed answers the question the other three cannot: those three say whether the declared
      check RAN; only this one says whether it PASSED. A contract that ran and FAILED (the operator
      pressed nothing, the marked region never changed) left every one of the three reading exactly
      as it does for a contract that ran and succeeded -- which is how a run whose declared
      behaviour failed, and whose three fix passes then failed too, could still sign off as a clean
      delivery. Positive polarity on purpose: $false means "not affirmed", which is the safe
      reading on every surface that has no browser behaviour smoke at all.
      Returns @{ Captured=[bool]; Hard=[bool]; Messages=[string[]]; Notes=[string[]];
      SmokeDeclared=[bool]; SmokeMeasured=[bool]; SmokeStatus=[string]; SmokePassed=[bool] }.
    #>
    param([Parameter(Mandatory)][string]$SidecarPath)
    # A capture that produced no sidecar tells us nothing about the contract either -- 'unavailable'
    # is the honest reading, never 'not-declared' (which would assert the plan declared nothing).
    $empty = @{ Captured = $false; Hard = $false; Messages = @(); Notes = @()
                SmokeDeclared = $false; SmokeMeasured = $false; SmokeStatus = 'unavailable'
                SmokePassed = $false }
    if (-not (Test-Path $SidecarPath)) { return $empty }
    try { $obj = Get-Content $SidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $empty }
    if (-not $obj -or -not $obj.captured) { return $empty }
    $msgs = @()
    if ($obj.findings) { $msgs = @($obj.findings | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    $notes = @()
    if ($obj.notes) { $notes = @($obj.notes | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    # A legacy helper writes no `smoke` block. Absent -> declared=$false, measured=$false,
    # status='unavailable': it can neither claim the contract ran nor claim none existed.
    $declared = $false; $measured = $false; $status = 'unavailable'; $passed = $false
    if ($null -ne $obj.smoke) {
        $declared = [bool]$obj.smoke.declared
        $measured = [bool]$obj.smoke.measured
        if ($obj.smoke.status) { $status = [string]$obj.smoke.status }
        # ``behaviorHard``, NOT ``hard``. The aggregate is ALSO raised by a console error, an
        # uncaught exception or an undefined/NaN text leak, so reading it here would report a page
        # that merely threw as a failed contract -- and would leave a failed contract on an
        # otherwise quiet page indistinguishable from either. ``behaviorHard`` is the capture's one
        # field that means exactly "a DECLARED must-work feature did not work".
        #
        # A PASS IS AFFIRMED, NEVER INFERRED. Both halves are required: the contract must have been
        # exercised (measured), and the capture must have STATED the verdict. A producer that
        # writes a `smoke` block but no ``behaviorHard`` leaves the verdict unread, and unread
        # resolves to $false -- not passed -- because the only consumer of this field composes a
        # clean bill from it.
        if ($measured -and $null -ne $obj.behaviorHard) { $passed = -not [bool]$obj.behaviorHard }
    }
    return @{ Captured = $true; Hard = [bool]$obj.hard; Messages = $msgs; Notes = $notes
              SmokeDeclared = $declared; SmokeMeasured = $measured; SmokeStatus = $status
              SmokePassed = $passed }
}

# ---------------------------------------------------------------------------
# Invoke-CritiquePass : ONE capture + critique pass
# ---------------------------------------------------------------------------
function Resolve-UnservedAssetFindings {
    <#
    .SYNOPSIS
      Rewrite a browser 4xx/5xx finding into an ACTIONABLE diagnosis (#1133).

      THE INCIDENT (2026-07-27, run 20260727-215338-bd). The capture stage worked: it
      caught a 404 on `header/header.styles.css`, set hard=true, and surfaced the message
      to the fix loop TWICE. The loop then committed five more lines of CSS *into that
      same unreachable file*. It had the diagnosis in plain English and still edited a
      file the page cannot load.

      The cause is the WORDING, not a missing signal. The browser says "Failed to load
      resource", which reads as "this resource is inadequate" and invites "improve it".
      What the coder needs to hear is "this file is not being served, so editing it
      cannot change the page" — which is a fact we can determine deterministically from
      the worktree, not something the model should have to infer.

      PURE + FAIL-SOFT: any parse/IO failure returns the ORIGINAL message untouched, so a
      degraded environment can never lose the finding (it only loses the enrichment).
      Messages that are not same-origin asset failures pass through verbatim.

    .PARAMETER Messages
      The runtime findings from Read-ConsoleSidecar.
    .PARAMETER AppDir
      The worktree root, used to locate the missing file and the served root.
    .OUTPUTS
      [string[]] — same length and order as $Messages, each either enriched or verbatim.
    #>
    param(
        [string[]]$Messages = @(),
        [string]$AppDir = ''
    )
    if (-not $Messages -or $Messages.Count -eq 0) { return @() }

    # The directories a zero-dependency static server actually exposes. `public` is the
    # seeded convention; `static`/`www`/`dist` cover the shapes a coder may choose.
    $servedNames = @('public', 'static', 'www', 'dist')
    $servedRoots = @()
    if ($AppDir -and (Test-Path -LiteralPath $AppDir)) {
        foreach ($n in $servedNames) {
            $p = Join-Path $AppDir $n
            if (Test-Path -LiteralPath $p) { $servedRoots += $n }
        }
    }

    $out = @()
    foreach ($m in $Messages) {
        $msg = [string]$m
        try {
            # Only same-origin asset failures. A 4xx/5xx with a loopback URL.
            if ($msg -notmatch '(?i)status of (4\d\d|5\d\d)') { $out += $msg; continue }
            # Capture the status BEFORE the next -match overwrites $Matches.
            $status = $Matches[1]
            if ($msg -notmatch '(?i)\((https?://(127\.0\.0\.1|localhost)[^)\s]*)\)') { $out += $msg; continue }
            $url = $Matches[1]
            $rel = ([uri]$url).AbsolutePath.TrimStart('/')
            if (-not $rel) { $out += $msg; continue }
            # A missing favicon is browser noise, not a defect the coder introduced.
            if ($rel -ieq 'favicon.ico') { $out += $msg; continue }

            # Without a readable worktree we cannot tell "exists but unserved" from
            # "does not exist" — and asserting either would be a claim we did not check.
            # Pass the browser's message through untouched rather than invent a diagnosis.
            if (-not $AppDir -or -not (Test-Path -LiteralPath $AppDir)) { $out += $msg; continue }

            $onDisk = ''
            $candidate = Join-Path $AppDir ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $candidate) { $onDisk = $rel }

            $servedHint = if ($servedRoots.Count -gt 0) { $servedRoots -join '/ or ' } else { 'the served root' }

            if ($onDisk) {
                # THE INCIDENT'S SHAPE: the file exists, but outside what the server serves.
                $out += ("The page requested '/$rel' and the server returned $status — " +
                         "the file EXISTS at '$onDisk' but is NOT under the served directory ($servedHint), " +
                         "so the server never returns it. EDITING '$onDisk' CANNOT CHANGE THE PAGE. " +
                         "Move it under $servedHint (and update the link in the HTML), or inline its contents into the page.")
            } else {
                $out += ("The page requested '/$rel' and the server returned $status — nothing exists at that path " +
                         "anywhere in the project. Create it under $servedHint, or remove the reference from the HTML. " +
                         "Adding content elsewhere will not make this request succeed.")
            }
        } catch {
            $out += $msg   # fail-soft: never lose a finding to enrichment
        }
    }
    return $out
}

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
        [string]$WorkDir = '',
        # #1171: passed straight through to capture-app.ps1 -> check-design-structural.ps1.
        [string]$DeclaredSurface = ''
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
        return _FailResult "capture-app.ps1 not found at '$captureScript'" '' $layoutResult
    }

    $captureLines = $null
    $captureExit = 0
    try {
        $captureLines = @(& $captureScript -AppDir $AppDir -OutPng $pngPath -DeclaredSurface $DeclaredSurface 2>&1)
        $captureExit = $LASTEXITCODE
    } catch {
        return _FailResult "capture-app.ps1 threw: $($_.Exception.Message)" '' $layoutResult
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
        # #1198: on this floor the pixel lint never runs -- there is no screenshot by construction. The
        # feedback line above says so in prose, but prose beside a field is not the field: a consumer
        # reading PixelMeasured must get the fact, not a $true left over from a default.
        $merged = Merge-DesignSignals -LayoutHard $layoutResult.Hard -LayoutMessages $layoutResult.Messages `
            -LayoutMeasured $layoutResult.Measured -LayoutDetail $layoutResult.Detail -LayoutStatus $layoutResult.Status `
            -LayoutUnparsed $layoutResult.Unparsed `
            -PixelMeasured $false -PixelStatus 'not-applicable' `
            -PixelDetail 'no screenshot was captured (Tier 3 structural floor), so there was nothing to examine' `
            -VlmOk $false -VlmNeedsWork $false -VlmShouldIterate $false -VlmFeedback $vlmFeedback `
            -Iteration $Iteration -MaxIter $MaxIter
        return @{
            ShouldIterate  = $merged.ShouldIterate   # driven by the layout gate alone here
            NeedsWork      = $merged.NeedsWork
            Feedback       = $merged.Feedback
            CaptureTier    = 'structural'
            Ok             = $false
            LayoutHard     = $merged.LayoutHard
            LayoutMeasured = $merged.LayoutMeasured
            LayoutStatus   = "$($layoutResult.Status)"
            PixelMeasured  = $merged.PixelMeasured
            PixelStatus    = 'not-applicable'
            LintsMeasured  = $merged.LintsMeasured
            Caveats        = $merged.Caveats
            CaveatText     = $merged.CaveatText
            ScreenshotPath = ''
        }
    }

    # ---- Step 3: CAPTURE-FAIL or bad exit --------------------------------
    if ($captureExit -ne 0 -or -not ($captureSignal -match '^CAPTURE-OK:')) {
        $detail = if ($captureSignal) { $captureSignal } else { "exit $captureExit" }
        return _FailResult "Capture failed: $detail" '' $layoutResult
    }

    # Parse the capture tier (tier=1 or tier=2) from CAPTURE-OK line.
    $captureTier = '?'
    if ($captureSignal -match 'tier=(\d+)') { $captureTier = $Matches[1] }

    # Verify the PNG exists on disk.
    if (-not (Test-Path $pngPath) -or (Get-Item $pngPath).Length -eq 0) {
        return _FailResult "Capture reported OK but PNG is missing or empty at '$pngPath'" $captureTier $layoutResult
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
    # #1133: turn a raw "Failed to load resource" into a diagnosis the coder can act on.
    # The loop previously received the browser's own wording and responded by EDITING the
    # very file that was 404ing. Fail-soft — on any trouble the original message stands.
    if ($runtimeResult.Messages -and $runtimeResult.Messages.Count -gt 0) {
        $runtimeResult.Messages = Resolve-UnservedAssetFindings `
            -Messages $runtimeResult.Messages -AppDir $AppDir
    }

    # ---- Step 4: VLM critique -------------------------------------------
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) {
        return _FailResult "BlarAI python not found at '$pythonExe'. Is BlarAiRepo correct?" $captureTier $layoutResult $pixelResult
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
        return _FailResult "VLM critique threw: $($_.Exception.Message)" $captureTier $layoutResult $pixelResult
    }

    if ($critiqueExit -ne 0) {
        $detail = ($critiqueLines | Select-Object -Last 3) -join ' | '
        return _FailResult "VLM critique exited $critiqueExit (usage error): $detail" $captureTier $layoutResult $pixelResult
    }

    # Find the JSON line (the CLI prints exactly ONE JSON line to stdout).
    $jsonLine = ($critiqueLines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1) ?? ''
    if (-not $jsonLine) {
        $detail = ($critiqueLines | Where-Object { $_ } | Select-Object -Last 3) -join ' | '
        return _FailResult "VLM critique produced no JSON line (stdout: $detail)" $captureTier $layoutResult $pixelResult
    }

    $critiqueObj = $null
    try { $critiqueObj = $jsonLine | ConvertFrom-Json } catch {
        return _FailResult "VLM critique JSON parse failed ('$jsonLine'): $($_.Exception.Message)" $captureTier $layoutResult $pixelResult
    }

    # Extract and type-coerce fields (ConvertFrom-Json gives PSCustomObject).
    $ok            = [bool]($critiqueObj.ok)
    $needsWork     = [bool]($critiqueObj.needs_work)
    $feedback      = [string]($critiqueObj.feedback ?? '')
    $shouldIterate = [bool]($critiqueObj.should_iterate)

    # Combine the soft VLM signal with the HARD deterministic gates: a layout (Lever A), pixel
    # (Lever B), or browser-RUNTIME (Lever D, #823) defect forces a FIX even when the VLM passed
    # (the false-pass fix). Runtime findings LEAD the merged feedback (fix the thrown error first).
    # #1198: each lint's MEASURED-ness travels beside its HARD signal. A lint that produced no verdict adds
    # no hard finding (it has none) and no coder feedback (it has nothing actionable) -- it adds a caveat
    # the operator-facing report must print, so an unexamined axis can never read as an examined-clean one.
    $merged = Merge-DesignSignals -LayoutHard $layoutResult.Hard -LayoutMessages $layoutResult.Messages `
        -LayoutMeasured $layoutResult.Measured -LayoutDetail $layoutResult.Detail -LayoutStatus $layoutResult.Status `
        -LayoutUnparsed $layoutResult.Unparsed `
        -PixelHard $pixelResult.Hard -PixelMessages $pixelResult.Messages `
        -PixelMeasured $pixelResult.Measured -PixelDetail $pixelResult.Detail -PixelStatus $pixelResult.Status `
        -RuntimeHard $runtimeResult.Hard -RuntimeMessages $runtimeResult.Messages `
        -SmokeDeclared $runtimeResult.SmokeDeclared -SmokeMeasured $runtimeResult.SmokeMeasured `
        -SmokeStatus $runtimeResult.SmokeStatus -SmokePassed $runtimeResult.SmokePassed `
        -SmokeApplicable ([bool]($captureTier -eq 'web')) `
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
        LayoutMeasured  = $merged.LayoutMeasured
        LayoutStatus    = "$($layoutResult.Status)"
        PixelMeasured   = $merged.PixelMeasured
        PixelStatus     = "$($pixelResult.Status)"
        LintsMeasured   = $merged.LintsMeasured
        SmokeDeclared   = $merged.SmokeDeclared
        SmokeMeasured   = $merged.SmokeMeasured
        SmokeStatus     = $merged.SmokeStatus
        SmokePassed     = $merged.SmokePassed
        Caveats         = $merged.Caveats
        CaveatText      = $merged.CaveatText
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

    .PARAMETER SmokePinBytes
      The PLAN's blarai-smoke.json bytes (from Save-SmokeContractPin, taken before the coder ran).
      Re-materialised into the app dir before EVERY pass, so a candidate cannot edit the exam it is
      about to sit -- this loop runs against the CANDIDATE worktree, which the coder has had write
      access to for the whole build, and its fix cycle hands that tree back between passes. Without
      it a candidate that rewrites the contract to something trivially satisfiable gets a clean
      per-task critique, spending its fix budget on nothing and deferring the real finding to the
      smaller post-merge design lap. $null -> no-op (every caller that supplies nothing, and every
      dispatch with no declared contract, is byte-identical).

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
        [scriptblock]$RebuildCallback = $null,
        # #1171: threaded onward to every Invoke-CritiquePass this loop drives.
        [string]$DeclaredSurface = '',
        # The PLAN's blarai-smoke.json bytes, snapshotted by Save-SmokeContractPin before the coder
        # ran. See the .PARAMETER block: re-materialised before EVERY pass, so a candidate cannot
        # edit the exam it is about to sit. $null (the default) is a no-op, so every caller that
        # supplies nothing -- and every dispatch with no contract -- is byte-identical.
        $SmokePinBytes = $null
    )

    $currentAppDir = $AppDir
    $iteration = 0
    $lastResult = $null

    while ($iteration -lt $MaxIter) {
        # BEFORE the capture reads it, never after: the coder has had write access to this tree for
        # the whole build, and the fix cycle below hands it back between passes.
        Restore-SmokeContractPin -Worktree $currentAppDir -PinBytes $SmokePinBytes
        $result = Invoke-CritiquePass `
            -AppDir $currentAppDir `
            -Goal $Goal `
            -VisualCriteriaJson $VisualCriteriaJson `
            -BlarAiRepo $BlarAiRepo `
            -Iteration $iteration `
            -MaxIter $MaxIter `
            -WorkDir $WorkDir `
            -DeclaredSurface $DeclaredSurface

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
        -WorkDir $WorkDir `
        -DeclaredSurface $DeclaredSurface
    $result | ConvertTo-Json -Depth 3
}
