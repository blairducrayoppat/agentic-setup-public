# verify-breaker-reason.ps1 — #1494 regression lock.
#
# THE DEFECT: the circuit-breaker sentence was formatted inline from $IdleTimeoutSec (the STDIN
# transcript-idle default, 240) while under driver=acp the enforced bound is cfg.acp.idle_sec
# (600), threaded to acp_coder.py and never seen at the print site. Every ACP idle kill therefore
# printed "240s" for a 600s bound. Measured on run 20260831-230448-bd, whose own record said
# Seconds: 609.4 in the same breath as "no new step/edit for 240s".
#
# It is the number a park analysis reads: at 600s an 8192-token burst needs 13.65 tok/s to
# survive; at 240s it needs 34.13, which this hardware never reaches.
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok) { if ($ok) { "  [PASS] $n"; $script:pass++ } else { "  [FAIL] $n"; $script:fail++ } }
$lib = Join-Path $PSScriptRoot 'fleet-lib.ps1'
$src = Get-Content $lib -Raw

""
"== S  the enforced bound reaches the message, and nothing re-derives it =="
Check "S1 the message no longer formats the idle bound from the parameter default" `
  (-not ($src -match 'no new step/edit for \$\{IdleTimeoutSec\}s'))
Check "S2 the ACP branch stamps the bound it actually enforced" `
  ($src -match '\$acp\.Result\.IdleBoundSec\s*=\s*\$acpIdle')
Check "S3 the stdin path carries its own enforced bound" `
  ($src -match 'IdleBoundSec\s*=\s*\$IdleTimeoutSec')
Check "S4 the print site delegates to the pure function" `
  ($src -match '\$why\s*=\s*Get-BreakerReason\s+-Run\s+\$run')
Check "S5 the two paths declare DIFFERENT idle signals (they are different observables)" `
  (($src -match "IdleSignal\s*=\s*'no session/update'") -and ($src -match "IdleSignal\s*=\s*'no new step/edit'"))

# load only the function under test
$ast = [System.Management.Automation.Language.Parser]::ParseFile($lib, [ref]$null, [ref]$null)
$node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BreakerReason' }, $true)
Check "L  Get-BreakerReason extracted by AST" ($null -ne $node)
. ([scriptblock]::Create($node.Extent.Text))

""
"== T  THE TOGGLE: a distinctive bound must appear, so the number is not hard-coded =="
# 777 is neither 240 nor 600. A test asserting only that 'some number' appears would have PASSED
# the original bug, which is exactly why this uses a value neither default can produce.
$acpRun = @{ TimedOut=$true; TimeoutReason='idle'; IdleBoundSec=777; IdleSignal='no session/update' }
$m = Get-BreakerReason -Run $acpRun -IdleTimeoutSec 240 -MaxRunMinutes 60
Check "T1 the ENFORCED bound is printed, not the 240 parameter" ($m -match '777s')
Check "T2 the 240 default does NOT leak into the sentence" (-not ($m -match '240'))
Check "T3 the ACP signal is named (session/update, not step/edit)" ($m -match 'no session/update')

# the real shape of tonight's kill
$tonight = @{ TimedOut=$true; TimeoutReason='idle'; IdleBoundSec=600; IdleSignal='no session/update' }
$m2 = Get-BreakerReason -Run $tonight -IdleTimeoutSec 240 -MaxRunMinutes 60
Check "T4 tonight's ACP kill would now print 600s, not 240s" (($m2 -match '600s') -and (-not ($m2 -match '240')))

# stdin path keeps its own number and wording
$stdin = @{ TimedOut=$true; TimeoutReason='idle'; IdleBoundSec=240; IdleSignal='no new step/edit' }
$m3 = Get-BreakerReason -Run $stdin -IdleTimeoutSec 240 -MaxRunMinutes 60
Check "T5 the stdin path still prints its own 240s and its own signal" `
  (($m3 -match '240s') -and ($m3 -match 'no new step/edit'))

""
"== B  back-compat and the other switch arms =="
$old = @{ TimedOut=$true; TimeoutReason='idle' }   # a pre-#1494 result shape
$m4 = Get-BreakerReason -Run $old -IdleTimeoutSec 333 -MaxRunMinutes 60
Check "B1 an older result with no IdleBoundSec falls back to the parameter, not to a literal" `
  ($m4 -match '333s')
$ceil = @{ TimedOut=$true; TimeoutReason='ceiling' }
Check "B2 the ceiling arm still reports its minutes" `
  ((Get-BreakerReason -Run $ceil -IdleTimeoutSec 240 -MaxRunMinutes 45) -match '45-min')
$other = @{ TimedOut=$true; TimeoutReason='' }
Check "B3 an unknown reason degrades to the generic sentence, never a wrong number" `
  ((Get-BreakerReason -Run $other -IdleTimeoutSec 240 -MaxRunMinutes 60) -match 'exceeded its time budget')

""
"== D  THE DURABLE SENTENCE -- the one that is written to the report and read next morning =="
# The console sentence was fixed first; this one was not, and it is the one that PERSISTS.
# Measured 2026-09-01 across state/: 70 banked reports carry this line and EVERY one says 240s,
# against ground truth of 42 idle kills enforced at 600s and 26 at 120s. The printed 240 never
# matched any enforced value, ever -- so this is not drift, it was never right.
$dnode = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-TimeoutStopText' }, $true)
Check "L2 Get-TimeoutStopText extracted by AST" ($null -ne $dnode)
. ([scriptblock]::Create($dnode.Extent.Text))

$d1 = Get-TimeoutStopText -Reason 'idle' -IdleTimeoutSec 240 -MaxRunMinutes 60 -Run $acpRun
Check "D1 the REPORT sentence prints the ENFORCED bound (777), not the 240 parameter" `
  (($d1 -match '777s') -and (-not ($d1 -match '240')))
Check "D2 the REPORT sentence names the ACP signal, not the stdin observable" `
  (($d1 -match 'no session/update') -and (-not ($d1 -match 'no new step or edit')))

$d2 = Get-TimeoutStopText -Reason 'idle' -IdleTimeoutSec 240 -MaxRunMinutes 60 -Run $tonight
Check "D3 tonight's ACP kill would now be BANKED as 600s, not 240s" `
  (($d2 -match '600s') -and (-not ($d2 -match '240')))

$dstdin = Get-TimeoutStopText -Reason 'idle' -IdleTimeoutSec 240 -MaxRunMinutes 60 -Run $stdin
Check "D4 the stdin path is NOT broken by the acp fix -- it keeps 240s and its own wording" `
  (($dstdin -match '240s') -and ($dstdin -match 'no new step/edit'))

$dold = Get-TimeoutStopText -Reason 'idle' -IdleTimeoutSec 333 -MaxRunMinutes 60
Check "D5 a pre-#1494 run with no stamp still falls back to the parameter, not a literal" `
  ($dold -match '333s')
Check "D6 the ceiling arm is untouched" `
  ((Get-TimeoutStopText -Reason 'ceiling' -MaxRunMinutes 45) -match '45-min')

Check "D7 the report call site passes the run, so it cannot be told a number by a caller that does not know the driver" `
  ((Get-Content (Join-Path $PSScriptRoot 'new-agent-task.ps1') -Raw) -match 'Get-TimeoutStopText[^
]*-Run \$run')

""
"== X  CROSS-SENTENCE: console and report must never disagree about one event =="
# The whole #1494 class is two descriptions of one event drifting apart. Asserting each one
# separately is what allowed the console to be fixed while the banked one stayed wrong, so this
# compares them to EACH OTHER over the same run object rather than to a constant.
foreach ($case in @($acpRun, $tonight, $stdin)) {
    $c = Get-BreakerReason    -Run $case -IdleTimeoutSec 240 -MaxRunMinutes 60
    $r = Get-TimeoutStopText  -Reason 'idle' -IdleTimeoutSec 240 -MaxRunMinutes 60 -Run $case
    $cn = ([regex]::Match($c, '(\d+)s')).Groups[1].Value
    $rn = ([regex]::Match($r, '(\d+)s')).Groups[1].Value
    Check ("X the two sentences agree for IdleBoundSec={0}: console={1}s report={2}s" -f $case.IdleBoundSec, $cn, $rn) `
      (($cn -eq $rn) -and ($cn -eq [string]$case.IdleBoundSec))
    $cs = if ($c -match 'no session/update') { 'acp' } else { 'stdin' }
    $rs = if ($r -match 'no session/update') { 'acp' } else { 'stdin' }
    Check ("X the two sentences name the SAME signal for IdleBoundSec={0}: {1}/{2}" -f $case.IdleBoundSec, $cs, $rs) `
      ($cs -eq $rs)
}

""
"== C  THE Start-Job BOUNDARY: EXECUTE the rebuild, do not read its source =="
# Found by independent review. ConvertTo-CandidateResult rebuilds Run from an EXPLICIT field list
# after the CliXml round trip, and the two stamps were not on it -- so on the CONCURRENT path the
# sentence silently reverted to the stdin default while the sequential path was correct. Latent
# only because concurrency has been RAM-gated to sequential since 2026-08; the dispatch default
# is 3.
#
# THE FIRST TWO VERSIONS OF THIS SECTION WERE BOTH WRONG, and how they were wrong is the point.
# v1 derived the expected fields by parsing the return literal; the parse failed, and it reported
# "missing: none" and PASSED -- proving nothing. v2 replaced that with an explicit list checked by
# `$convertFn -notmatch $field`, a SUBSTRING TEST OVER SOURCE TEXT. Review defeated it two ways
# while keeping the suite fully green: delete the assignment but leave the identifier in a comment,
# and -- worse, with nothing deleted at all -- keep both assignments and have IdleSignal read
# $run.CappedReason. "The word appears somewhere in this function" is not "the field is carried."
#
# So this EXECUTES the rebuild and asserts on returned VALUES, the way D and X assert on returned
# sentences. A broken fixture throws instead of quietly reporting success.
$cnode = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-CandidateResult' }, $true)
Check "C0 ConvertTo-CandidateResult extracted by AST (a miss here throws, it does not pass)" ($null -ne $cnode)
. ([scriptblock]::Create($cnode.Extent.Text))

# The shape the real path produces: a candidate result whose Run carries the ACP stamps.
$rawAcp = @{
    GitFailed = $false; GitError = ''; GitFaultReason = ''; SHA = 'abc1234'; BuildAttempts = 1
    TestError = ''; VerifyDetail = ''; VerifyError = ''; AgentLog = 'x.log'
    Run = @{ TimedOut = $true; TimeoutReason = 'idle'; Capped = $false; CappedReason = 'CAPPED-SENTINEL'
             ExitCode = $null; Seconds = 601.4; Error = ''
             IdleBoundSec = 600; IdleSignal = 'no session/update' }
}
$rebuilt = ConvertTo-CandidateResult -Raw $rawAcp -Index 1
Check "C1 the enforced bound SURVIVES the boundary (value, not the name appearing in the source)" `
  ($rebuilt.Run.IdleBoundSec -eq 600)
Check "C2 the signal name survives with the RIGHT value, not merely present" `
  ($rebuilt.Run.IdleSignal -eq 'no session/update')
# Kills the "reads the wrong source variable" mutant: CappedReason is distinctive on purpose.
Check "C3 the signal did not come from another field of the same run" `
  ($rebuilt.Run.IdleSignal -ne 'CAPPED-SENTINEL')

# and the sentence built FROM the rebuilt run -- the property that actually matters downstream
$afterBoundary = Get-TimeoutStopText -Reason 'idle' -IdleTimeoutSec 240 -MaxRunMinutes 60 -Run $rebuilt.Run
Check "C4 a CONCURRENT candidate's banked sentence says 600s, not the stdin default" `
  (($afterBoundary -match '600s') -and (-not ($afterBoundary -match '240')))
Check "C5 and it names the ACP signal after the round trip" ($afterBoundary -match 'no session/update')

# A pre-#1494 result must rebuild as ABSENT, not 0: 0 would read as a measurement and mask the fallback.
$rawOld = @{ Run = @{ TimedOut = $true; TimeoutReason = 'idle'; Capped = $false; CappedReason = ''
                      ExitCode = $null; Seconds = 12.0; Error = '' } }
$rebuiltOld = ConvertTo-CandidateResult -Raw $rawOld -Index 2
Check "C6 an unstamped result rebuilds with a null bound, not 0" ($null -eq $rebuiltOld.Run.IdleBoundSec)
Check "C7 and its sentence falls back to the caller's parameter" `
  ((Get-TimeoutStopText -Reason 'idle' -IdleTimeoutSec 333 -MaxRunMinutes 60 -Run $rebuiltOld.Run) -match '333s')

"== Result =="
"  Passed:  $pass"
"  Failed:  $fail"
if ($fail -gt 0) { exit 1 }
"  BREAKER REASON: the sentence reports the bound that actually fired, and names which signal ran out."
exit 0
