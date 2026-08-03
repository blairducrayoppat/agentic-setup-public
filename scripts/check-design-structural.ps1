#requires -Version 5.1
<#
.SYNOPSIS
  Tier-3 structural/static design check: deterministic, no-render inspection of a
  built WinUI app's source and assets for basic design signals.

.DESCRIPTION
  Emits a JSON object with design signals derived from file inspection ONLY -- no
  process launched, no display required. This is the never-block floor: the VLM
  design loop always has SOMETHING even when no pixels can be captured.

  Signals produced (see output schema below):
    has_image_assets         : true if the project contains embedded image files
                               (.png / .jpg / .jpeg / .ico / .svg in the source tree).
    uses_nondefault_styling  : true if any XAML file sets Color, Background,
                               Foreground, FontSize, FontFamily, CornerRadius,
                               or BorderBrush beyond the seed template defaults.
    emoji_art_placeholder    : true if any XAML file contains an emoji character
                               used as a content placeholder (the anti-pattern of
                               "put a rocket emoji where an image should go").
    control_count            : integer count of distinct WinUI control elements
                               found across all .xaml files (Button, TextBlock,
                               Image, Grid, StackPanel, ListBox, ComboBox, etc.).
    xaml_file_count          : number of .xaml files found (0 = red flag).
    has_custom_templates     : true if any XAML file uses a ControlTemplate or
                               DataTemplate.
    seed_only                : true if the project appears to be the unmodified seed
                               (only the two seed XAML files, one seed Button, one
                               TextBlock, no custom colour/font/image).
    notes                    : human-readable summary string for the VLM prompt.

.PARAMETER AppDir
  Directory containing the built project source (the worktree root or the src/ dir
  that contains the .csproj and .xaml files). Can also be a publish/build output
  directory -- the script searches recursively for .xaml files.

.PARAMETER OutJson
  Optional: write the JSON result to this file as well as stdout. Parent dir created
  if absent.

.OUTPUTS
  A single-line JSON object on stdout. Exit 0 always (never-block; structural
  failures are surfaced in the "notes" field, not as a non-zero exit).
#>
param(
    [Parameter(Mandatory)][string]$AppDir,
    [string]$OutJson = '',
    # #1171: the surface the OPERATOR chose at intake -- 'desktop-gui', 'web', 'mobile',
    # 'command-line', 'automation', 'library'. Empty = not supplied (an older caller), which
    # reproduces the pre-#1171 hedge byte-for-byte. See the applicability block below for why
    # this parameter exists at all: the answer is already collected deterministically from a
    # button menu at intake, and this check was the one place still guessing at it.
    [string]$DeclaredSurface = ''
)
$ErrorActionPreference = 'Stop'

# ---- Helpers ----------------------------------------------------------------

function Search-XamlFiles {
    param([string]$Root)
    if (-not (Test-Path $Root)) { return @() }
    # Exclude bin/ obj/ .git worktree debris.
    @(Get-ChildItem -Path $Root -Recurse -Filter '*.xaml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|\.git|\.worktrees)\\' })
}

function Search-ImageAssets {
    param([string]$Root)
    if (-not (Test-Path $Root)) { return 0 }
    $exts = '*.png','*.jpg','*.jpeg','*.ico','*.svg','*.bmp','*.gif','*.tiff','*.webp'
    $count = 0
    foreach ($ext in $exts) {
        $count += @(Get-ChildItem -Path $Root -Recurse -Filter $ext -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(bin|obj|\.git|\.worktrees)\\' }).Count
    }
    return $count
}

# ---- Collect XAML content ---------------------------------------------------

$xamlFiles = Search-XamlFiles -Root $AppDir
$xamlCount = $xamlFiles.Count

$allXaml = ''
foreach ($f in $xamlFiles) {
    try { $allXaml += (Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) + "`n" }
    catch {}
}

# ---- Image assets -----------------------------------------------------------

$imageAssetCount = Search-ImageAssets -Root $AppDir
$hasImageAssets = $imageAssetCount -gt 0

# ---- Non-default styling ----------------------------------------------------
# Look for explicit Color/Background/Foreground/FontSize/FontFamily/CornerRadius
# values that are NOT the seed template's defaults (the seed sets none).
$stylingPatterns = @(
    'Background\s*=\s*"(?!{StaticResource)[^"]{2,}"',    # literal colour
    'Foreground\s*=\s*"(?!{StaticResource)[^"]{2,}"',
    'FontSize\s*=\s*"[^"]{1,}"',
    'FontFamily\s*=\s*"[^"]{1,}"',
    'CornerRadius\s*=\s*"[^"]{1,}"',
    'BorderBrush\s*=\s*"(?!{StaticResource)[^"]{2,}"',
    '<SolidColorBrush\b',
    '<LinearGradientBrush\b',
    '<Style\s',
    'Background="(?:#|Color\.|Colors\.)',
    'Foreground="(?:#|Color\.|Colors\.)'
)
$usesNonDefaultStyling = $false
foreach ($pat in $stylingPatterns) {
    if ($allXaml -match $pat) { $usesNonDefaultStyling = $true; break }
}

# ---- Emoji art anti-pattern -------------------------------------------------
# Any emoji in XAML Content= or Text= attributes is the "put a rocket emoji where
# an image should go" anti-pattern. We scan attribute values for emoji codepoints
# using .NET's [char]::ConvertFromUtf32 to build range characters, since PS 5.1
# regex does not support \x{XXXXXX} syntax in character classes.
# Coverage: Miscellaneous Symbols (U+2600-27BF), Emoticons (U+1F600-1F64F),
#           Misc Symbols and Pictographs (U+1F300-1F5FF), Transport (U+1F680-1F6FF),
#           Supplemental Symbols (U+1F900-1F9FF, U+1FA00-1FAFF).
function Test-HasEmojiInAttr {
    param([string]$XamlContent)
    # Extract all Content= and Text= attribute values (double- or single-quoted).
    $attrValues = [regex]::Matches($XamlContent, '(?:Content|Text)\s*=\s*(?:"([^"]*)"|''([^'']*)'')') |
        ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } }
    foreach ($val in $attrValues) {
        foreach ($ch in $val.ToCharArray()) {
            $cp = [int][char]$ch
            # Supplementary plane emoji use surrogate pairs; check the high surrogate range.
            if (($cp -ge 0xD83C -and $cp -le 0xDBFF)) {
                # High surrogate of a supplementary character -- almost certainly emoji.
                return $true
            }
            # BMP emoji / symbol ranges.
            if (($cp -ge 0x2600 -and $cp -le 0x27BF) -or  # Misc Symbols
                ($cp -ge 0x2B00 -and $cp -le 0x2BFF) -or  # Misc Symbols and Arrows
                ($cp -ge 0xFE00 -and $cp -le 0xFE0F)) {   # Variation Selectors
                return $true
            }
        }
    }
    return $false
}
$emojiArtPlaceholder = Test-HasEmojiInAttr -XamlContent $allXaml

# ---- Control count ----------------------------------------------------------
$controlElements = @(
    'Button','TextBlock','TextBox','Image','Grid','StackPanel','ListBox',
    'ComboBox','CheckBox','RadioButton','Slider','ProgressBar','ProgressRing',
    'ListView','GridView','Canvas','Border','ScrollViewer','TabView','TabBar',
    'NavigationView','AppBarButton','CommandBar','Flyout','MenuFlyout',
    'PersonPicture','RatingControl','NumberBox','AutoSuggestBox','CalendarView',
    'DatePicker','TimePicker','ColorPicker','ContentDialog','Popup','ToggleButton',
    'ToggleSwitch','HyperlinkButton','RepeatButton','SplitButton','DropDownButton',
    'Expander','InfoBar','SplitView','Frame','Page','UserControl','ItemsRepeater',
    'BreadcrumbBar','PipsPager','TeachingTip','TreeView','MapControl',
    'InkCanvas','WebView2','MediaPlayerElement','SwipeControl','RefreshContainer'
)
$controlCount = 0
foreach ($ctrl in $controlElements) {
    # Count opening tags (<Button, <Grid, etc.) across all XAML.
    $controlCount += ([regex]::Matches($allXaml, "<$ctrl\b")).Count
}

# ---- Custom templates -------------------------------------------------------
$hasCustomTemplates = [bool]($allXaml -match '<(?:Control|Data)Template\b')

# ---- Applicability (#1140) ---------------------------------------------------
# EVERY signal below is read out of XAML. With no XAML there is no visual design
# surface to assess, and each signal degenerates to its absent-value: zero images,
# zero styling, zero templates, zero controls -- which is indistinguishable from an
# unmodified WinUI seed. So a Python CLI, a library or a service scored as
# "SEED-ONLY: appears unmodified from template", i.e. the check told the operator a
# fully-built project had never been touched. Observed twice on 2026-07-28 (battery
# runs 20260728-074047-bd and 20260728-110640-bd, card B4, a python command-line
# flashcard app: "SEED-ONLY ...; NO-XAML-FILES: no XAML found").
#
# A check that cannot see its subject must SAY SO rather than report the absence of
# evidence as evidence of absence. Same discipline as the #1133 unserved-asset fix:
# with no way to distinguish the cases, decline instead of inventing a diagnosis.
$designSurfacePresent = $xamlCount -gt 0

# ---- Seed-only heuristic ----------------------------------------------------
# The unmodified seed has exactly 2 XAML files (App.xaml + MainWindow.xaml),
# one Button, one TextBlock, no styling, no images, no templates. Gated on the
# surface existing at all -- "unmodified WinUI seed" is not a statement you can
# make about a project that has no WinUI in it.
$seedOnly = $designSurfacePresent -and
            ($xamlCount -le 2) -and
            (-not $hasImageAssets) -and
            (-not $usesNonDefaultStyling) -and
            (-not $hasCustomTemplates) -and
            ($controlCount -le 3)   # seed has 1 Button + 1 TextBlock + 1 StackPanel

# ---- Notes string -----------------------------------------------------------
if (-not $designSurfacePresent) {
    # One honest line, and NO design verdict. Deliberately does not carry SEED-ONLY,
    # NO-IMAGE-ASSETS or NO-CUSTOM-STYLING: each would read as a finding about the
    # build when it is only a restatement of "this project has no XAML".
    #
    # #1171 -- and it must not GUESS whether the absence matters. The pre-#1171 line ended
    # "only a finding if this project was supposed to have a WinUI front end", which reads
    # as an open question to the one person who cannot answer it from a report. The
    # question is not open: intake ALREADY asks the operator, as a button menu ("On this
    # computer" / "In a web browser" / "On my phone"), and pins the answer on the spec's
    # build_plan.surface. That answer simply never reached this script. So take the
    # declared surface and say the definite thing -- no wording inference anywhere in the
    # chain, because the person already told us.
    # Three-way, and the split is NOT ui-vs-no-ui. THIS check reads XAML, so the only
    # surface whose absence of XAML is a defect is the WinUI one. A `web` build has HTML
    # and no XAML BY CONSTRUCTION -- it is captured by capture-app.ps1's headless browser
    # tier, never this one -- so lumping it in with desktop-gui would have convicted every
    # correctly-built website of missing its own interface. `mobile` likewise.
    $noVisualSurfaces = @('command-line', 'library', 'automation')
    $nonXamlVisual    = @('web', 'mobile')
    $ds = "$DeclaredSurface".Trim().ToLowerInvariant()
    if ($noVisualSurfaces -contains $ds) {
        # Expected by construction: the operator chose a surface that HAS no visual front
        # end. Not a finding, and no hedge -- an absence that was specified is just the spec.
        $notes = "NOT-APPLICABLE: you asked for a $ds project, which has no visual " +
                 "interface to inspect, so the structural design check does not apply " +
                 "and draws NO conclusion about this build."
    } elseif ($nonXamlVisual -contains $ds) {
        # A real visual surface that this check is simply the wrong instrument for. Say
        # which instrument owns it, so "no XAML" never reads as "no interface".
        $notes = "NOT-APPLICABLE: you asked for a $ds project, whose interface is not " +
                 "built from XAML, so this WinUI structural check does not apply and " +
                 "draws NO conclusion about this build (the browser capture tier owns " +
                 "the visual signal for this surface)."
    } elseif ($ds -eq 'desktop-gui') {
        # The one true mismatch: a WinUI desktop app was asked for and there is no XAML in
        # the tree. That IS the finding the old wording could only hypothesise about.
        $notes = "SURFACE-MISSING: you asked for a desktop app with a window, but no XAML " +
                 "UI surface exists under $AppDir -- the build has no desktop interface. " +
                 "This is a genuine mismatch between what was asked for and what was built."
    } else {
        # No surface supplied (older caller, or an 'unknown'/'ambiguous' spec that never got
        # clarified). Keep the pre-#1171 wording EXACTLY: an un-threaded caller must not
        # silently acquire a confident verdict this script has no basis for.
        $notes = "NOT-APPLICABLE: no XAML UI surface under $AppDir, so the structural " +
                 "design check has nothing to assess and draws NO conclusion about this " +
                 "build. Expected for a command-line tool, library or service; only a " +
                 "finding if this project was supposed to have a WinUI front end."
    }
} else {
    $notesParts = @()
    if ($seedOnly)               { $notesParts += "SEED-ONLY: appears unmodified from template (no theming, no images, seed controls only)" }
    if ($emojiArtPlaceholder)    { $notesParts += "EMOJI-ART-PLACEHOLDER: emoji used as graphic content (should use real images)" }
    if (-not $hasImageAssets -and -not $seedOnly) { $notesParts += "NO-IMAGE-ASSETS: no embedded image files found" }
    if (-not $usesNonDefaultStyling -and -not $seedOnly) { $notesParts += "NO-CUSTOM-STYLING: XAML uses no explicit colors/fonts/brushes" }
    $notes = if ($notesParts.Count -gt 0) { $notesParts -join '; ' } else { "Design signals present: $controlCount controls, styling applied, image assets=$hasImageAssets" }
}

# ---- Assemble result --------------------------------------------------------
$result = [ordered]@{
    has_image_assets          = $hasImageAssets
    image_asset_count         = $imageAssetCount
    uses_nondefault_styling   = $usesNonDefaultStyling
    emoji_art_placeholder     = $emojiArtPlaceholder
    control_count             = $controlCount
    xaml_file_count           = $xamlCount
    has_custom_templates      = $hasCustomTemplates
    seed_only                 = $seedOnly
    design_check_applicable   = $designSurfacePresent
    # #1171: what the OPERATOR chose at intake ('' when the caller supplied nothing), and
    # whether a declared visual surface is missing from the build. Emitted so the downstream
    # report states the mismatch as a fact instead of restating the open question.
    declared_surface          = "$DeclaredSurface".Trim().ToLowerInvariant()
    # desktop-gui ONLY: it is the sole surface this XAML-reading check can convict. web /
    # mobile have no XAML by construction and are owned by the browser capture tier.
    surface_missing           = ((-not $designSurfacePresent) -and
                                 ("$DeclaredSurface".Trim().ToLowerInvariant() -eq 'desktop-gui'))
    notes                     = $notes
}

$json = $result | ConvertTo-Json -Compress
Write-Output $json

if ($OutJson) {
    $dir = Split-Path $OutJson -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Set-Content -Path $OutJson -Value $json -Encoding UTF8
}

exit 0
