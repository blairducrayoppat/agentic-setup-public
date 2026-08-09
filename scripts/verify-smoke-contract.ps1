#requires -Version 7.0
<#
.SYNOPSIS
  Verify the BEHAVIOR-CONTRACT seam: Add-SmokeContractHint (the coder is TOLD),
  Read-ConsoleSidecar / Format-SmokeContractCaveat (the run reports honestly what it exercised),
  and Save-/Restore-SmokeContractPin (a candidate cannot edit the exam it is about to sit).

.DESCRIPTION
  capture-web-cdp.mjs has always been able to read a declared behavior spec from
  <app-dir>/blarai-smoke.json -- and until BlarAI's plan gained a writer for it, NOTHING wrote that
  file. Every web build fell through to the heuristic ("first visible enabled control"), whose
  failures are only a soft note. Built-but-wired-into-nothing.

  Two halves, and this suite proves both:
    * TOLD  -- Add-SmokeContractHint reads the contract FROM THE FILE (never a literal) and puts the
               two markers in the coder's prompt, gated on actual file presence so a dispatch with
               no contract is a byte-identical no-op.
    * SAID  -- Read-ConsoleSidecar and Format-SmokeContractCaveat keep "the declared check ran and
               passed" apart from "nothing was declared, so a guess was made". Those two read
               identically in a green report, and only the second was ever possible before.

    * PINNED -- the plan's contract bytes are re-materialised before EVERY per-task critique pass,
               so a candidate that rewrites blarai-smoke.json cannot make its own critique report
               `honoured` on a contract the capture never exercised.

  Mutation-resistant: each [kill] case fails a specific wrong implementation. In particular the
  OFF cases are as deliberate as the ON cases -- a control that is not tested OFF cannot be
  distinguished from one the test cannot reach.

  PS 7 ONLY, and MEASURED rather than assumed: this suite dot-sources critique-loop.ps1, which uses
  the PS7 null-coalescing operator `??` (three sites). Under Windows PowerShell 5.1 that file does
  not PARSE, so a `#requires -Version 5.1` here would let the script start and then die on a parse
  error pointing at a file the operator did not run. Exit 0 if all passed, 1 otherwise.
  Run: pwsh -NoProfile -File .\verify-smoke-contract.ps1
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"
# critique-loop.ps1 has a mandatory param block; dot-source it with placeholders to bind it (the
# same pattern new-agent-task.ps1 and swap_ops use).
. "$PSScriptRoot\critique-loop.ps1" -AppDir 'x' -Goal 'x' -VisualCriteriaJson '[]' -BlarAiRepo 'x' 2>$null

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Contains($Haystack, $Needle, $Msg) { if ([string]$Haystack -like "*$Needle*") { _pass $Msg } else { _fail "$Msg (expected to contain '$Needle')" } }
function Assert-NotContains($Haystack, $Needle, $Msg) { if ([string]$Haystack -notlike "*$Needle*") { _pass $Msg } else { _fail "$Msg (expected NOT to contain '$Needle')" } }

$root = Join-Path ([System.IO.Path]::GetTempPath()) 'verify-smoke-contract'
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path $root | Out-Null
function New-Wt($name) {
    $p = Join-Path $root $name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}
function Set-Contract($wt, $json) {
    Set-Content -LiteralPath (Join-Path $wt 'blarai-smoke.json') -Value $json -Encoding UTF8
}
function New-Sidecar($name, $obj) {
    $p = Join-Path $root "$name.console.json"
    Set-Content -LiteralPath $p -Value ($obj | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
    return $p
}

$P = 'ORIGINAL PROMPT'
$CONTRACT = @'
{
  "actionLabel": "the Calculate button",
  "click": "[data-blarai-action=\"primary\"]",
  "expectDelta": "[data-blarai-result=\"primary\"]",
  "resultLabel": "the total below the form"
}
'@

# ===========================================================================
Section 'OFF: no contract declared -> a byte-identical no-op'
# The absence direction. Before the writer existed this was the ONLY reachable state, so it is what
# every prior web build did; nothing here may change for those.
Assert-Eq $P (Add-SmokeContractHint -Prompt $P -Worktree '')                   'SC1 empty worktree -> prompt unchanged'
Assert-Eq $P (Add-SmokeContractHint -Prompt $P -Worktree (Join-Path $root 'nope')) 'SC2 missing worktree -> prompt unchanged'
$wtNone = New-Wt 'none'
Assert-Eq $P (Add-SmokeContractHint -Prompt $P -Worktree $wtNone)              'SC3 worktree with no contract file -> prompt unchanged'

Section 'OFF: a malformed contract is a no-op, never a half-instruction'
$wtBad = New-Wt 'bad'; Set-Contract $wtBad '{ not json'
Assert-Eq $P (Add-SmokeContractHint -Prompt $P -Worktree $wtBad)               'SC4 unreadable JSON -> no-op (fail-soft, never throws)'
$wtHalf = New-Wt 'half'; Set-Contract $wtHalf '{"click": "#go"}'
Assert-Eq $P (Add-SmokeContractHint -Prompt $P -Worktree $wtHalf)              'SC5 [kill] half a contract (no expectDelta) -> no-op, NOT a partial instruction'
$wtEmpty = New-Wt 'emptyc'; Set-Contract $wtEmpty '{}'
Assert-Eq $P (Add-SmokeContractHint -Prompt $P -Worktree $wtEmpty)             'SC6 empty object -> no-op'

# ===========================================================================
Section 'ON: a declared contract reaches the coder, read FROM THE FILE'
$wtOk = New-Wt 'ok'; Set-Contract $wtOk $CONTRACT
$h = Add-SmokeContractHint -Prompt $P -Worktree $wtOk
Assert-True ($h.StartsWith($P))                          'SC7 original prompt preserved verbatim (appended, never replaced)'
Assert-Contains $h 'data-blarai-action="primary"'        'SC8 the ACTION selector reaches the coder'
Assert-Contains $h 'data-blarai-result="primary"'        'SC9 the RESULT selector reaches the coder'
Assert-Contains $h 'the Calculate button'                'SC10 the plain-language action label reaches the coder'
Assert-Contains $h 'the total below the form'            'SC11 the plain-language result label reaches the coder'
Assert-Contains $h 'FAILURE'                             'SC12 the coder is told the consequence of not complying'
Assert-Contains $h 'do NOT fake the change'              'SC13 the coder is told not to satisfy the marker cosmetically'

Section 'ON: the selectors come from the FILE, so the two sides cannot drift'
# [kill] an implementation that hardcodes the data-blarai-* literals in the hint would pass every
# check above and still ship a hint that disagrees with a future contract. Feed it a DIFFERENT
# contract: the hint must follow the file.
$wtAlt = New-Wt 'alt'
Set-Contract $wtAlt '{"click": "#send-it", "expectDelta": ".answer", "actionLabel": "the Send button", "resultLabel": "the answer box"}'
$hAlt = Add-SmokeContractHint -Prompt $P -Worktree $wtAlt
Assert-Contains $hAlt '#send-it'                         'SC14 [kill] the hint uses the FILE selector, not a hardcoded literal'
Assert-Contains $hAlt '.answer'                          'SC15 [kill] the hint uses the FILE delta selector'
Assert-NotContains $hAlt 'data-blarai-action'            'SC16 [kill] no stale selector from another contract leaks in (a fixed worked example would)'
Assert-Contains $hAlt 'id="send-it"'                     'SC17 the worked example is DERIVED from this contract (#id form)'
# ...and the attribute form derives its own example rather than reusing the id one.
Assert-Contains $h 'data-blarai-action="primary"'        'SC18 the worked example derives the attribute form too'
Assert-NotContains $h 'id="'                             'SC19 [kill] the id example does not leak into an attribute contract'

Section 'ON: missing labels degrade to wording, never to a broken instruction'
$wtNoLbl = New-Wt 'nolabel'; Set-Contract $wtNoLbl '{"click": "#go", "expectDelta": "#out"}'
$hNoLbl = Add-SmokeContractHint -Prompt $P -Worktree $wtNoLbl
Assert-Contains $hNoLbl '#go'                            'SC20 a label-less contract still delivers the selectors'
Assert-Contains $hNoLbl 'the main control'               'SC21 a missing label falls back to generic wording'

# ===========================================================================
Section 'Read-ConsoleSidecar: the contract honesty fields'
# The collapse being prevented: "the declared check ran and passed" and "nothing was declared so a
# guess was made" read identically in a green report. These must be distinguishable.
$sHon = New-Sidecar 'honoured' @{ captured = $true; hard = $false; findings = @(); notes = @()
                                  smoke = @{ declared = $true; measured = $true; status = 'honoured' } }
$rHon = Read-ConsoleSidecar -SidecarPath $sHon
Assert-True  $rHon.Captured                              'SC22 a captured sidecar is read'
Assert-True  $rHon.SmokeDeclared                         'SC23 a declared contract is reported as declared'
Assert-True  $rHon.SmokeMeasured                         'SC24 an exercised contract is reported as measured'
Assert-Eq    'honoured' $rHon.SmokeStatus                 'SC25 the status is carried through'

$sNone = New-Sidecar 'undeclared' @{ captured = $true; hard = $false; findings = @(); notes = @()
                                     smoke = @{ declared = $false; measured = $false; status = 'not-declared' } }
$rNone = Read-ConsoleSidecar -SidecarPath $sNone
Assert-False $rNone.SmokeDeclared                        'SC26 [kill] a heuristic run does NOT claim a declared contract'
Assert-False $rNone.SmokeMeasured                        'SC27 [kill] a heuristic run does NOT claim a measurement'
Assert-Eq    'not-declared' $rNone.SmokeStatus            'SC28 the heuristic run says so'

$sMiss = New-Sidecar 'hookmissing' @{ captured = $true; hard = $true; findings = @('Behavior smoke: the Calculate button is missing its required marker'); notes = @()
                                      smoke = @{ declared = $true; measured = $false; status = 'action-hook-missing' } }
$rMiss = Read-ConsoleSidecar -SidecarPath $sMiss
Assert-True  $rMiss.SmokeDeclared                        'SC29 a declared-but-unmet contract is still DECLARED'
Assert-False $rMiss.SmokeMeasured                        'SC30 [kill] a declared-but-unmet contract was NOT measured'
Assert-True  $rMiss.Hard                                 'SC31 the unmet contract forces a fix (hard)'

Section 'Read-ConsoleSidecar: a blind capture claims NOTHING about the contract'
# A legacy helper writes no `smoke` block; a missing/uncaptured sidecar reports no capture at all.
# Neither may assert "nothing was declared" -- that is a fact about the PLAN they never saw.
$sLegacy = New-Sidecar 'legacy' @{ captured = $true; hard = $false; findings = @() }
$rLegacy = Read-ConsoleSidecar -SidecarPath $sLegacy
Assert-False $rLegacy.SmokeDeclared                      'SC32 a legacy sidecar claims no contract'
Assert-False $rLegacy.SmokeMeasured                      'SC33 a legacy sidecar claims no measurement'
Assert-Eq 'unavailable' $rLegacy.SmokeStatus             'SC34 [kill] a legacy sidecar reports unavailable, NOT not-declared'
$rGone = Read-ConsoleSidecar -SidecarPath (Join-Path $root 'no-such.console.json')
Assert-Eq 'unavailable' $rGone.SmokeStatus               'SC35 an absent sidecar reports unavailable'
$sUncap = New-Sidecar 'uncaptured' @{ captured = $false; error = 'msedge fallback' }
Assert-Eq 'unavailable' (Read-ConsoleSidecar -SidecarPath $sUncap).SmokeStatus 'SC36 a captured:false sidecar reports unavailable'

# ===========================================================================
Section 'Format-SmokeContractCaveat: silence ONLY for declared-and-exercised'
Assert-Eq '' (Format-SmokeContractCaveat -Declared $true -Measured $true -Status 'honoured') 'SC37 declared + measured -> silent'
Assert-Eq '' (Format-SmokeContractCaveat)                                                    'SC38 inert default (every pre-contract caller) -> silent'
$cNone = Format-SmokeContractCaveat -Declared $false -Measured $false -Status 'not-declared'
Assert-Contains $cNone 'GUESSED'                         'SC39 [kill] "no contract" is NOT silence -- it names the guess'
Assert-Contains $cNone 'UNEXAMINED'                      'SC40 the undeclared case is reported as absent, not clean'
$cBroken = Format-SmokeContractCaveat -Declared $false -Measured $false -Status 'invalid-selector'
Assert-Contains $cBroken 'DID NOT RUN'                   'SC41 a present-but-unusable contract is reported loudly'
$cUnavail = Format-SmokeContractCaveat -Declared $false -Measured $false -Status 'unavailable'
Assert-Contains $cUnavail 'UNKNOWN'                      'SC42 a blind capture reports unknown, never clean'
$cUnmet = Format-SmokeContractCaveat -Declared $true -Measured $false -Status 'action-hook-missing'
Assert-Contains $cUnmet 'missing the markers'            'SC43 a declared-but-unmet contract names the reach'

Section 'Format-SmokeContractCaveat: NOT-APPLICABLE surfaces stay silent'
# This caveat feeds Get-DesignCritiqueNote, which withholds the CLEAN BILL whenever ANY caveat is
# present. So a caveat that fires where it cannot apply is not a harmless extra line -- it
# downgrades a correct verdict on every WinUI/desktop dispatch, which has no browser behavior smoke
# by construction. Same shape as #1140's "a project with no XAML is not an unexamined layout".
Assert-Eq '' (Format-SmokeContractCaveat -Declared $false -Measured $false -Status 'unavailable' -Applicable $false)  'SC44 [kill] a non-web capture is SILENT, not "unexamined"'
Assert-Eq '' (Format-SmokeContractCaveat -Declared $false -Measured $false -Status 'not-declared' -Applicable $false) 'SC45 [kill] not-applicable beats not-declared'
Assert-True ((Format-SmokeContractCaveat -Declared $false -Measured $false -Status 'unavailable' -Applicable $true) -ne '') 'SC46 [kill] the WEB tier still reports the absence (the gate is not stuck off)'
# ...and the WIRING: applicability comes from the capture TIER, a fact the caller already holds.
# Without this the parameter could sit at its inert default forever and nothing would notice.
# .Contains, NOT Assert-Contains: -like reads the [bool] brackets as a wildcard character class,
# so the -like form silently never matches and the check would pass for the wrong reason.
$critiqueSrc = Get-Content "$PSScriptRoot\critique-loop.ps1" -Raw
Assert-True ($critiqueSrc.Contains("-SmokeApplicable ([bool](`$captureTier -eq 'web'))")) 'SC47 [kill] applicability is wired to the web capture tier, not left at its default'
$mNonWeb = Merge-DesignSignals -Iteration 0 -MaxIter 3 -SmokeDeclared $false -SmokeMeasured $false -SmokeStatus 'unavailable' -SmokeApplicable $false
Assert-Eq 0 ($mNonWeb.Caveats.Count)                     'SC48 [kill] Merge-DesignSignals adds no contract caveat on a non-web surface'

Section 'Merge-DesignSignals: the contract REPORTS, it never DECIDES'
# The caveat channel must not touch ShouldIterate/NeedsWork/Feedback: "no contract was declared" is
# not something the coder can fix, and forcing a lap on it would spend the iteration budget on
# nothing. Same discipline the #1198 lint caveats already carry.
$mOff = Merge-DesignSignals -Iteration 0 -MaxIter 3
$mOn  = Merge-DesignSignals -Iteration 0 -MaxIter 3 -SmokeDeclared $false -SmokeMeasured $false -SmokeStatus 'not-declared'
Assert-Eq $mOff.ShouldIterate $mOn.ShouldIterate         'SC49 [kill] a contract caveat does not change ShouldIterate'
Assert-Eq $mOff.NeedsWork     $mOn.NeedsWork             'SC50 [kill] a contract caveat does not change NeedsWork'
Assert-Eq $mOff.Feedback      $mOn.Feedback              'SC51 [kill] a contract caveat never enters the coder FIX prompt'
Assert-True ($mOn.CaveatText -like '*BEHAVIOR CONTRACT*') 'SC52 it rides the operator caveat channel instead'
Assert-Eq 0 ($mOff.Caveats.Count)                        'SC53 the inert default adds no caveat (pre-contract callers byte-identical)'
$mMet = Merge-DesignSignals -Iteration 0 -MaxIter 3 -SmokeDeclared $true -SmokeMeasured $true -SmokeStatus 'honoured'
Assert-Eq 0 ($mMet.Caveats.Count)                        'SC54 a fully honoured contract adds no caveat'
Assert-True $mMet.SmokeMeasured                          'SC55 the merged result carries the measured-ness onward'
Assert-Eq 'honoured' $mMet.SmokeStatus                   'SC56 the merged result carries the status onward'

Section 'Format-SmokeContractCaveat: a CAPTURE crash is not a DELIVERY defect'
# The declared-but-unmeasured branch used to be one sentence for every status, asserting two things
# about all of them: that the delivery is missing its markers, and that "the finding itself is in the
# fix feedback above". Both are true for the *-hook-missing statuses (behaviorHard is set, so the
# capture DID raise a hard finding) and both are FALSE for 'unavailable', which capture-web-cdp.mjs
# emits when the evaluate block THREW after reading a valid spec: behavior.ran is false, behaviorHard
# is false, no finding was raised and no note was pushed. Pointing a reader at feedback that is not
# there is worse than a wrong diagnosis -- they read its absence as "nothing serious".
$cCrash = Format-SmokeContractCaveat -Declared $true -Measured $false -Status 'unavailable'
Assert-True ($cCrash -ne '')                             'SC57 a declared contract the capture crashed on is still reported'
Assert-Contains    $cCrash 'CAPTURE failure'             'SC58 [kill] a capture crash is named as a capture crash'
Assert-Contains    $cCrash 'UNEXAMINED'                  'SC59 it is still an ABSENT measurement, not a clean one'
Assert-NotContains $cCrash 'missing the markers'         'SC60 [kill] the delivery is not blamed for a crash in the capture'
Assert-NotContains $cCrash 'fix feedback above'          'SC61 [kill] no finding is promised where none was raised'
# A status this side does not recognise (the JS half renamed a constant, a legacy producer): the
# DISCLOSURE still holds, so it is made -- but no cause is asserted and no upstream finding promised.
# Same distinction swap_ops.smoke_contract_disposition draws on the BlarAI side.
$cUnknown = Format-SmokeContractCaveat -Declared $true -Measured $false -Status 'some-future-status'
Assert-Contains    $cUnknown 'UNEXAMINED'                'SC62 [kill] an unrecognised status still discloses that a contract went ungraded'
Assert-Contains    $cUnknown 'some-future-status'        'SC63 the unrecognised status is carried verbatim, not swallowed'
Assert-NotContains $cUnknown 'missing the markers'       'SC64 [kill] no cause is asserted for a status this side cannot read'
Assert-NotContains $cUnknown 'fix feedback above'        'SC65 [kill] no finding is promised for a status this side cannot read'
# ...and the hook-missing wording is unchanged, so the split did not just rename everything.
Assert-Contains $cUnmet 'fix feedback above'             'SC66 the DELIVERY-defect branch still points at its real finding'

# ===========================================================================
Section 'THE EXAM PIN: a candidate cannot edit the contract it is about to be graded on'
# The seeded contract sits in the tree the coder writes to for the whole build. The swap driver pins
# the plan's bytes before its two POST-MERGE captures; the PER-TASK critique hop -- which runs
# against the candidate worktree, with its own fix cycle -- was outside that pin. A candidate that
# rewrote the contract to {"click":"body","expectDelta":"body"} got a clean per-task critique on a
# contract that was never exercised: not a false GREEN at run level, but a false CLEAN at the hop
# that spends its fix budget, deferring the real finding into the smaller design-lap budget.
$wtPin = New-Wt 'pin'; Set-Contract $wtPin $CONTRACT
$pinBytes = Save-SmokeContractPin -Worktree $wtPin
Assert-True ($null -ne $pinBytes)                        'SC67 the plan bytes are snapshotted before the coder ever runs'
Assert-Eq $null (Save-SmokeContractPin -Worktree $wtNone) 'SC68 no contract -> no pin (every non-web dispatch stays byte-identical)'
Assert-Eq $null (Save-SmokeContractPin -Worktree '')      'SC69 an empty worktree -> no pin, no throw'

# ON: the tamper is undone.
Set-Contract $wtPin '{"click":"body","expectDelta":"body","actionLabel":"x","resultLabel":"y"}'
Restore-SmokeContractPin -Worktree $wtPin -PinBytes $pinBytes
$restored = Get-Content -LiteralPath (Join-Path $wtPin 'blarai-smoke.json') -Raw
Assert-Contains    $restored 'data-blarai-action'        'SC70 [kill] a tampered contract is RESTORED to the plan bytes'
Assert-NotContains $restored '"body"'                    'SC71 [kill] the candidate substitute does not survive to the capture'

# OFF: on an untampered tree the restore is a byte-for-byte no-op, so it leaves no spurious diff.
$wtClean = New-Wt 'pinclean'; Set-Contract $wtClean $CONTRACT
$cleanPin = Save-SmokeContractPin -Worktree $wtClean
$beforeBytes = [System.IO.File]::ReadAllBytes((Join-Path $wtClean 'blarai-smoke.json'))
Restore-SmokeContractPin -Worktree $wtClean -PinBytes $cleanPin
$afterBytes = [System.IO.File]::ReadAllBytes((Join-Path $wtClean 'blarai-smoke.json'))
Assert-Eq ([Convert]::ToBase64String($beforeBytes)) ([Convert]::ToBase64String($afterBytes)) 'SC72 an untampered tree is byte-identical after the restore'
# OFF: a $null pin never writes -- a dispatch with no contract must not grow a contract file.
$wtNoPin = New-Wt 'pinnone'
Restore-SmokeContractPin -Worktree $wtNoPin -PinBytes $null
Assert-False (Test-Path -LiteralPath (Join-Path $wtNoPin 'blarai-smoke.json')) 'SC73 [kill] a null pin writes NOTHING (absence stays legal)'
Restore-SmokeContractPin -Worktree (Join-Path $root 'nope') -PinBytes $pinBytes
_pass 'SC74 restoring into a missing worktree is fail-soft (never throws)'

Section 'THE EXAM PIN: re-applied before EVERY pass, not once at loop entry'
# THE SEAM, driven through the REAL Invoke-CritiqueLoop with a stubbed pass. Pinning once at entry
# would cover only the first capture -- the fix cycle hands the tree back to the coder between
# passes, which is the same reason the design lap re-pins. This is the reachability half: a control
# that exists but is called in the wrong place is the built-but-wired-into-nothing shape.
$wtLoop = New-Wt 'pinloop'; Set-Contract $wtLoop $CONTRACT
$loopPin = Save-SmokeContractPin -Worktree $wtLoop
$script:seenAtPass = New-Object System.Collections.ArrayList
function Invoke-CritiquePass {
    # Records what the contract file said AT THE MOMENT the capture would have read it.
    param($AppDir, $Goal, $VisualCriteriaJson, $BlarAiRepo, $Iteration, $MaxIter, $WorkDir, $DeclaredSurface)
    [void]$script:seenAtPass.Add((Get-Content -LiteralPath (Join-Path $AppDir 'blarai-smoke.json') -Raw))
    return @{ ShouldIterate = ($Iteration -lt 1); Feedback = 'fix it'; CaptureTier = 'web' }
}
# The rebuild callback tampers, exactly as a coder with write access to the tree would.
$tamper = { param($Feedback, $AppDir)
    Set-Content -LiteralPath (Join-Path $AppDir 'blarai-smoke.json') `
        -Value '{"click":"body","expectDelta":"body","actionLabel":"x","resultLabel":"y"}' -Encoding UTF8
    return $AppDir }
$null = Invoke-CritiqueLoop -AppDir $wtLoop -Goal 'g' -VisualCriteriaJson '[]' -BlarAiRepo 'x' `
    -MaxIter 3 -WorkDir $root -RebuildCallback $tamper -SmokePinBytes $loopPin
Assert-Eq 2 $script:seenAtPass.Count                     'SC75 the stubbed loop ran the two passes the fix cycle asks for'
Assert-Contains $script:seenAtPass[0] 'data-blarai-action' 'SC76 pass 1 graded the PLAN contract'
Assert-Contains $script:seenAtPass[1] 'data-blarai-action' 'SC77 [kill] pass 2 graded the PLAN contract too -- the tamper between passes did not survive'
Assert-NotContains $script:seenAtPass[1] '"body"'          'SC78 [kill] the fix cycle cannot hand the capture a rewritten exam'

# OFF: with no pin the loop is byte-identical to before this control existed -- the tamper stands.
$script:seenAtPass = New-Object System.Collections.ArrayList
$wtOffPin = New-Wt 'pinoff'; Set-Contract $wtOffPin $CONTRACT
$null = Invoke-CritiqueLoop -AppDir $wtOffPin -Goal 'g' -VisualCriteriaJson '[]' -BlarAiRepo 'x' `
    -MaxIter 3 -WorkDir $root -RebuildCallback $tamper
Assert-Contains $script:seenAtPass[1] '"body"'           'SC79 [kill] the OFF direction: no pin -> the tamper survives, so SC77 proves the control and not the harness'
Remove-Item -LiteralPath Function:\Invoke-CritiquePass -ErrorAction SilentlyContinue

Section 'THE EXAM PIN: the WIRING, so the parameter cannot sit unused forever'
# Same discipline as SC47: without these, Save-SmokeContractPin could be defined and never called,
# or the loop could be handed $null forever, and every behavioural check above would still pass.
# .Contains, NOT Assert-Contains: -like reads the bracket forms as wildcard character classes.
$natSrc = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
Assert-True ($natSrc.Contains('$smokePinBytes = Save-SmokeContractPin -Worktree $wt')) 'SC80 [kill] the pin is taken in new-agent-task.ps1, at the seeded worktree'
Assert-True ($natSrc.Contains('-SmokePinBytes $smokePinBytes'))                        'SC81 [kill] the pin is threaded into the per-task critique loop'
# ...and it is taken BEFORE the build, which is the only moment the bytes are still the plan's.
$pinAt = $natSrc.IndexOf('Save-SmokeContractPin')
$buildAt = $natSrc.IndexOf('$BuildTestVerify = {')
Assert-True (($pinAt -gt 0) -and ($buildAt -gt 0) -and ($pinAt -lt $buildAt)) 'SC82 [kill] the snapshot is taken BEFORE the coder gets write access to the tree'
$clSrc = Get-Content "$PSScriptRoot\critique-loop.ps1" -Raw
$restoreAt = $clSrc.IndexOf('Restore-SmokeContractPin -Worktree $currentAppDir')
$passAt = $clSrc.IndexOf('$result = Invoke-CritiquePass')
Assert-True (($restoreAt -gt 0) -and ($passAt -gt 0) -and ($restoreAt -lt $passAt)) 'SC83 [kill] the restore runs BEFORE the pass reads the file, inside the loop body'

# ===========================================================================
Section 'THE VERDICT: did the declared contract PASS, not merely RUN'
# Declared/Measured/Status answer "did the declared check RUN". None of them answers "did it PASS",
# and the sidecar's aggregate `hard` cannot be asked: it is also raised by a console error, an
# uncaught exception and an undefined/NaN text leak. So a delivery whose declared behaviour FAILED
# read, at the RESULT line, exactly like one that succeeded -- observed live 2026-08-06 (fleet run
# 20260806-171303-bd, job create-habit-tracking: the declared result region did not change when the
# declared control was used, three fix passes then failed, and the report's last line still said
# "MERGED into your project - just open the app and try it").
$sPass = New-Sidecar 'contract-passed' @{ captured = $true; hard = $false; behaviorHard = $false; findings = @(); notes = @()
                                          smoke = @{ declared = $true; measured = $true; status = 'honoured' } }
Assert-True  (Read-ConsoleSidecar -SidecarPath $sPass).SmokePassed  'SC84 a declared contract that was exercised and worked is reported as PASSED'
$sFail = New-Sidecar 'contract-failed' @{ captured = $true; hard = $true; behaviorHard = $true
                                          findings = @('Behavior smoke: the result region did not change'); notes = @()
                                          smoke = @{ declared = $true; measured = $true; status = 'honoured' } }
$rFail = Read-ConsoleSidecar -SidecarPath $sFail
Assert-True  $rFail.SmokeMeasured                        'SC85 the failing contract WAS exercised (measured), which is why the other three fields read clean'
Assert-False $rFail.SmokePassed                          'SC86 [kill] ...and it did NOT pass -- the one field that separates the two'
# THE FIELD, not the aggregate. An implementation lifting $obj.hard passes SC86 and then reports a
# page that merely logged a console error as a FAILED CONTRACT -- a defect invented on the operator.
$sNoisy = New-Sidecar 'contract-passed-noisy-page' @{ captured = $true; hard = $true; behaviorHard = $false
                                                      findings = @('Console error: Failed to load resource'); notes = @()
                                                      smoke = @{ declared = $true; measured = $true; status = 'honoured' } }
Assert-True  (Read-ConsoleSidecar -SidecarPath $sNoisy).SmokePassed 'SC87 [kill] a console error does NOT read as a failed contract (behaviorHard, not the aggregate hard)'
# FAIL-CLOSED. A verdict that was never stated is not a pass, and a surface that has no browser
# behaviour smoke at all affirms nothing -- $false is the safe reading on every one of them.
$sMute = New-Sidecar 'verdict-unstated' @{ captured = $true; hard = $false; findings = @(); notes = @()
                                           smoke = @{ declared = $true; measured = $true; status = 'honoured' } }
Assert-False (Read-ConsoleSidecar -SidecarPath $sMute).SmokePassed  'SC88 [kill] a producer that never wrote the verdict does NOT resolve to passed'
Assert-False $rLegacy.SmokePassed                        'SC89 [kill] a legacy sidecar affirms no pass'
Assert-False $rGone.SmokePassed                          'SC90 [kill] an absent sidecar affirms no pass'
$sCrash = New-Sidecar 'capture-crashed' @{ captured = $true; hard = $false; behaviorHard = $false; findings = @(); notes = @()
                                           smoke = @{ declared = $true; measured = $false; status = 'unavailable' } }
Assert-False (Read-ConsoleSidecar -SidecarPath $sCrash).SmokePassed 'SC91 [kill] a contract the capture never exercised is not a pass either (BOTH halves are required)'

Section 'Merge-DesignSignals: the verdict REPORTS, it never DECIDES'
# Identical discipline to SC49-SC53. A failed declared contract already forced its fix laps through
# `hard` at capture time; by the time this is read the laps are spent, and re-deciding on it here
# would spend them twice against a finding the coder has already been handed.
$mFail = Merge-DesignSignals -Iteration 0 -MaxIter 3 -SmokeDeclared $true -SmokeMeasured $true -SmokeStatus 'honoured' -SmokePassed $false
$mPass = Merge-DesignSignals -Iteration 0 -MaxIter 3 -SmokeDeclared $true -SmokeMeasured $true -SmokeStatus 'honoured' -SmokePassed $true
Assert-True  $mPass.SmokePassed                          'SC92 the merged result carries the verdict onward'
Assert-False $mFail.SmokePassed                          'SC93 [kill] ...in both directions'
Assert-Eq $mPass.ShouldIterate $mFail.ShouldIterate      'SC94 [kill] the verdict does not change ShouldIterate'
Assert-Eq $mPass.NeedsWork     $mFail.NeedsWork          'SC95 [kill] the verdict does not change NeedsWork'
Assert-Eq $mPass.Feedback      $mFail.Feedback           'SC96 [kill] the verdict never enters the coder FIX prompt'
Assert-False ([bool]$mOff.SmokePassed)                   'SC97 the inert default affirms nothing (pre-contract callers unchanged)'

Section 'Format-SmokeResultQualifier: the RESULT line stops outranking the instrument'
$qFail = Format-SmokeResultQualifier -Declared $true -Measured $true -Passed $false
Assert-True ($qFail -ne '')                              'SC98 [kill] a declared contract that was exercised and failed QUALIFIES the merged RESULT line'
Assert-Contains $qFail 'did NOT pass'                    'SC99 the qualifier states the verdict plainly'
Assert-Contains $qFail 'try that step first'             'SC100 it tells the operator what to do, not what the harness is'
# The operator is non-technical: no harness vocabulary may reach this line.
Assert-NotContains $qFail 'smoke'                        'SC101 [kill] no harness jargon ("smoke")'
Assert-NotContains $qFail 'selector'                     'SC102 [kill] no harness jargon ("selector")'
Assert-NotContains $qFail 'contract'                     'SC103 [kill] no harness jargon ("contract")'

Section 'Format-SmokeResultQualifier: THE OFF CASES -- silence everywhere else'
# The one that matters most. A HEURISTIC no-delta -- the capture guessing at "the first visible
# enabled control" because nothing was declared -- must stay a soft note forever. Forcing this
# qualifier onto it would stamp a permanent failure notice on every button-less page, on a verdict
# nobody asked for: the #1140 shape, and the same downgrade SC44-SC48 hold the line against. Without
# these the ON cases above prove only that a string can be produced, not that a CONTROL fired.
Assert-Eq '' (Format-SmokeResultQualifier -Declared $false -Measured $false -Passed $false) 'SC104 [kill] a HEURISTIC (undeclared) no-delta stays a soft note -- never a forced caveat'
Assert-Eq '' (Format-SmokeResultQualifier -Declared $true -Measured $true -Passed $true)    'SC105 [kill] a contract that passed says nothing (silence is the clean reading)'
Assert-Eq '' (Format-SmokeResultQualifier -Declared $true -Measured $false -Passed $false)  'SC106 [kill] a contract that never ran, with NO status stated, is silent (the unexercised branch is an allowlist, so an unstated status decides nothing)'
Assert-Eq '' (Format-SmokeResultQualifier)                                                  'SC107 [kill] the inert default is silent (every non-web dispatch byte-identical)'

Section 'THE SEAM: sidecar -> reader -> merge -> RESULT line, driven end to end'
# Each hop is proven above in isolation; a mock-shaped drift between any two of them would still
# ship the defect. These drive the REAL functions over the REAL sidecar bytes.
function Get-QualifierForSidecar($Path) {
    $r = Read-ConsoleSidecar -SidecarPath $Path
    $m = Merge-DesignSignals -Iteration 0 -MaxIter 3 -SmokeDeclared $r.SmokeDeclared `
        -SmokeMeasured $r.SmokeMeasured -SmokeStatus $r.SmokeStatus -SmokePassed $r.SmokePassed
    return (Format-SmokeResultQualifier -Declared $m.SmokeDeclared -Measured $m.SmokeMeasured `
        -Passed $m.SmokePassed -Status $m.SmokeStatus)
}
Assert-True ((Get-QualifierForSidecar $sFail) -ne '')    'SC108 [kill] the LIVE #1303 shape reaches the RESULT line as a qualifier'
Assert-Eq '' (Get-QualifierForSidecar $sPass)            'SC109 [kill] an honoured contract reaches it as silence'
Assert-Eq '' (Get-QualifierForSidecar $sNone)            'SC110 [kill] the heuristic run reaches it as silence'
Assert-Eq '' (Get-QualifierForSidecar $sLegacy)          'SC111 [kill] a legacy sidecar reaches it as silence'

Section 'THE WIRING: the verdict cannot sit unread forever'
# Same discipline as SC47 and SC80-SC83: without these, every behavioural check above still passes
# while the field is never lifted into the loop result and the qualifier is never composed into the
# report -- built-but-wired-into-nothing, the failure mode this whole seam exists to close.
# .Contains, NOT Assert-Contains: -like reads the [bool] brackets as a wildcard character class.
Assert-True ($critiqueSrc.Contains('-SmokePassed $runtimeResult.SmokePassed')) 'SC112 [kill] the capture verdict is lifted out of the sidecar reader into the merge'
Assert-True ($critiqueSrc.Contains('SmokePassed     = $merged.SmokePassed'))   'SC113 [kill] ...and out of the merge into the pass result the loop returns'
Assert-True ($natSrc.Contains('Format-SmokeResultQualifier'))                  'SC114 [kill] new-agent-task.ps1 composes the qualifier from that result'
Assert-True ($natSrc.Contains('})$smokeQualifier"}'))                          'SC115 [kill] ...onto the MERGED branch of the RESULT line, which is the line that was lying'

# ===========================================================================
Section 'DECLARED but never exercisable: the delivery did not build what it was told to'
# The second dishonest state, and the SAME defect as the first. Add-SmokeContractHint TELLS the coder
# to place both markers. A delivery that shipped without them did not build what it was asked for,
# the capture had nothing to press, and the RESULT line still said "just open the app and try it".
# The information was in the critique block; the last line contradicted it. Same overstatement, so
# the same line is qualified -- with a DIFFERENT sentence, because nothing was checked here and
# saying "the check failed" would assert a measurement that never happened.
$qMissA = Format-SmokeResultQualifier -Declared $true -Measured $false -Passed $false -Status 'action-hook-missing'
$qMissR = Format-SmokeResultQualifier -Declared $true -Measured $false -Passed $false -Status 'result-hook-missing'
Assert-True ($qMissA -ne '')                             'SC116 [kill] a missing ACTION marker qualifies the merged RESULT line'
Assert-True ($qMissR -ne '')                             'SC117 [kill] a missing RESULT marker qualifies it too (both hooks, not just the one)'
Assert-Eq $qMissA $qMissR                                'SC118 both hook-missing statuses read the same to the operator (one fact: it is not there)'
Assert-Contains $qMissA 'not on the page'                'SC119 the wording says the part could not be found'
Assert-Contains $qMissA 'never built'                    'SC120 ...and names the likely reason in plain language'
Assert-Contains $qMissA 'actually there'                 'SC121 it tells the operator what to go and check'
# THE DISTINCTION AN OPERATOR HAS TO BE ABLE TO MAKE. "It was checked and did not work" and "it was
# never there to check" are different facts about their product; a shared sentence would erase one.
Assert-NotContains $qMissA 'did NOT pass'                'SC122 [kill] the not-built branch does NOT claim the check failed -- nothing was checked'
Assert-NotContains $qMissA 'try that step first'         'SC123 [kill] ...and does not tell them to try a step that does not exist'
Assert-True ($qMissA -ne $qFail)                         'SC124 [kill] the two states produce DIFFERENT sentences (a shared string would erase the distinction)'
Assert-NotContains $qMissA 'smoke'                       'SC125 [kill] no harness jargon ("smoke") in the new wording either'
Assert-NotContains $qMissA 'selector'                    'SC126 [kill] no harness jargon ("selector")'
Assert-NotContains $qMissA 'contract'                    'SC127 [kill] no harness jargon ("contract")'

Section 'THE LINE THE RULING DREW: a HARNESS crash stays silent, and cannot widen'
# 'unavailable' is what the capture emits when the evaluate block THREW after reading a VALID spec:
# behavior.ran is false, behaviorHard is false, no finding was raised and no note was pushed. It is
# the harness's fault, not the delivery's. It is also Declared + not-Measured, exactly like the
# hook-missing states -- so ONLY the status separates them, and these are the tests that stop a later
# change from quietly widening the branch into blaming the delivery for a crash in the capture
# (the distinction 667ec5f / SC57-SC61 exists to draw). Without them that line is a comment.
Assert-Eq '' (Format-SmokeResultQualifier -Declared $true -Measured $false -Passed $false -Status 'unavailable') 'SC128 [kill] a CAPTURE crash on a valid contract is SILENT at the RESULT line -- harness fault, never the delivery''s'
Assert-Eq '' (Format-SmokeResultQualifier -Declared $true -Measured $false -Passed $false -Status 'some-future-status') 'SC129 [kill] an unrecognised status is silent (ALLOWLIST -- a blocklist would speak for every status it had not heard of)'
Assert-Eq '' (Format-SmokeResultQualifier -Declared $true -Measured $false -Passed $false -Status 'honoured') 'SC130 [kill] a status outside the two-item allowlist cannot leak in, even a benign one'
Assert-Eq '' (Format-SmokeResultQualifier -Declared $false -Measured $false -Passed $false -Status 'action-hook-missing') 'SC131 [kill] an UNDECLARED run cannot reach either branch, whatever its status claims'

Section 'THE SEAM: both new states driven end to end over real sidecar bytes'
Assert-True ((Get-QualifierForSidecar $sMiss) -ne '')    'SC132 [kill] a real hook-missing sidecar reaches the RESULT line as the not-built wording'
Assert-Contains (Get-QualifierForSidecar $sMiss) 'not on the page' 'SC133 [kill] ...as the NOT-BUILT sentence specifically, not the failure one'
Assert-Eq '' (Get-QualifierForSidecar $sCrash)           'SC134 [kill] a real capture-crash sidecar reaches it as SILENCE, over the same two-boolean shape'
# ...and the WIRING for the field that splits them. Without this the status sits at its default ''
# forever, every check above still passes, and the not-built branch is unreachable in production.
Assert-True ($natSrc.Contains("-Status ([string]`$_fr['SmokeStatus'])")) 'SC135 [kill] the STATUS is threaded into the qualifier call, not left at its default'

# ===========================================================================
Write-Host ''
Write-Host "PASS: $script:Pass   FAIL: $script:Fail" -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
