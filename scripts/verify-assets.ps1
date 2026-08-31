#requires -Version 5.1
<#
.SYNOPSIS
  Verify Add-AssetHint (UC-010 dispatch assets, SEAM A / #714; widened #1165/#1469 2026-08-30):
  the coder-prompt steer that names the asset files ALREADY in the seeded worktree and tells the
  coder what to do with each kind -- images referenced, video/audio embedded, fonts wired in CSS,
  and documents READ for the words inside. Files arrive both from BlarAI's own image generator
  and from the operator's assets/ folder; this steer is provenance-neutral about which.

.DESCRIPTION
  Add-AssetHint is DYNAMIC + gated on ACTUAL FILE PRESENCE in the seeded worktree (NOT on $scaffold,
  because a real pre-existing project resolves to an EMPTY scaffold, so a scaffold gate would miss
  it). This suite proves: no assets -> a byte-identical no-op (the inline-SVG fallback stands);
  assets present -> the offline reference path is emitted (web strips public/), the original prompt
  is preserved verbatim, each kind of file gets its OWN instruction, files outside the served root
  are marked and told to be copied in, names the intake manifest would skip are skipped here too,
  and the no-external-URL posture is unchanged.

  ("non-image files are ignored" was this suite's claim until 2026-08-30. That WAS the defect:
  the operator's own bio was committed into the coder's tree and never mentioned to it, so the
  coder invented a stand-in person. The surviving rule is narrower -- a document is never dressed
  as an image.)

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
$wtUnknown = New-Wt 'unknownext'; Add-Asset $wtUnknown 'public/assets/tool.exe'
Assert-Eq $P (Add-AssetHint -Prompt $P -Worktree $wtUnknown -Surface 'web')   'AH3 [kill] an unclassified extension is ignored -> no-op (the allowlist is closed)'

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

Section 'documents -> the CONTENT block (read the words), never dressed as an image'
# Rewritten 2026-08-30 (#1165). Before the widening a .txt produced a byte-identical no-op,
# and that was the defect: an operator's own bio was committed into the coder's tree and never
# mentioned, so the coder invented a stand-in person. The rule that survives is the narrower,
# still kill-strength one -- a document is surfaced, but NEVER as an image.
$wtDoc = New-Wt 'docs'; Add-Asset $wtDoc 'assets/bio.md'; Add-Asset $wtDoc 'assets/notes.txt'
$hDoc = Add-AssetHint -Prompt $P -Worktree $wtDoc -Surface 'web'
Assert-True ($hDoc.StartsWith($P))               'AH16 original prompt preserved verbatim'
Assert-Contains $hDoc 'assets/bio.md'            'AH17 the document is listed'
Assert-Contains $hDoc 'READ EACH ONE'            'AH18 tells the coder to READ it, not link it'
Assert-NotContains $hDoc '<img src='             'AH19 [kill] a document NEVER gets an <img> tag'
Assert-NotContains $hDoc 'IMAGE ASSETS IN YOUR TREE' 'AH20 [kill] a document never enters the image block'
Assert-Contains $hDoc 'do NOT add a link'        'AH21 [kill] forbids linking the file in place of its content'
Assert-Contains $hDoc 'Do NOT invent placeholder' 'AH22 forbids the invented stand-in person'
Assert-Contains $hDoc 'leave that item OUT'      'AH23 an unfilled TODO marker is omitted, never printed or invented'

Section 'video/audio -> the media block (embed the local file), never an <img>'
$wtVid = New-Wt 'video'; Add-Asset $wtVid 'public/assets/reel.mov'; Add-Asset $wtVid 'public/assets/theme.mp3'
$hVid = Add-AssetHint -Prompt $P -Worktree $wtVid -Surface 'web'
Assert-Contains $hVid 'assets/reel.mov'          'AH24 lists the video (a phone .mov, not just .mp4)'
Assert-Contains $hVid 'assets/theme.mp3'         'AH25 lists the audio file'
Assert-Contains $hVid '<video controls'          'AH26 web guidance embeds it with <video>'
Assert-NotContains $hVid '<img src='             'AH27 [kill] a video is never emitted as an <img>'
Assert-NotContains $hVid 'http://'               'AH28 no external URL is ever suggested'

Section 'our own scaffold is not operator material'
# Both exclusions mirror the intake manifest exactly. If this steer named them, it would
# disagree with the plan card the operator actually approved.
$wtSeed = New-Wt 'seeded'
Add-Asset $wtSeed 'assets/README.txt'
Add-Asset $wtSeed 'assets/reference/inspiration.png'
Assert-Eq $P (Add-AssetHint -Prompt $P -Worktree $wtSeed -Surface 'web') 'AH29 [kill] the seeded README and the reference/ subtree are both excluded -> no-op'
Add-Asset $wtSeed 'assets/bio.md'
$hSeed = Add-AssetHint -Prompt $P -Worktree $wtSeed -Surface 'web'
Assert-Contains $hSeed 'assets/bio.md'           'AH30 a real file beside them still lists'
Assert-NotContains $hSeed 'README.txt'           'AH31 [kill] the seeded README stays excluded alongside real files'
Assert-NotContains $hSeed 'inspiration.png'      'AH32 [kill] reference/ stays excluded alongside real files'

Section 'nested assets are found (the manifest walks four deep; this must not be shallower)'
$wtNest = New-Wt 'nested'; Add-Asset $wtNest 'public/assets/photos/portrait.jpg'
$hNest = Add-AssetHint -Prompt $P -Worktree $wtNest -Surface 'web'
Assert-Contains $hNest 'assets/photos/portrait.jpg' 'AH33 [kill] a photo in a subfolder is listed (was invisible when the walk was flat)'

Section 'each file is named ONCE (the mapping lists two spellings of one folder)'
# Found by running the real function against a real project folder, not a fixture: on a
# case-insensitive filesystem 'assets' and 'Assets' are the same directory, so every file was
# listed twice. A 'contains' assertion cannot see that, so this one counts.
$wtDup = New-Wt 'dup'; Add-Asset $wtDup 'assets/bio.md'; Add-Asset $wtDup 'assets/logo.png'
$hDup = Add-AssetHint -Prompt $P -Worktree $wtDup -Surface 'web'
$bioCount = ([regex]::Matches($hDup, [regex]::Escape('/bio.md'))).Count
$logoCount = ([regex]::Matches($hDup, [regex]::Escape('/logo.png'))).Count
Assert-Eq 1 $bioCount  'AH34 [kill] the document is listed exactly once, not once per folder spelling'
Assert-Eq 1 $logoCount 'AH35 [kill] the image is listed exactly once, not once per folder spelling'

Section 'a favicon is wired as a link, not an <img>'
$wtIco = New-Wt 'favicon'; Add-Asset $wtIco 'public/assets/favicon.ico'
$hIco = Add-AssetHint -Prompt $P -Worktree $wtIco -Surface 'web'
Assert-Contains $hIco 'assets/favicon.ico'       'AH36 the .ico is listed (it is a real asset)'
Assert-Contains $hIco 'rel="icon"'               'AH37 [kill] guidance names the <link rel="icon"> form for it'

Section 'SERVED vs NOT SERVED -- a file outside public/ is a 404, and must be copied in'
# The defect this locks (adversarial review, 2026-08-30): a web seed serves public/ AND NOTHING
# ELSE, but every listed file was told "the file is served from public/, so the assets/... path
# resolves". For an operator asset at <project>/assets/ that sentence is false, it contradicts
# the seed's own served-root hint in the same prompt, and the resulting broken <img> STILL
# satisfies the machine floor, which only checks that the filename appears in the markup.
$wtUn = New-Wt 'unserved'; Add-Asset $wtUn 'public/index.html'; Add-Asset $wtUn 'assets/hero.png'
$hUn = Add-AssetHint -Prompt $P -Worktree $wtUn -Surface 'web'
Assert-Contains $hUn 'assets/hero.png'          'AH38 the root-assets image is still listed'
Assert-Contains $hUn 'NOT SERVED'               'AH39 [kill] it is MARKED as outside the served root'
Assert-Contains $hUn 'COPY each one into public/assets/' 'AH40 [kill] and the coder is told to copy it in'
Assert-NotContains $hUn 'so the assets/... path resolves' 'AH41 [kill] the false "it resolves" claim is gone'

$wtSv = New-Wt 'served'; Add-Asset $wtSv 'public/index.html'; Add-Asset $wtSv 'public/assets/hero.png'
$hSv = Add-AssetHint -Prompt $P -Worktree $wtSv -Surface 'web'
Assert-Contains $hSv 'assets/hero.png'          'AH42 a file genuinely under public/ is listed'
Assert-NotContains $hSv 'NOT SERVED'            'AH43 [kill] and is NOT falsely marked unserved'

$wtFlat = New-Wt 'flatsite'; Add-Asset $wtFlat 'assets/hero.png'; Add-Asset $wtFlat 'index.html'
$hFlat = Add-AssetHint -Prompt $P -Worktree $wtFlat -Surface 'web'
Assert-NotContains $hFlat 'NOT SERVED'          'AH44 [kill] a flat site with no public/ serves assets/ from the root'

Section 'both asset dirs present -> both walked, each file distinguishable'
# The dedupe keys on RESOLVED path, so genuinely different directories must BOTH survive it.
$wtBoth = New-Wt 'bothdirs'
Add-Asset $wtBoth 'public/index.html'; Add-Asset $wtBoth 'public/assets/generated.png'; Add-Asset $wtBoth 'assets/operator.png'
$hBoth = Add-AssetHint -Prompt $P -Worktree $wtBoth -Surface 'web'
Assert-Contains $hBoth 'assets/generated.png'   'AH45 the generated asset under public/ is listed'
Assert-Contains $hBoth 'assets/operator.png'    'AH46 the operator asset at the root is listed'
Assert-Contains $hBoth 'copy to public/assets/operator.png' 'AH47 [kill] and only the ROOT one is told to be copied'
Assert-Eq 1 ([regex]::Matches($hBoth, [regex]::Escape('/generated.png'))).Count 'AH48 [kill] the served file is still named exactly once'

Section 'fonts are named (they are machine-graded, so silence is a guaranteed failure)'
# `other` (ttf/otf/woff/woff2) is inside _OPERATOR_ASSET_MARKUP_CLASSES, so the smoke-tier
# operator-assets-floor asserts a font filename appears in the markup. Until 2026-08-30 this
# function skipped fonts entirely: the coder was graded on a file it was never told existed.
$wtFont = New-Wt 'fontonly'; Add-Asset $wtFont 'assets/BrandSans.woff2'
$hFont = Add-AssetHint -Prompt $P -Worktree $wtFont -Surface 'web'
Assert-Contains $hFont 'assets/BrandSans.woff2' 'AH49 [kill] a font-only folder is NOT a no-op'
Assert-Contains $hFont '@font-face'             'AH50 the coder is told how to wire it'
Assert-NotContains $hFont '<img src='           'AH51 [kill] a font is never emitted as an <img>'

Section 'filename hygiene mirrors the intake manifest (card and coder name the SAME files)'
# The manifest filters every path component through an ASCII allowlist and reports the rest to
# the operator as SKIPPED. Without the same filter the card said "5 skipped, rename them" while
# the coder was told to use those exact five. An apostrophe was enough.
$wtName = New-Wt 'names'
Add-Asset $wtName "assets/Blair's CV.pdf"; Add-Asset $wtName 'assets/plain.pdf'
$hName = Add-AssetHint -Prompt $P -Worktree $wtName -Surface 'web'
Assert-Contains $hName 'assets/plain.pdf'       'AH52 a conforming name is listed'
Assert-NotContains $hName 'Blair'               'AH53 [kill] a name the manifest would skip is skipped here too'

Section 'binary documents get an honest exception instead of an impossible order'
$wtBin = New-Wt 'binary'; Add-Asset $wtBin 'assets/CV.pdf'
$hBin = Add-AssetHint -Prompt $P -Worktree $wtBin -Surface 'web'
Assert-Contains $hBin 'binary format you cannot read' 'AH54 the unreadable-format caveat is present'
Assert-Contains $hBin 'An invented value is worse'    'AH55 [kill] and it forbids guessing rather than forbidding the retreat'

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -eq 0) { Write-Host "ALL $($script:Pass) CHECKS PASSED" -ForegroundColor Green; exit 0 }
Write-Host "$($script:Fail) FAILED / $($script:Pass) passed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
