#requires -Version 7.0
<#
.SYNOPSIS
  Proves that with containment OFF the coder path is unchanged by the #1678/#1686/#1692 work: the new
  fleet-lib.ps1 / coder-leg-queue.ps1 / configs/AGENTS.md are compared with the BASE commit's (default: the pinned commit 3097116)
  two ways.

.DESCRIPTION
  1. STRUCTURAL: every function in fleet-lib.ps1 and coder-leg-queue.ps1 is compared by its parsed text between
     the base and now. The only function allowed to differ in fleet-lib.ps1 is Invoke-FusedCoderRun (the
     restricted path); nothing else may change; coder-leg-queue.ps1 may only ADD functions. configs/AGENTS.md
     and configs/fleet-driver.json must be byte-identical.
  2. BEHAVIOURAL: for each manifest shape (missing, empty, garbled, wrong encoding, BOM, duplicate keys,
     every containment/driver value, with the interpreter present and absent), Invoke-CoderDriver runs in a
     fresh process against the base tree and against this tree, with the three things it would call
     (Invoke-AcpCoderRun, Invoke-AgentRun, Invoke-FusedCoderRun) and the containment-expected test replaced by
     recording stubs. The recorded call sequence, the arguments of each call (the prompt included) and the
     returned value or thrown message must be identical. The same shapes also run through
     Get-FleetDriverConfig and Resolve-WorktreeBase.
  A control proves the comparison can fail: one stub is made to differ on purpose and the comparison must
  report it.
#>
# The BASE is a PINNED commit (agentic-setup main before the #1678 stage merged), never the moving branch name:
# 'main' becomes this tree after the merge and every 'only these functions changed' assertion goes red.
param([string]$BaseRef = '3097116', [switch]$KeepTemp)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\hidden-process-lib.ps1"
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('offdiff-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
# Hash with CRLF folded to LF: a Windows checkout (core.autocrlf) and `git archive` carry the same content with
# different line endings, which is not a change of the file.
function _EolNormalisedHash([string]$Path) {
    $t = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($t)) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

try {
    $base = Join-Path $tmp 'base'; $new = Join-Path $tmp 'new'
    New-Item -ItemType Directory $base, $new | Out-Null
    $baseSha = (& git -C $repo rev-parse $BaseRef).Trim()
    & git -C $repo archive --format=zip $BaseRef scripts configs -o (Join-Path $tmp 'base.zip')
    if ($LASTEXITCODE -ne 0) { throw "git archive $BaseRef failed" }
    Expand-Archive -LiteralPath (Join-Path $tmp 'base.zip') -DestinationPath $base -Force
    foreach ($d in 'scripts', 'configs') { Copy-Item (Join-Path $repo $d) (Join-Path $new $d) -Recurse -Force }
    Write-Host "base = $BaseRef ($baseSha)   now = $repo (working tree)" -ForegroundColor Cyan

    Section 'structural: the functions that changed'
    function Get-FunctionTexts([string]$File) {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errs)
        if ($errs.Count -gt 0) { throw "parse errors in ${File}: $($errs[0].Message)" }
        $h = @{}
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $h[$f.Name] = ($f.Extent.Text -replace "`r`n", "`n") }
        return $h
    }
    foreach ($file in 'fleet-lib.ps1', 'coder-leg-queue.ps1', 'coder-leg-run.ps1', 'new-agent-task.ps1', 'run-fleet.ps1') {
        $b = Get-FunctionTexts (Join-Path $base "scripts\$file"); $n = Get-FunctionTexts (Join-Path $new "scripts\$file")
        $changed = @($b.Keys | Where-Object { $n.ContainsKey($_) -and $b[$_] -cne $n[$_] } | Sort-Object)
        $removed = @($b.Keys | Where-Object { -not $n.ContainsKey($_) } | Sort-Object)
        $added = @($n.Keys | Where-Object { -not $b.ContainsKey($_) } | Sort-Object)
        Write-Host "  $file : changed=[$($changed -join ', ')] added=[$($added -join ', ')] removed=[$($removed -join ', ')]"
        switch ($file) {
            'fleet-lib.ps1' {
                Assert-True (($changed -join ',') -eq 'Invoke-FusedCoderRun' -and $removed.Count -eq 0 -and $added.Count -eq 0) 'fleet-lib.ps1: the only changed function is Invoke-FusedCoderRun (the restricted path); Invoke-CoderDriver, Invoke-AcpCoderRun, Invoke-AgentRun, Get-FleetDriverConfig and Resolve-WorktreeBase are byte-identical'
            }
            'coder-leg-queue.ps1' {
                Assert-True ($changed.Count -eq 0 -and $removed.Count -eq 0) 'coder-leg-queue.ps1: no existing function changed or removed (new helpers are only added)'
            }
            default { Assert-True ($changed.Count -eq 0 -and $removed.Count -eq 0 -and $added.Count -eq 0) "$file : no function changed" }
        }
    }
    $runnerNew = Get-Content (Join-Path $new 'scripts\coder-leg-run.ps1') -Raw
    Assert-True ($runnerNew -match 'Get-CoderLegGitEnv' -and (Get-Content (Join-Path $base 'scripts\coder-leg-run.ps1') -Raw) -notmatch 'Get-CoderLegGitEnv') 'coder-leg-run.ps1 gained the git environment (the runner only ever runs for the restricted coder leg and the verify probe)'
    foreach ($f in 'configs\AGENTS.md', 'configs\fleet-driver.json', 'configs\opencode.json') {
        $hb = _EolNormalisedHash (Join-Path $base $f); $hn = _EolNormalisedHash (Join-Path $new $f)
        Assert-True ($hb -eq $hn) "$f is byte-identical to the base (sha256 $($hn.Substring(0, 12)))"
    }
    # Files the restricted tool-chain setup (#775 plan step 4) added: the manifest, the library, the stage. The
    # containment=off path must not be able to read ANY of them: no script that path loads may name them.
    $setupNames = 'coder-setup-lib', 'coder-toolchain', 'provision-coder-setup', 'coder-boot-surface-lib', 'remove-nginx-gateway'
    foreach ($file in 'fleet-lib.ps1', 'coder-leg-queue.ps1', 'new-agent-task.ps1', 'run-fleet.ps1', 'critic-run.ps1') {
        $txt = Get-Content (Join-Path $new "scripts\$file") -Raw
        $named = @($setupNames | Where-Object { $txt -match [regex]::Escape($_) })
        Assert-True ($named.Count -eq 0) "scripts\$file (loaded on the off path) names none of the new tool-chain setup files$(if ($named.Count) { ': ' + ($named -join ', ') })"
    }
    Assert-True (-not (Test-Path (Join-Path $base 'configs\coder-toolchain.json')) -and (Test-Path (Join-Path $new 'configs\coder-toolchain.json'))) 'configs\coder-toolchain.json is NEW (absent at the base): nothing at the base could have read it'
    $legRun = Get-Content (Join-Path $new 'scripts\coder-leg-run.ps1') -Raw
    Assert-True ($legRun -match 'coder-setup-lib') 'the only runner that reads the setup library is coder-leg-run.ps1 (it runs only for the restricted coder leg and the verify probe)'

    Section 'behavioural: Invoke-CoderDriver, Get-FleetDriverConfig and Resolve-WorktreeBase over the manifest shapes'
    $pyExe = (Get-Command pwsh).Source -replace '\\', '/'
    $shapes = [ordered]@{
        'missing-file'                  = $null
        'empty-file'                    = ''
        'garbled-json'                  = '{not json'
        'array-not-object'              = '[1,2,3]'
        'string-scalar'                 = '"off"'
        'shipped-manifest'              = 'SHIPPED'
        'stdin-off'                     = '{"driver":"stdin","containment":"off"}'
        'acp-off-interpreter-present'   = ('{"driver":"acp","containment":"off","acp":{"python":"' + $pyExe + '","blarai_root":"C:/x","idle_sec":600,"max_steps":45,"spin_steps":10}}')
        'acp-off-interpreter-absent'    = '{"driver":"acp","containment":"off","acp":{"python":"C:/no/such/python.exe"}}'
        'acp-off-no-acp-block'          = '{"driver":"acp","containment":"off"}'
        'containment-only-off'          = '{"containment":"off"}'
        'containment-missing'           = '{"driver":"acp"}'
        'containment-capitalised'       = '{"driver":"acp","containment":"Restricted_Account"}'
        'containment-empty-string'      = '{"driver":"acp","containment":""}'
        'containment-null'              = '{"driver":"acp","containment":null}'
        'containment-number'            = '{"driver":"acp","containment":5}'
        'containment-typo'              = '{"driver":"acp","containment":"restricted"}'
        'driver-unknown-off'            = '{"driver":"foo","containment":"off"}'
        'driver-number'                 = '{"driver":7,"containment":"off"}'
        'duplicate-keys'                = '{"driver":"stdin","driver":"acp","containment":"off","containment":"restricted_account"}'
        'restricted-acp'                = '{"driver":"acp","containment":"restricted_account","acp":{"python":"C:/no/such.exe"}}'
        'restricted-stdin'              = '{"driver":"stdin","containment":"restricted_account"}'
        'research-docs-true'            = '{"driver":"stdin","containment":"off","research_docs":true}'
        'bom-valid'                     = "BOM:" + '{"driver":"stdin","containment":"off"}'
        'utf16-valid'                   = 'UTF16:' + '{"driver":"stdin","containment":"off"}'
    }
    $tracer = @'
param([string]$Tree, [string]$ShapeFile, [string]$Expected, [string]$Variant)
$ErrorActionPreference = 'Stop'
$scripts = Join-Path $Tree 'scripts'
. (Join-Path $scripts 'coder-leg-queue.ps1')
. (Join-Path $scripts 'fleet-lib.ps1')
$script:Trace = New-Object System.Collections.ArrayList
function ConvertTo-StableJson($o) {
    # hashtable key order is randomised per process: sort keys so two runs of the same code print the same text
    function Sort-Deep($x) {
        if ($x -is [System.Collections.IDictionary]) { $r = [ordered]@{}; foreach ($k in ($x.Keys | Sort-Object)) { $r[[string]$k] = Sort-Deep $x[$k] }; return $r }
        if ($x -is [pscustomobject]) { $r = [ordered]@{}; foreach ($p in ($x.PSObject.Properties | Sort-Object Name)) { $r[$p.Name] = Sort-Deep $p.Value }; return $r }
        if ($x -is [System.Collections.IEnumerable] -and $x -isnot [string]) { return @($x | ForEach-Object { Sort-Deep $_ }) }
        return $x
    }
    return (ConvertTo-Json -InputObject (Sort-Deep $o) -Depth 8 -Compress)
}
function Invoke-AcpCoderRun { param($WorkDir, $Model, $Prompt, $LogPath, $Acp, $TimeoutSec, $IdleTimeoutSec, $MaxSteps, $SpinSteps, $Job = $null)
    [void]$script:Trace.Add(@{ fn = 'Invoke-AcpCoderRun'; WorkDir = $WorkDir; Model = $Model; Prompt = $Prompt; LogPath = $LogPath; Timeout = $TimeoutSec; Idle = $IdleTimeoutSec; MaxSteps = $MaxSteps; SpinSteps = $SpinSteps; Python = [string]$Acp.python })
    if ($env:DIFF_CONTROL -eq '1' -and $Tree -like '*new*') { [void]$script:Trace.Add(@{ fn = 'control-difference' }) }
    return @{ Ok = $true; Reason = 'stub'; Result = @{ TimedOut = $false; Seconds = 1.5; ExitCode = 0; LogPath = $LogPath } } }
function Invoke-AgentRun { param($WorkDir, $Model, $Prompt, $LogPath, $TimeoutSec, $IdleTimeoutSec, [switch]$JsonStepCap)
    [void]$script:Trace.Add(@{ fn = 'Invoke-AgentRun'; WorkDir = $WorkDir; Model = $Model; Prompt = $Prompt; LogPath = $LogPath; Timeout = $TimeoutSec; Idle = $IdleTimeoutSec; StepCap = [bool]$JsonStepCap })
    return @{ TimedOut = $false; Seconds = 2.5; ExitCode = 0; LogPath = $LogPath } }
function Invoke-FusedCoderRun { param($WorkDir, $Model, $Prompt, $LogPath, $Cfg, $TimeoutSec, $ScriptRoot, $Options)
    [void]$script:Trace.Add(@{ fn = 'Invoke-FusedCoderRun'; WorkDir = $WorkDir; Model = $Model; Prompt = $Prompt; LogPath = $LogPath; Timeout = $TimeoutSec; Driver = [string]$Cfg.driver; Containment = [string]$Cfg.containment })
    return @{ TimedOut = $false; Seconds = 3.5; ExitCode = 0; LogPath = $LogPath } }
function Test-CoderContainmentExpected { param($TaskPath, $TaskName, $MarkerPath)
    [void]$script:Trace.Add(@{ fn = 'Test-CoderContainmentExpected'; Answer = ($Expected -eq 'yes') })
    return ($Expected -eq 'yes') }
$out = [ordered]@{}
$cfgText = 'none'
try { $c = Get-FleetDriverConfig -ScriptRoot $scripts; $cfgText = (ConvertTo-StableJson $c) } catch { $cfgText = "THREW: $($_.Exception.Message)" }
$out.config = $cfgText
$res = $null; $thrown = $null
try { $res = Invoke-CoderDriver -WorkDir 'C:\w\wt1' -Model 'coder-30b' -Prompt "PROMPT <&> text`nline2" -LogPath 'C:\w\log.txt' -TimeoutSec 123 -IdleTimeoutSec 45 -ScriptRoot $scripts } catch { $thrown = $_.Exception.Message }
$out.result = if ($null -ne $res) { (ConvertTo-StableJson $res) } else { 'null' }
$out.thrown = [string]$thrown
$out.trace = ($script:Trace | ForEach-Object { ConvertTo-StableJson $_ }) -join "`n"
$out.base_off = (Resolve-WorktreeBase -ScriptRoot $scripts -Containment 'off')
$out.base_restricted = (Resolve-WorktreeBase -ScriptRoot $scripts -Containment 'restricted_account')
$out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ShapeFile -Encoding UTF8
'@
    $shippedBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'configs\fleet-driver.json'))
    $tracerPath = Join-Path $tmp 'tracer.ps1'; Set-Content -LiteralPath $tracerPath -Value $tracer -Encoding UTF8
    $pw = (Get-Command pwsh).Source
    function Write-Shape($tree, $name, $text) {
        $f = Join-Path $tree 'configs\fleet-driver.json'
        if ($null -eq $text) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return }
        if ($text -eq 'SHIPPED') { [IO.File]::WriteAllBytes($f, $shippedBytes); return }
        if ($text.StartsWith('BOM:')) { [IO.File]::WriteAllText($f, $text.Substring(4), (New-Object Text.UTF8Encoding($true))); return }
        if ($text.StartsWith('UTF16:')) { [IO.File]::WriteAllText($f, $text.Substring(6), [Text.Encoding]::Unicode); return }
        [IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding($false)))
    }
    $compared = 0; $diffs = New-Object System.Collections.ArrayList
    foreach ($name in $shapes.Keys) {
        foreach ($expected in 'no', 'yes') {
            $outs = @{}
            foreach ($pair in @(@('base', $base), @('new', $new))) {
                Write-Shape $pair[1] $name $shapes[$name]
                $of = Join-Path $tmp "$name-$expected-$($pair[0]).json"
                $null = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $tracerPath, '-Tree', $pair[1], '-ShapeFile', $of, '-Expected', $expected, '-Variant', $name) -TimeoutSec 300
                if (-not (Test-Path $of)) { [void]$diffs.Add("$name/$expected/$($pair[0]): the tracer wrote nothing"); continue }
                $raw = (Get-Content -LiteralPath $of -Raw)
                $bs = [string][char]92
                $outs[$pair[0]] = $raw.Replace($pair[1].Replace($bs, $bs + $bs), '<TREE>').Replace($pair[1], '<TREE>').Replace($pair[1].Replace($bs, '/'), '<TREE>')
            }
            $compared++
            if ($outs['base'] -cne $outs['new']) { [void]$diffs.Add("$name (containment-expected=$expected): base and new differ") }
        }
    }
    Assert-True ($diffs.Count -eq 0) "Invoke-CoderDriver: $compared runs ($($shapes.Count) manifest shapes x 2 'containment expected' answers) produce IDENTICAL traces, results, thrown messages, configs and worktree bases$(if ($diffs.Count) { ' -- ' + ($diffs -join ' | ') })"

    Section 'control: the comparison can fail'
    $env:DIFF_CONTROL = '1'
    Write-Shape $base 'x' $shapes['acp-off-interpreter-present']; Write-Shape $new 'x' $shapes['acp-off-interpreter-present']
    $ob = Join-Path $tmp 'ctl-base.json'; $on = Join-Path $tmp 'ctl-new.json'
    $null = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $tracerPath, '-Tree', $base, '-ShapeFile', $ob, '-Expected', 'no', '-Variant', 'x') -TimeoutSec 300
    $null = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $tracerPath, '-Tree', $new, '-ShapeFile', $on, '-Expected', 'no', '-Variant', 'x') -TimeoutSec 300
    Remove-Item Env:\DIFF_CONTROL -ErrorAction SilentlyContinue
    Assert-True ((Get-Content $ob -Raw) -cne (Get-Content $on -Raw)) 'a deliberate difference in one stub IS reported (the comparison is not vacuous)'

    Section 'what the shapes actually exercised (so "identical" is not "identical emptiness")'
    $kinds = @{}
    foreach ($name in $shapes.Keys) {
        $t = (Get-Content -LiteralPath (Join-Path $tmp "$name-no-new.json") -Raw | ConvertFrom-Json)
        $fn = @($t.trace -split "`n" | Where-Object { $_ } | ForEach-Object { ($_ | ConvertFrom-Json).fn } | Where-Object { $_ -ne 'Test-CoderContainmentExpected' })
        $kinds["$($fn -join '+')$(if ($t.thrown) { ' THROWS' } else { '' })"] = 1 + [int]$kinds["$($fn -join '+')$(if ($t.thrown) { ' THROWS' } else { '' })"]
    }
    $kinds.GetEnumerator() | ForEach-Object { Write-Host "    $($_.Value) shape(s): $(if ($_.Key) { $_.Key } else { '(no call)' })" }
    Assert-True ($kinds.Keys -contains 'Invoke-AgentRun' -and $kinds.Keys -contains 'Invoke-AcpCoderRun' -and ($kinds.Keys | Where-Object { $_ -like 'Invoke-FusedCoderRun*' }) -and ($kinds.Keys | Where-Object { $_ -like '*THROWS' })) 'the shapes reached the stdin path, the ACP path, the fused (restricted) path and a refusal'
} finally {
    if (-not $KeepTemp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
if ($script:Fail -eq 0) { Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0 }
Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red; exit 1
