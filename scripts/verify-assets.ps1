#requires -Version 5.1
<#
.SYNOPSIS
  Verify Add-AssetHint (UC-010 dispatch assets, SEAM A / #714): the coder-prompt steer that, when
  BlarAI pre-generated raster image assets into the seeded worktree, tells the coder to REFERENCE
  the local file offline instead of drawing an <svg> placeholder or reaching for a CDN.

.DESCRIPTION
  Add-AssetHint is DYNAMIC + gated on ACTUAL FILE PRESENCE in the seeded worktree (NOT on $scaffold,
  because a real pre-existing project resolves to an EMPTY scaffold, so a scaffold gate would miss
  it). This suite proves: no assets -> a byte-identical no-op (the inline-SVG fallback stands);
  assets present -> the offline reference path is emitted (web strips public/), the original prompt
  is preserved verbatim, non-image files are ignored, and the no-external-URL posture is unchanged.

  Mutation-resistant: each [kill] case fails a specific wrong implementation.
  Exit 0 if all passed, 1 otherwise. Run: .\verify-assets.ps1  (PS 5.1 AND 7)
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-Contains($Haystack, $Needle, $Msg) { if ([string]$Haystack -like "*$Needle*") { _pass $Msg } else { _fail "$Msg (expected to contain '$Needle')" } }
function Assert-NotContains($Haystack, $Needle, $Msg) { if ([string]$Haystack -notlike "*$Needle*") { _pass $Msg } else { _fail "$Msg (expected NOT to contain '$Needle')" } }

$root = Join-Path ([System.IO.Path]::GetTempPath()) 'verify-assets-wt'
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path $root | Out-Null
function New-Wt($name) {
    $p = Join-Path $root $name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}
function Add-Asset($wt, $rel) {
    $full = Join-Path $wt $rel
    New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
    Set-Content -LiteralPath $full -Value 'x' -NoNewline
}

$P = 'ORIGINAL PROMPT'

Section 'no assets -> byte-identical no-op (the inline-SVG fallback stands)'
Assert-Eq $P (Add-AssetHint -Prompt $P -Worktree '' -Surface 'web')          'AH1 empty worktree -> prompt unchanged'
$wtEmpty = New-Wt 'empty'
Assert-Eq $P (Add-AssetHint -Prompt $P -Worktree $wtEmpty -Surface 'web')     'AH2 worktree with no asset dirs -> prompt unchanged'
$wtTxt = New-Wt 'txtonly'; Add-Asset $wtTxt 'public/assets/notes.txt'
Assert-Eq $P (Add-AssetHint -Prompt $P -Worktree $wtTxt -Surface 'web')       'AH3 [kill] a non-image file is ignored -> no-op (never lists a .txt)'

Section 'web asset present -> offline reference emitted (public/ stripped)'
$wtWeb = New-Wt 'web'; Add-Asset $wtWeb 'public/assets/elephant.png'
$hWeb = Add-AssetHint -Prompt $P -Worktree $wtWeb -Surface 'web'
Assert-True ($hWeb.StartsWith($P))                    'AH4 original prompt preserved verbatim (appended, never replaced)'
Assert-Contains $hWeb 'assets/elephant.png'           'AH5 emits the offline reference path'
Assert-NotContains $hWeb 'public/assets/elephant.png' 'AH6 [kill] web reference STRIPS public/ (served as root)'
Assert-Contains $hWeb '<img src='                     'AH7 tells the coder to use an <img> tag'
Assert-Contains $hWeb 'do not redraw'                 'AH8 header forbids redrawing a placeholder for it'
Assert-NotContains $hWeb 'http://'                    'AH9 no external URL is ever suggested'

Section 'web detected by a public/ dir even when Surface is blank (real project = empty scaffold)'
$wtBlank = New-Wt 'blanksurface'; Add-Asset $wtBlank 'public/assets/hero.png'
$hBlank = Add-AssetHint -Prompt $P -Worktree $wtBlank -Surface ''
Assert-Contains $hBlank 'assets/hero.png'             'AH10 fires on file presence with a blank surface'
Assert-Contains $hBlank '<img src='                   'AH11 public/ dir -> web guidance even with no surface label'

Section 'non-web asset present -> local file reference (not the web <img> form)'
$wtGui = New-Wt 'gui'; Add-Asset $wtGui 'assets/logo.png'
$hGui = Add-AssetHint -Prompt $P -Worktree $wtGui -Surface 'desktop-gui'
Assert-Contains $hGui 'assets/logo.png'               'AH12 lists the desktop asset'
Assert-Contains $hGui 'BitmapImage'                   'AH13 desktop guidance (packaged Image), not the web <img> form'

Section 'multiple assets all listed'
$wtMulti = New-Wt 'multi'; Add-Asset $wtMulti 'public/assets/hero.png'; Add-Asset $wtMulti 'public/assets/logo.webp'
$hMulti = Add-AssetHint -Prompt $P -Worktree $wtMulti -Surface 'web'
Assert-Contains $hMulti 'assets/hero.png'             'AH14 lists the first asset'
Assert-Contains $hMulti 'assets/logo.webp'            'AH15 lists the second asset'

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -eq 0) { Write-Host "ALL $($script:Pass) CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host "$($script:Fail) FAILED / $($script:Pass) passed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
