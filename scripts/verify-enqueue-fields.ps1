#requires -Version 5.1
<#
.SYNOPSIS
  Verify the ENQUEUE-FIELD contract (#698): the deterministic enqueue path carries EVERY rich PLAN field
  the fleet consumes, not just {repo,task,prompt,model}.

.DESCRIPTION
  Background (plain English):
    BlarAI's PLAN step (compile_prompts) stamps a rich set of signal fields onto each task dict: the build
    signal (surface / complexity / language_hint), the VLM-critique inputs (goal / visual_criteria_json), and
    the #690 shared acceptance ORACLE (acceptance_test_code / acceptance_test_path). The LIVE /dispatch path
    already carries all of these end to end (the swap driver writes the whole task dict into the per-run queue).
    But the DETERMINISTIC enqueue path -- BlarAI's shared/fleet/dispatch.py::enqueue_task -> add-fleet-task.ps1
    -> fleet-queue.json -- historically wrote only {repo,task,prompt,model}, silently dropping the rich fields
    (#698). run-fleet.ps1 already READS all of them from a queue item and forwards them to new-agent-task.ps1;
    the only gap was the WRITE side. This is the agentic-setup half of the cross-repo #698 fix: add-fleet-task
    now persists all seven fields under the exact queue-key names run-fleet reads.

  This script proves it three ways, no model needed:
    1. FUNCTIONAL round-trip  -- drive the REAL add-fleet-task.ps1 with every field and read the queue JSON
       back, asserting each field landed with the exact key name run-fleet consumes (incl. a multi-line
       acceptance-oracle body, which must survive the JSON seam intact).
    2. DRIFT-LOCK             -- assert, per field, that add-fleet-task WRITES $item.<key> AND run-fleet READS
       $t.<key> into the matching -Param. If either side renames a key, this fails loudly (the seam a
       language-boundary mirror silently breaks -- #886 lesson: a red test, not vigilance).
    3. BACKWARD-COMPAT        -- a bare enqueue (repo/task/prompt only) writes NONE of the rich keys, so the
       default path stays byte-identical.

  Exit 0 if all passed, 1 otherwise. Run it normally ( .\verify-enqueue-fields.ps1 ).
#>
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }

# The seven rich PLAN fields, each as { the add-fleet-task -Param name ; the queue key run-fleet reads }.
# Order mirrors compile_prompts' task dict / run-fleet.ps1's read order.
$Contract = @(
    @{ Param = 'Surface';            Key = 'surface' }
    @{ Param = 'Complexity';         Key = 'complexity' }
    @{ Param = 'LanguageHint';       Key = 'language_hint' }
    @{ Param = 'Goal';               Key = 'goal' }
    @{ Param = 'VisualCriteriaJson'; Key = 'visual_criteria_json' }
    @{ Param = 'AcceptanceTestCode'; Key = 'acceptance_test_code' }
    @{ Param = 'AcceptanceTestPath'; Key = 'acceptance_test_path' }
)

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-enqueue-" + [guid]::NewGuid().ToString('N'))
try {
    $repo = Join-Path $tmp 'proj'
    New-Item -ItemType Directory -Force (Join-Path $repo '.git') | Out-Null   # a real .git so add-fleet-task does not warn
    $queue = Join-Path $tmp 'queue.json'

    # The oracle body is deliberately MULTI-LINE to prove newline content survives the JSON seam.
    $oracle = "def test_it():`n    assert add(2, 2) == 4`n"

    # ------------------------------------------------------------------------
    Section 'Functional: add-fleet-task.ps1 persists EVERY rich PLAN field into the queue item'
    & "$PSScriptRoot\add-fleet-task.ps1" `
        -Repo $repo -Task 'make-calc' -Prompt 'Build a calculator.' `
        -Model 'qwen' -Complexity 'moderate' -Surface 'desktop-gui' -LanguageHint 'python' `
        -Goal 'a calculator that looks like a rocket' `
        -VisualCriteriaJson '["the buttons are large"]' `
        -AcceptanceTestCode $oracle -AcceptanceTestPath 'tests/test_acceptance.py' `
        -Queue $queue | Out-Null

    $items = @(Get-Content $queue -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-Eq 1 $items.Count 'F0 one task written to the queue'
    $it = $items[-1]
    # The base + model fields (pre-existing, re-asserted so the round-trip is complete).
    Assert-Eq $repo               $it.repo                 'F1 repo persisted'
    Assert-Eq 'make-calc'         $it.task                 'F2 task persisted'
    Assert-Eq 'Build a calculator.' $it.prompt             'F3 prompt persisted'
    Assert-Eq 'qwen'              $it.model                'F4 model persisted'
    # The seven rich PLAN fields, each under the exact queue key run-fleet reads.
    Assert-Eq 'desktop-gui'       $it.surface              'F5 surface -> $item.surface'
    Assert-Eq 'moderate'          $it.complexity           'F6 complexity -> $item.complexity'
    Assert-Eq 'python'            $it.language_hint        'F7 language_hint -> $item.language_hint'
    Assert-Eq 'a calculator that looks like a rocket' $it.goal 'F8 goal -> $item.goal'
    Assert-Eq '["the buttons are large"]' $it.visual_criteria_json 'F9 visual_criteria_json -> $item.visual_criteria_json'
    Assert-Eq $oracle             $it.acceptance_test_code 'F10 acceptance_test_code -> $item.acceptance_test_code (multi-line body survives the JSON seam)'
    Assert-Eq 'tests/test_acceptance.py' $it.acceptance_test_path 'F11 acceptance_test_path -> $item.acceptance_test_path'

    # ------------------------------------------------------------------------
    Section 'Backward-compat: a bare enqueue writes NONE of the rich keys (default path byte-identical)'
    $bareQueue = Join-Path $tmp 'bare.json'
    & "$PSScriptRoot\add-fleet-task.ps1" -Repo $repo -Task 't' -Prompt 'p' -Queue $bareQueue | Out-Null
    $bare = @(Get-Content $bareQueue -Raw -Encoding UTF8 | ConvertFrom-Json)[-1]
    $bareNames = @($bare.PSObject.Properties.Name)
    Assert-True  ($bareNames -contains 'repo' -and $bareNames -contains 'task' -and $bareNames -contains 'prompt') 'BC1 bare enqueue keeps {repo,task,prompt}'
    foreach ($c in $Contract) {
        Assert-False ($bareNames -contains $c.Key) ("BC2 [kill] bare enqueue omits '{0}' (absent field -> not written)" -f $c.Key)
    }
    Assert-False ($bareNames -contains 'model') 'BC3 [kill] bare enqueue omits model when absent'
}
finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
Section 'Drift-lock: add-fleet-task WRITES $item.<key> and run-fleet READS $t.<key> for every field'
$addTask  = Get-Content "$PSScriptRoot\add-fleet-task.ps1" -Raw
$runFleet = Get-Content "$PSScriptRoot\run-fleet.ps1" -Raw
foreach ($c in $Contract) {
    # add-fleet-task must persist the queue key from the matching -Param.
    $writePat = '\$item\.' + $c.Key + '\s*=\s*\$' + $c.Param
    Assert-True ([regex]::IsMatch($addTask, $writePat)) ("DL-write [kill] add-fleet-task persists `$item.{0} = `${1}" -f $c.Key, $c.Param)
    # run-fleet must forward that same queue key into the matching new-agent-task -Param (else the
    # field is dormant on the overnight path -- the exact defect W7 of verify-complexity guards for complexity).
    $readPat = '\$params\.' + $c.Param + '\s*=\s*\$t\.' + $c.Key
    Assert-True ([regex]::IsMatch($runFleet, $readPat)) ("DL-read [kill] run-fleet forwards `$params.{0} = `$t.{1}" -f $c.Param, $c.Key)
}

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  ENQUEUE FIELDS: VALIDATED. The deterministic enqueue path carries every rich PLAN field (build signal + VLM-critique inputs + the #690 acceptance oracle) under the exact queue keys run-fleet reads; a bare enqueue stays byte-identical.' -ForegroundColor Green
    exit 0
}
