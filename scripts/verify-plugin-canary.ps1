#requires -Version 5.1
<#
.SYNOPSIS
  Verify Test-PluginLoadLines / Write-PluginCanaryVerdict (fleet-lib.ps1) -- the #762
  load-line canary, the lesson-46 third-instance structural control (2026-07-08).

.DESCRIPTION
  Both fleet plugins print a stderr load-line at every opencode boot so the fleet can
  verify they wired in -- and nothing ever read them, so both ran silently dead in
  production 2026-06-30 -> 2026-07-07 (#764). The canary is the reader. Each scenario
  kills a specific wrong implementation:
    S1 both load-lines, no errors        -> Ok            (inverted logic flips this)
    S2 one load-line missing             -> not Ok, named (substring-anywhere bug flips S2)
    S3 both missing (the #764 shape)     -> not Ok, both named
    S4 lines present BUT loader error    -> not Ok        (drop the error scan -> S4 flips)
    S5 empty transcript                  -> not Ok        (vacuous-pass guard)
    S6 verdict writer appends transcript line + state marker on failure, nothing on Ok
    S7 COUPLING: the literals the canary greps are pinned against the actual plugin
       sources in configs/opencode-plugins/ -- reword a load-line there and S7 names
       the drift before the canary goes silently blind (the exact defect class again).
  PS 5.1 & 7 safe; no model, no network, no live plugin dir touched.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

$ctLine = '[command-timeout] loaded: bash/shell commands capped at 240000ms (server probe 60000ms)'
$pnLine = '[path-normalize] loaded: Windows drive-path backslashes in bash commands -> forward slashes'

Write-Host "S1: both load-lines present, no loader errors -> Ok"
$v = Test-PluginLoadLines -TranscriptContent "boot noise`n$ctLine`n$pnLine`nagent output"
Assert ($v.Ok -eq $true) 'S1 verdict is Ok'
Assert ($v.Missing.Count -eq 0) 'S1 nothing missing'
Assert ($v.LoaderErrors.Count -eq 0) 'S1 no loader errors'

Write-Host "S2: path-normalize load-line missing -> not Ok, named"
$v = Test-PluginLoadLines -TranscriptContent "boot noise`n$ctLine`nagent output"
Assert ($v.Ok -eq $false) 'S2 verdict is not Ok'
Assert (@($v.Missing) -contains 'path-normalize') 'S2 names path-normalize'
Assert (-not (@($v.Missing) -contains 'command-timeout')) 'S2 does not name the loaded plugin'

Write-Host "S3: both load-lines missing (the #764 production shape) -> not Ok, both named"
$v = Test-PluginLoadLines -TranscriptContent "boot noise`nagent output, no plugins anywhere"
Assert ($v.Ok -eq $false) 'S3 verdict is not Ok'
Assert ((@($v.Missing) -contains 'command-timeout') -and (@($v.Missing) -contains 'path-normalize')) 'S3 names both'

Write-Host "S4: load-lines present BUT a loader error line present -> not Ok"
$v = Test-PluginLoadLines -TranscriptContent "$ctLine`n$pnLine`nERROR failed to load plugin qwen-sampling.js: Plugin export is not a function"
Assert ($v.Ok -eq $false) 'S4 verdict is not Ok despite both load-lines'
Assert ($v.LoaderErrors.Count -ge 1) 'S4 loader error captured'

Write-Host "S5: empty transcript -> not Ok (vacuous-pass guard)"
$v = Test-PluginLoadLines -TranscriptContent ''
Assert ($v.Ok -eq $false) 'S5 empty transcript is never Ok'

Write-Host "S6: verdict writer -- loud line + state marker on failure, silence on Ok"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-canary-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $tmp 'state') | Out-Null
$log = Join-Path $tmp 'run.log'
Set-Content -Path $log -Value 'transcript body'
$bad = Test-PluginLoadLines -TranscriptContent 'nothing loaded'
Write-PluginCanaryVerdict -Verdict $bad -LogPath $log -StateDir (Join-Path $tmp 'state')
Assert ((Get-Content $log -Raw) -match 'PLUGIN-CANARY: FAILED') 'S6 transcript carries the loud line'
$marker = Join-Path $tmp 'state\plugin-canary-failed.txt'
Assert (Test-Path $marker) 'S6 state marker written'
Assert ((Get-Content $marker -Raw) -match 'load-line missing: command-timeout, path-normalize') 'S6 marker names the missing plugins'
$log2 = Join-Path $tmp 'run2.log'
Set-Content -Path $log2 -Value "$ctLine`n$pnLine"
$good = Test-PluginLoadLines -TranscriptContent (Get-Content $log2 -Raw)
Write-PluginCanaryVerdict -Verdict $good -LogPath $log2 -StateDir (Join-Path $tmp 'state')
Assert (-not ((Get-Content $log2 -Raw) -match 'PLUGIN-CANARY')) 'S6 Ok verdict writes nothing to the transcript'
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host "S7: coupling -- the greped literals exist in the actual plugin sources"
$pluginDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\opencode-plugins'
foreach ($pin in @(
    @{ File = 'command-timeout.js'; Marker = '[command-timeout] loaded' },
    @{ File = 'path-normalize.js';  Marker = '[path-normalize] loaded' }
)) {
    $src = Join-Path $pluginDir $pin.File
    Assert (Test-Path $src) ("S7 plugin source exists: " + $pin.File)
    if (Test-Path $src) {
        $content = Get-Content $src -Raw
        Assert ($content.IndexOf($pin.Marker, [System.StringComparison]::Ordinal) -ge 0) `
            ("S7 " + $pin.File + " still emits the literal '" + $pin.Marker + "' the canary greps for")
    }
}

Write-Host ""
Write-Host ("verify-plugin-canary: {0} passed, {1} failed" -f $script:Pass, $script:Fail) `
    -ForegroundColor ($(if ($script:Fail -eq 0) { 'Green' } else { 'Red' }))
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
