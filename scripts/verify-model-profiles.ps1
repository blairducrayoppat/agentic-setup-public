#requires -Version 5.1
<#
.SYNOPSIS
  Verify configs/model-profiles.json is well-formed, internally consistent, DORMANT, and
  agrees with its two SSOT mirrors (opencode.json + start-llm.ps1). #834 QUALITY-15.

.DESCRIPTION
  Background (plain English):
    model-profiles.json is the per-model attributes manifest the BlarAI-side harness reads so it
    can branch on model ARCHITECTURE/FAMILY (dense vs MoE, Hermes vs XML tool calls, thinking vs
    not), not only on task complexity. It is a SUPERSET of the same per-model facts already spread
    across opencode.json (provider.local.models) and start-llm.ps1 (the OVMS launch flags). Those
    overlapping facts drift silently unless something asserts they agree -- the exact class the
    passthrough-allowlist gate was minted to kill. This is the agentic-side drift alarm (the blarai
    pytest tests/integration/test_model_profiles_ssot.py is its Python twin over the same files).

  It checks:
    * the manifest parses and is DORMANT (schema present; the assistant-role model's reasoning-strip
      tags are the byte-identical <think>/<tool_call> default the AO consumers fall back to),
    * internal consistency (every call_site.model references an existing model; models have arch/quant),
    * agreement with opencode.json: tool_call, reasoning, limit.context (vs effective_context),
      limit.output (vs max_output_tokens),
    * agreement with start-llm.ps1: --tool_parser (vs tool_call_format), the $residentGB table (vs
      resident_gb), and the MoE MOE_USE_MICRO_GEMM_PREFILL env (vs arch=moe).

  Standalone checker (like verify-fleet-driver.ps1 / verify-opencode-pin.ps1): no model, no GPU, no
  network, no fleet-lib import. Run it normally ( .\verify-model-profiles.ps1 ); do NOT dot-source.
  Exit 0 = agreement. Exit 1 = drift (or the manifest can't be verified). A deliberate model change
  is expected to fail this until model-profiles.json + its mirrors are reconciled in the same change.
#>
param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [DRIFT] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True)" } }

# opencode.json's permission block intentionally carries case-VARIANT keys
# (**/secrets/** and **/SECRETS/**). PowerShell 7's ConvertFrom-Json rejects those
# unless -AsHashtable; 5.1 tolerates them as a PSCustomObject. Parse compatibly and
# read names/fields through helpers that work for both shapes.
function ConvertFrom-JsonCompat([string]$Raw) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ($Raw | ConvertFrom-Json -AsHashtable) }
    return ($Raw | ConvertFrom-Json)
}
function Get-Names($obj) {
    if ($obj -is [System.Collections.IDictionary]) { return @($obj.Keys) }
    return @($obj.PSObject.Properties.Name)
}

# start-llm.ps1 --tool_parser <-> the profile's abstract tool_call_format.
$ParserToFormat = @{ 'hermes3' = 'hermes'; 'qwen3coder' = 'qwen3_xml' }

$ConfigDir    = Join-Path (Split-Path $PSScriptRoot -Parent) 'configs'
$ManifestPath = Join-Path $ConfigDir 'model-profiles.json'
$OpencodePath = Join-Path $ConfigDir 'opencode.json'
$StartLlmPath = Join-Path $PSScriptRoot 'start-llm.ps1'

Write-Host "== model-profiles.json verification ==" -ForegroundColor Cyan

# --- Load the manifest -------------------------------------------------------
Assert-True (Test-Path $ManifestPath) "manifest exists: configs/model-profiles.json"
if (-not (Test-Path $ManifestPath)) {
    Write-Host ("  Passed: {0}  Drift: {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red; exit 1
}
$manifest = $null
try { $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json; _pass "manifest parses as JSON" }
catch { _fail "manifest parses as JSON ($($_.Exception.Message))" }
if ($null -eq $manifest) {
    Write-Host ("  Passed: {0}  Drift: {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red; exit 1
}

$modelNames = @($manifest.models.PSObject.Properties.Name)

Section 'Structure + DORMANCY'
Assert-Eq 'model-profile/v1' $manifest.schema 'schema == model-profile/v1'
Assert-True ($modelNames.Count -ge 1) "models table is non-empty ($($modelNames -join ', '))"
Assert-True ($null -ne $manifest.call_sites) 'call_sites table present'
Assert-True ($null -ne $manifest.defaults)  'defaults table present'

# The one field the AO consumers read today must be the byte-identical historical strip.
$assistantModel = $null
foreach ($n in $modelNames) {
    if (@($manifest.models.$n.roles) -contains 'assistant') { $assistantModel = $n; break }
}
Assert-True ($null -ne $assistantModel) "an assistant-role model exists ($assistantModel)"
if ($assistantModel) {
    $tags = @($manifest.models.$assistantModel.reasoning_strip.hidden_block_tags)
    Assert-Eq 'think,tool_call' ($tags -join ',') "assistant reasoning_strip tags are the byte-identical <think>/<tool_call> default"
}

Section 'Internal consistency (call_sites reference real models; models are attributed)'
foreach ($csName in @($manifest.call_sites.PSObject.Properties.Name)) {
    $csModel = $manifest.call_sites.$csName.model
    Assert-True ($modelNames -contains $csModel) "call_site '$csName' -> model '$csModel' exists"
}
foreach ($n in $modelNames) {
    Assert-True ([bool]$manifest.models.$n.arch)  "model '$n' declares arch ($($manifest.models.$n.arch))"
    Assert-True ([bool]$manifest.models.$n.quant) "model '$n' declares quant"
}

# --- opencode.json overlap ---------------------------------------------------
Section 'SSOT: agreement with opencode.json (tool_call / reasoning / limit)'
if (-not (Test-Path $OpencodePath)) {
    _fail "opencode.json present for the overlap check"
} else {
    $opencode = ConvertFrom-JsonCompat (Get-Content $OpencodePath -Raw)
    $ocModels = $opencode.provider.local.models
    $ocNames = @(Get-Names $ocModels)

    $profOnly = @($modelNames | Where-Object { $ocNames -notcontains $_ })
    $ocOnly   = @($ocNames   | Where-Object { $modelNames -notcontains $_ })
    Assert-True (($profOnly.Count -eq 0) -and ($ocOnly.Count -eq 0)) `
        "model-id sets match (profile-only: [$($profOnly -join ',')], opencode-only: [$($ocOnly -join ',')])"

    foreach ($n in $modelNames) {
        if ($ocNames -notcontains $n) { continue }
        $pm = $manifest.models.$n
        $om = $ocModels.$n

        $ocTool  = [bool]$om.tool_call
        $pfTool  = ($pm.tool_call_format -ne 'none')
        Assert-Eq $ocTool $pfTool "$n : tool_call (opencode) == (profile tool_call_format != none)"

        $ocReason = [bool]$om.reasoning
        $pfReason = ($pm.thinking_mode -ne 'none')
        Assert-Eq $ocReason $pfReason "$n : reasoning (opencode) == (profile thinking_mode != none)"

        $effective = if ($null -ne $pm.effective_context) { $pm.effective_context } else { $pm.context_window }
        Assert-Eq $om.limit.context $effective "$n : opencode limit.context == profile effective_context"
        Assert-Eq $om.limit.output $pm.max_output_tokens "$n : opencode limit.output == profile max_output_tokens"
    }
}

# --- start-llm.ps1 overlap ---------------------------------------------------
Section 'SSOT: agreement with start-llm.ps1 (tool_parser / residentGB / MoE env)'
if (-not (Test-Path $StartLlmPath)) {
    _fail "start-llm.ps1 present for the overlap check"
} else {
    $startText = Get-Content $StartLlmPath -Raw

    # tool_parser -> nearest preceding switch-branch id
    $headers = [regex]::Matches($startText, "'(coder-30b|qwen3-14b|vision)'\s*\{")
    $parsers = [regex]::Matches($startText, "'--tool_parser'\s*,\s*'([^']+)'")
    $found = @{}
    foreach ($p in $parsers) {
        $owner = $null
        foreach ($h in $headers) { if ($h.Index -lt $p.Index) { $owner = $h.Groups[1].Value } else { break } }
        if ($owner) { $found[$owner] = $p.Groups[1].Value }
    }
    Assert-True ($found.Count -ge 2) "start-llm tool_parser lines parsed ($($found.Keys -join ', '))"
    foreach ($mid in $found.Keys) {
        $parser = $found[$mid]
        $expected = $ParserToFormat[$parser]
        if ($null -eq $expected) { _fail "start-llm --tool_parser '$parser' for $mid not in the translation map" ; continue }
        Assert-Eq $expected $manifest.models.$mid.tool_call_format "$mid : start-llm --tool_parser '$parser' -> profile tool_call_format"
    }

    # $residentGB table
    $rm = [regex]::Match($startText, "residentGB\s*=\s*@\{(.*?)\}", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $rm.Success 'start-llm $residentGB table parsed'
    if ($rm.Success) {
        foreach ($pair in [regex]::Matches($rm.Groups[1].Value, "'([^']+)'\s*=\s*(\d+)")) {
            $mid = $pair.Groups[1].Value; $gb = [int]$pair.Groups[2].Value
            if ($modelNames -contains $mid) {
                Assert-Eq $gb $manifest.models.$mid.resident_gb "$mid : start-llm residentGB == profile resident_gb"
            }
        }
    }

    # MoE workaround env <-> arch=moe
    if ($startText -match 'MOE_USE_MICRO_GEMM_PREFILL') {
        $moe = @($modelNames | Where-Object { $manifest.models.$_.arch -eq 'moe' })
        Assert-True ($moe -contains 'coder-30b') "start-llm sets the MoE env AND profile coder-30b.arch == moe"
    }
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host ("  MODEL-PROFILES: VALIDATED. {0} passed, 0 drift." -f $script:Pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  MODEL-PROFILES: DRIFT. {0} passed, {1} drift." -f $script:Pass, $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "  Reconcile model-profiles.json with opencode.json / start-llm.ps1 in the same change." -ForegroundColor Yellow
    exit 1
}
