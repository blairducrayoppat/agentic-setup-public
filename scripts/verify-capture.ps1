#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the VLM design-loop capture system (check-design-structural.ps1,
  capture-app.ps1 degrade-chain logic). Tests the pure/decidable parts WITHOUT
  needing a real GUI, display, or built App.exe.

.DESCRIPTION
  Tests:
    SC* -- check-design-structural.ps1 signal detection (file-based, pure)
    DC* -- capture-app.ps1 degrade-chain ordering and fallback decisions
    WI* -- wiring / interface assertions (parameter names, output shape)

  The foreground and headless render tiers require a real WinUI exe and display;
  those are on-hardware-only steps, not unit-testable here.

  Exit 0 if all passed, 1 otherwise.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function _skip($m) { $script:Skip++; Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function Assert-Eq($Expected, $Actual, $Msg)    { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg)               { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True)" } }
function Assert-False($Cond, $Msg)              { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False)" } }
function Assert-Match($Hay, $Pat, $Msg)         { if ([string]$Hay -match $Pat) { _pass $Msg } else { _fail "$Msg (/$Pat/ did not match '$Hay')" } }
function Assert-NoMatch($Hay, $Pat, $Msg)       { if ([string]$Hay -notmatch $Pat) { _pass $Msg } else { _fail "$Msg (/$Pat/ matched '$Hay' unexpectedly)" } }
function Assert-JsonKey($Json, $Key, $Msg)      { $obj = $Json | ConvertFrom-Json; if ($obj.PSObject.Properties.Name -contains $Key) { _pass $Msg } else { _fail "$Msg (key '$Key' missing from JSON: $Json)" } }
function Assert-JsonBool($Json, $Key, $ExpBool, $Msg) {
    $obj = $Json | ConvertFrom-Json
    $val = [bool]$obj.$Key
    if ($val -eq $ExpBool) { _pass $Msg } else { _fail "$Msg (expected $Key=$ExpBool, got $val; JSON: $Json)" }
}
function Assert-JsonInt($Json, $Key, $Min, $Msg) {
    $obj = $Json | ConvertFrom-Json
    $val = [int]$obj.$Key
    if ($val -ge $Min) { _pass $Msg } else { _fail "$Msg (expected $Key >= $Min, got $val; JSON: $Json)" }
}

# Helper: create a temp dir with given XAML content and run the structural check.
function Invoke-StructCheck {
    param([hashtable]$XamlFiles, [string[]]$ImageFiles = @())
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-cap-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        foreach ($kv in $XamlFiles.GetEnumerator()) {
            $p = Join-Path $tmp $kv.Key
            $dir = Split-Path $p -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            Set-Content -Path $p -Value $kv.Value -Encoding UTF8
        }
        foreach ($img in $ImageFiles) {
            $p = Join-Path $tmp $img
            $dir = Split-Path $p -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            Set-Content -Path $p -Value 'fake-image-bytes' -Encoding UTF8
        }
        return & "$ScriptDir\check-design-structural.ps1" -AppDir $tmp 2>&1 | Select-String '^\{' | Select-Object -Last 1
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

$seedXaml = @{
    'App.xaml' = '<Application xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Application.Resources></Application.Resources></Application>'
    'MainWindow.xaml' = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="MinimalWinUI"><StackPanel><TextBlock Text="0" /><Button Content="2 + 3" /></StackPanel></Window>'
}

# =============================================================================
Section 'SC* -- check-design-structural.ps1: seed-only detection'
$seedJson = Invoke-StructCheck -XamlFiles $seedXaml
Assert-True ([bool]$seedJson) 'SC1 structural check produces JSON output'
Assert-JsonBool $seedJson 'seed_only' $true 'SC2 unmodified seed is detected as seed_only=true'
Assert-JsonBool $seedJson 'has_image_assets' $false 'SC3 seed has no image assets'
Assert-JsonBool $seedJson 'uses_nondefault_styling' $false 'SC4 seed uses no non-default styling'
Assert-JsonBool $seedJson 'emoji_art_placeholder' $false 'SC5 seed has no emoji art placeholder'
Assert-JsonInt  $seedJson 'xaml_file_count' 2 'SC6 seed has >= 2 xaml files'
Assert-JsonKey  $seedJson 'notes' 'SC7 JSON has a notes field'

Section 'SC* -- check-design-structural.ps1: image asset detection'
$withImage = Invoke-StructCheck -XamlFiles $seedXaml -ImageFiles @('Assets\rocket.png')
Assert-JsonBool $withImage 'has_image_assets' $true 'SC8 PNG in Assets/ -> has_image_assets=true'

$withSvg = Invoke-StructCheck -XamlFiles $seedXaml -ImageFiles @('Assets\icon.svg', 'Assets\logo.ico')
Assert-JsonBool $withSvg 'has_image_assets' $true 'SC9 SVG+ICO in Assets/ -> has_image_assets=true'

$noImage = Invoke-StructCheck -XamlFiles $seedXaml
Assert-JsonBool $noImage 'has_image_assets' $false 'SC10 no images -> has_image_assets=false'

Section 'SC* -- check-design-structural.ps1: non-default styling detection'
$themedXaml = @{
    'App.xaml' = '<Application xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"></Application>'
    'MainWindow.xaml' = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Grid Background="#FF1A1A2E"><TextBlock Foreground="#FFE94560" FontSize="24" Text="Score" /></Grid></Window>'
}
$themedJson = Invoke-StructCheck -XamlFiles $themedXaml
Assert-JsonBool $themedJson 'uses_nondefault_styling' $true 'SC11 explicit Background/Foreground/FontSize -> uses_nondefault_styling=true'
Assert-JsonBool $themedJson 'seed_only' $false 'SC12 themed XAML is NOT seed_only'

$gradientXaml = @{
    'MainWindow.xaml' = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Window.Resources><LinearGradientBrush x:Key="bg" /></Window.Resources></Window>'
}
$gradientJson = Invoke-StructCheck -XamlFiles $gradientXaml
Assert-JsonBool $gradientJson 'uses_nondefault_styling' $true 'SC13 LinearGradientBrush -> uses_nondefault_styling=true'

Section 'SC* -- check-design-structural.ps1: emoji art anti-pattern detection'
$emojiXaml = @{
    'MainWindow.xaml' = "<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><StackPanel><Button Content='&#x1F680;' /><TextBlock Text='&#x2B50;'/></StackPanel></Window>"
}
# Note: emoji art is detected via regex on unicode ranges; XML numeric entities are NOT the same
# bytes as raw emoji at parse time, so this tests the raw-emoji detection path.
# Build a XAML with a literal emoji byte sequence.
$rawEmojiXaml = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes(
    "<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Button Content='`u{1F680} Launch' /></Window>"
))
$emojiJson = Invoke-StructCheck -XamlFiles @{ 'MainWindow.xaml' = $rawEmojiXaml }
Assert-JsonBool $emojiJson 'emoji_art_placeholder' $true 'SC14 literal emoji in Content attribute -> emoji_art_placeholder=true'

# No emoji in seed.
$noEmojiJson = Invoke-StructCheck -XamlFiles $seedXaml
Assert-JsonBool $noEmojiJson 'emoji_art_placeholder' $false 'SC15 seed has no emoji -> emoji_art_placeholder=false'

Section 'SC* -- check-design-structural.ps1: control count'
$richXaml = @{
    'MainWindow.xaml' = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Grid>
    <StackPanel>
      <Button Content="1" /><Button Content="2" /><Button Content="3" />
      <TextBlock Text="Result" />
      <TextBox PlaceholderText="input" />
      <Image Source="x.png" />
      <ListView /><ComboBox /><CheckBox Content="ok" />
    </StackPanel>
  </Grid>
</Window>
'@
}
$richJson = Invoke-StructCheck -XamlFiles $richXaml
Assert-JsonInt $richJson 'control_count' 8 'SC16 rich XAML has >= 8 controls counted'

Section 'SC* -- check-design-structural.ps1: custom templates'
$templateXaml = @{
    'MainWindow.xaml' = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Window.Resources>
    <DataTemplate x:Key="ItemTmpl"><TextBlock Text="{Binding Name}" /></DataTemplate>
  </Window.Resources>
  <ListView />
</Window>
'@
}
$tmplJson = Invoke-StructCheck -XamlFiles $templateXaml
Assert-JsonBool $tmplJson 'has_custom_templates' $true 'SC17 DataTemplate -> has_custom_templates=true'
Assert-JsonBool (Invoke-StructCheck -XamlFiles $seedXaml) 'has_custom_templates' $false 'SC18 seed has no custom templates'

Section 'SC* -- check-design-structural.ps1: empty / missing directory'
$emptyJson = & "$ScriptDir\check-design-structural.ps1" -AppDir (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))) 2>&1 |
    Select-String '^\{' | Select-Object -Last 1
Assert-True ([bool]$emptyJson) 'SC19 missing AppDir still produces JSON (never-block)'
Assert-JsonBool $emptyJson 'has_image_assets' $false 'SC20 missing dir -> has_image_assets=false'
$emptyObj = ($emptyJson | ConvertFrom-Json)
Assert-True ($emptyObj.xaml_file_count -eq 0) 'SC21 missing dir -> xaml_file_count=0'

Section 'SC* -- check-design-structural.ps1: bin/obj dirs are excluded'
$binXaml = @{
    'bin\x64\net8.0\Main.xaml' = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Grid Background="#FF0000" /></Window>'
    'MainWindow.xaml'           = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock Text="0" /></Window>'
}
$binJson = Invoke-StructCheck -XamlFiles $binXaml
# The bin/ XAML has Background=#FF0000; if it is included it would fire non-default styling.
# Since bin/ is excluded, only MainWindow.xaml (no color) should be seen -> no non-default styling.
Assert-JsonBool $binJson 'uses_nondefault_styling' $false 'SC22 XAML under bin/ is excluded from analysis'

# =============================================================================
Section 'DC* -- capture-app.ps1: degrade-chain ordering in source'
$capSrc = Get-Content "$ScriptDir\capture-app.ps1" -Raw
Assert-True ([regex]::IsMatch($capSrc, '(?ms)TIER 1.*?render-to-file.*?TIER 2.*?foreground.*?TIER 3.*?Structural')) `
    'DC1 source documents tier order: 1=headless -> 2=foreground -> 3=structural'

# Tier 1 must run BEFORE Tier 2 in the code (degrade order).
$iTier1 = $capSrc.IndexOf('--render-to-file')
$iTier2 = $capSrc.IndexOf('capture-app-foreground.ps1')
$iTier3 = $capSrc.IndexOf('check-design-structural.ps1')
Assert-True ($iTier1 -gt 0) 'DC2 Tier 1 --render-to-file present in capture-app.ps1'
Assert-True ($iTier2 -gt 0) 'DC3 Tier 2 capture-app-foreground.ps1 reference present'
Assert-True ($iTier3 -gt 0) 'DC4 Tier 3 check-design-structural.ps1 reference present'
Assert-True ($iTier1 -lt $iTier2) 'DC5 [kill] Tier 1 code runs BEFORE Tier 2 code (degrade order)'
Assert-True ($iTier2 -lt $iTier3) 'DC6 [kill] Tier 2 code runs BEFORE Tier 3 code (degrade order)'

Section 'DC* -- capture-app.ps1: SkipTier1 / SkipTier2 gates in source'
Assert-True ([regex]::IsMatch($capSrc, '(?i)SkipTier1')) 'DC7 capture-app.ps1 has SkipTier1 parameter'
Assert-True ([regex]::IsMatch($capSrc, '(?i)SkipTier2')) 'DC8 capture-app.ps1 has SkipTier2 parameter'
Assert-True ([regex]::IsMatch($capSrc, '(?i)if \(-not \$SkipTier1\)')) 'DC9 [kill] Tier 1 is gated on -not $SkipTier1'
Assert-True ([regex]::IsMatch($capSrc, '(?i)if \(-not \$SkipTier2\)')) 'DC10 [kill] Tier 2 is gated on -not $SkipTier2'

Section 'DC* -- capture-app.ps1: STRUCTURAL_ONLY and JSON output path'
Assert-True ([regex]::IsMatch($capSrc, 'STRUCTURAL_ONLY')) 'DC11 capture-app.ps1 emits STRUCTURAL_ONLY when Tier 3 is used'
Assert-True ([regex]::IsMatch($capSrc, '\$OutPng.*\.json')) 'DC12 [kill] Tier 3 writes JSON to OutPng + ".json" (loop can find it)'

Section 'DC* -- capture-app.ps1: CAPTURE-OK output format'
Assert-True ([regex]::IsMatch($capSrc, 'CAPTURE-OK:.*tier=')) 'DC13 [kill] success output includes "tier=" so the loop can log which tier fired'

Section 'DC* -- capture-app.ps1: PNG validation (magic bytes check)'
Assert-True ([regex]::IsMatch($capSrc, '0x89.*0x50.*0x4E.*0x47')) 'DC14 [kill] Tier 1 success path validates PNG magic bytes before claiming success'

Section 'DC* -- capture-app.ps1: tier 3 always exits 0 (never-block floor)'
Assert-True ([regex]::IsMatch($capSrc, 'exit 0')) 'DC15 capture-app.ps1 has at least one exit 0'
# The Tier 3 block must lead to exit 0, not exit 1.
$t3Block = ($capSrc -split 'TIER 3 --')[1]
Assert-True ($t3Block -match 'exit 0') 'DC16 [kill] the Tier 3 block exits 0 (never-block guarantee)'
Assert-False ($t3Block -match '^exit 1') 'DC17 Tier 3 block does NOT exit 1 (it is the never-block floor)'

Section 'DC* -- capture-app.ps1: end-to-end Tier 3 with -SkipTier1 -SkipTier2 on a real tree'
$e2eDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-e2e-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force $e2eDir | Out-Null
Set-Content (Join-Path $e2eDir 'MainWindow.xaml') '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock Text="hello" /></Window>' -Encoding UTF8
$e2ePng = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-e2e-{0}.png" -f ([guid]::NewGuid().ToString('N')))
try {
    $e2eLines = @(& "$ScriptDir\capture-app.ps1" -AppDir $e2eDir -OutPng $e2ePng -SkipTier1 -SkipTier2 2>&1)
    $e2eExit  = $LASTEXITCODE
    Assert-Eq 0 $e2eExit 'DC18 [end-to-end] capture-app.ps1 -SkipTier1 -SkipTier2 exits 0 (never-block floor)'
    $hasStructOnly = [bool]($e2eLines | Where-Object { $_ -match 'STRUCTURAL_ONLY' })
    Assert-True $hasStructOnly 'DC19 [end-to-end] output contains STRUCTURAL_ONLY when both pixel tiers are skipped'
    $jsonPath = "$e2ePng.json"
    Assert-True (Test-Path $jsonPath) 'DC20 [end-to-end] Tier 3 JSON file is written alongside the PNG path'
    $jsonContent = Get-Content $jsonPath -Raw -Encoding UTF8
    Assert-True ([bool]$jsonContent) 'DC21 [end-to-end] Tier 3 JSON file is non-empty'
    $jsonObj = $jsonContent | ConvertFrom-Json
    Assert-True ($jsonObj.PSObject.Properties.Name -contains 'notes') 'DC22 [end-to-end] Tier 3 JSON has a notes field'
} finally {
    Remove-Item $e2eDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $e2ePng -Force -ErrorAction SilentlyContinue
    Remove-Item "$e2ePng.json" -Force -ErrorAction SilentlyContinue
}

# =============================================================================
Section 'FG* -- capture-app-foreground.ps1: the Add-Type GDI body ACTUALLY COMPILES (not stubbed)'
# THIS IS THE MOCK-PASSES/RUNTIME-FAILS GUARD. The earlier tests stub the capture and
# never run the inline Add-Type, so a pwsh-7 System.Drawing cascade (CS1069 'Bitmap'
# forwarded to System.Drawing.Common) sailed through them. This test drives the REAL
# script with -CompileProbeOnly, which compiles the WinCapture/GDI types and exits --
# so the assembly cascade is exercised end to end. The script self-re-invokes to
# Windows PowerShell 5.1 when run under Core, which is exactly the path the fleet hits.
$probeOut = & "$ScriptDir\capture-app-foreground.ps1" -AppExe 'C:\__nonexistent__\App.exe' -OutPng (Join-Path ([System.IO.Path]::GetTempPath()) 'fg-probe.png') -CompileProbeOnly 2>&1
$probeExit = $LASTEXITCODE
$probeText = ($probeOut | Out-String)
Assert-Eq 0 $probeExit 'FG1 [kill] the GDI Add-Type body COMPILES + runs (probe exit 0) -- catches the pwsh-7 System.Drawing cascade the stubbed tests missed'
Assert-Match $probeText 'COMPILE-OK' 'FG2 [kill] the compile probe reports COMPILE-OK (the WinCapture/Bitmap/Graphics/Size types resolved)'
Assert-NoMatch $probeText 'CS1069' 'FG3 [kill] no CS1069 (Bitmap-forwarded-to-System.Drawing.Common) in the probe output'
Assert-NoMatch $probeText 'CS0012' 'FG4 [kill] no CS0012 (Size/IImage not referenced) in the probe output'

Section 'FG* -- capture-app-foreground.ps1: edition guard + 5.1 re-invoke wiring (source)'
$fgSrc = Get-Content "$ScriptDir\capture-app-foreground.ps1" -Raw
Assert-True ([regex]::IsMatch($fgSrc, "PSEdition -eq 'Core'")) 'FG5 the script detects Core (pwsh 7) at the top'
Assert-True ([regex]::IsMatch($fgSrc, 'WindowsPowerShell\\v1\.0\\powershell\.exe')) 'FG6 [kill] under Core it re-invokes via the 5.1 powershell.exe (NOT pwsh)'
Assert-True ([regex]::IsMatch($fgSrc, "ReferencedAssemblies @\('System\.Drawing'\)")) 'FG7 the 5.1 body references only System.Drawing (the native, no-cascade assembly)'
Assert-True ([regex]::IsMatch($fgSrc, "Add-Type[\s\S]*?-ErrorAction Stop")) 'FG8 [kill] the Add-Type uses -ErrorAction Stop (a compile failure is LOUD, never swallowed into a later confusing type-not-found error)'
# The output contract must be Write-Output (pipeline), not Write-Host, so the contract
# lines survive the pwsh7->5.1 re-invoke and capture-app.ps1 can parse them.
Assert-True ([regex]::IsMatch($fgSrc, 'Write-Output "CAPTURE-FAIL:')) 'FG9 [kill] CAPTURE-FAIL is emitted via Write-Output (survives the re-invoke; capture-app.ps1 parses it)'
Assert-True ([regex]::IsMatch($fgSrc, 'Write-Output "CAPTURE-OK:')) 'FG10 [kill] CAPTURE-OK is emitted via Write-Output (survives the re-invoke)'

Section 'FG* -- capture-app-foreground.ps1: the CAPTURE-FAIL contract survives the re-invoke end to end'
# Drive the REAL script (which re-invokes to 5.1 under Core) with a nonexistent exe.
# It must surface CAPTURE-FAIL through the re-invoke with exit 1 -- proving both the
# contract line AND the exit code propagate across the powershell.exe boundary.
$failOut = & "$ScriptDir\capture-app-foreground.ps1" -AppExe 'C:\__nonexistent__\App.exe' -OutPng (Join-Path ([System.IO.Path]::GetTempPath()) 'fg-fail.png') 2>&1
$failExit = $LASTEXITCODE
$failText = ($failOut | Out-String)
Assert-Eq 1 $failExit 'FG11 [kill] a missing exe yields exit 1 ACROSS the re-invoke (the exit code propagates from 5.1 child back to the pwsh-7 caller)'
Assert-Match $failText 'CAPTURE-FAIL:' 'FG12 [kill] the CAPTURE-FAIL contract line propagates across the re-invoke (capture-app.ps1 sees it)'

# =============================================================================
Section 'WI* -- interface: required parameters present in each script'
# capture-app.ps1
Assert-True ([regex]::IsMatch($capSrc, '\[Parameter\(Mandatory\)\]\[string\]\$AppDir'))   'WI1 capture-app.ps1 has Mandatory -AppDir'
Assert-True ([regex]::IsMatch($capSrc, '\[Parameter\(Mandatory\)\]\[string\]\$OutPng'))   'WI2 capture-app.ps1 has Mandatory -OutPng'
Assert-True ([regex]::IsMatch($capSrc, '\[string\]\$AppExe\s*='))                        'WI3 capture-app.ps1 has optional -AppExe'

# capture-app-foreground.ps1
$fgSrc = Get-Content "$ScriptDir\capture-app-foreground.ps1" -Raw
Assert-True ([regex]::IsMatch($fgSrc, '\[Parameter\(Mandatory\)\]\[string\]\$AppExe'))   'WI4 capture-app-foreground.ps1 has Mandatory -AppExe'
Assert-True ([regex]::IsMatch($fgSrc, '\[Parameter\(Mandatory\)\]\[string\]\$OutPng'))   'WI5 capture-app-foreground.ps1 has Mandatory -OutPng'
Assert-True ([regex]::IsMatch($fgSrc, '\[int\]\$LaunchTimeoutSec'))                      'WI6 capture-app-foreground.ps1 has -LaunchTimeoutSec'

# check-design-structural.ps1
$chkSrc = Get-Content "$ScriptDir\check-design-structural.ps1" -Raw
Assert-True ([regex]::IsMatch($chkSrc, '\[Parameter\(Mandatory\)\]\[string\]\$AppDir'))  'WI7 check-design-structural.ps1 has Mandatory -AppDir'
Assert-True ([regex]::IsMatch($chkSrc, '\[string\]\$OutJson\s*='))                       'WI8 check-design-structural.ps1 has optional -OutJson'

Section 'WI* -- interface: App.xaml.cs headless entry'
$appXamlCs = Get-Content "$PSScriptRoot\..\build-infra\winui\reference\App.xaml.cs" -Raw
Assert-True ([regex]::IsMatch($appXamlCs, '--render-to-file'))       'WI9 App.xaml.cs accepts --render-to-file'
Assert-True ([regex]::IsMatch($appXamlCs, 'RenderTargetBitmap'))     'WI10 App.xaml.cs uses RenderTargetBitmap'
Assert-True ([regex]::IsMatch($appXamlCs, 'BitmapEncoder'))          'WI11 App.xaml.cs uses BitmapEncoder for PNG encoding'
Assert-True ([regex]::IsMatch($appXamlCs, 'SetWindowPos'))           'WI12 App.xaml.cs calls SetWindowPos for off-screen positioning'
Assert-True ([regex]::IsMatch($appXamlCs, 'SW_SHOWNOACTIVATE'))      'WI13 App.xaml.cs uses SW_SHOWNOACTIVATE (no focus steal)'
Assert-True ([regex]::IsMatch($appXamlCs, '-32000'))                 'WI14 App.xaml.cs positions window at -32000 (off-screen convention)'
Assert-True ([regex]::IsMatch($appXamlCs, 'RENDER-OK:'))             'WI15 App.xaml.cs emits RENDER-OK on success (parseable by capture-app.ps1)'
Assert-True ([regex]::IsMatch($appXamlCs, 'RENDER-ERROR:'))          'WI16 App.xaml.cs emits RENDER-ERROR on failure'
Assert-True ([regex]::IsMatch($appXamlCs, 'Application.Current.Exit')) 'WI17 render path calls Exit to self-terminate (no hang)'
# The --test entry must still be present (regression: we must not have broken the existing offline test entry).
Assert-True ([regex]::IsMatch($appXamlCs, '--test'))                 'WI18 [regression] App.xaml.cs still handles --test (offline test entry not removed)'
Assert-True ([regex]::IsMatch($appXamlCs, 'CalculatorTests'))        'WI19 [regression] App.xaml.cs still references CalculatorTests (--test wiring not removed)'

# =============================================================================
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Skip) { Write-Host ("  Skipped: {0}" -f $script:Skip) -ForegroundColor Yellow }
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  VLM CAPTURE SYSTEM: NOT VALIDATED - see [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  VLM CAPTURE SYSTEM: VALIDATED. Structural check pure-logic correct; degrade chain ordered Tier1->2->3; never-block floor proven; interfaces match spec.' -ForegroundColor Green
    exit 0
}
