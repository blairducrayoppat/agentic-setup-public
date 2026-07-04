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
    [string]$OutJson = ''
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

# ---- Seed-only heuristic ----------------------------------------------------
# The unmodified seed has exactly 2 XAML files (App.xaml + MainWindow.xaml),
# one Button, one TextBlock, no styling, no images, no templates.
$seedOnly = ($xamlCount -le 2) -and
            (-not $hasImageAssets) -and
            (-not $usesNonDefaultStyling) -and
            (-not $hasCustomTemplates) -and
            ($controlCount -le 3)   # seed has 1 Button + 1 TextBlock + 1 StackPanel

# ---- Notes string -----------------------------------------------------------
$notesParts = @()
if ($seedOnly)               { $notesParts += "SEED-ONLY: appears unmodified from template (no theming, no images, seed controls only)" }
if ($emojiArtPlaceholder)    { $notesParts += "EMOJI-ART-PLACEHOLDER: emoji used as graphic content (should use real images)" }
if (-not $hasImageAssets -and -not $seedOnly) { $notesParts += "NO-IMAGE-ASSETS: no embedded image files found" }
if (-not $usesNonDefaultStyling -and -not $seedOnly) { $notesParts += "NO-CUSTOM-STYLING: XAML uses no explicit colors/fonts/brushes" }
if ($xamlCount -eq 0)        { $notesParts += "NO-XAML-FILES: no XAML found under $AppDir" }
$notes = if ($notesParts.Count -gt 0) { $notesParts -join '; ' } else { "Design signals present: $controlCount controls, styling applied, image assets=$hasImageAssets" }

# ---- Assemble result --------------------------------------------------------
$result = [ordered]@{
    has_image_assets        = $hasImageAssets
    image_asset_count       = $imageAssetCount
    uses_nondefault_styling = $usesNonDefaultStyling
    emoji_art_placeholder   = $emojiArtPlaceholder
    control_count           = $controlCount
    xaml_file_count         = $xamlCount
    has_custom_templates    = $hasCustomTemplates
    seed_only               = $seedOnly
    notes                   = $notes
}

$json = $result | ConvertTo-Json -Compress
Write-Output $json

if ($OutJson) {
    $dir = Split-Path $OutJson -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Set-Content -Path $OutJson -Value $json -Encoding UTF8
}

exit 0
