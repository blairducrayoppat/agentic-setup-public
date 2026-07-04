# install-gitleaks.ps1 - install the gitleaks secret-scanner, fully offline-safe
# after this one online fetch. Pinned version + SHA-256 verification (no trust in
# "latest"). Idempotent. Sets up an optional git template-dir hook so new repos
# inherit secret scanning.
#
#   .\install-gitleaks.ps1                  # download + verify + install
#   .\install-gitleaks.ps1 -SetGlobalTemplate   # also: new 'git init' repos get the hook
#   .\install-gitleaks.ps1 -Force           # reinstall
#
# gitleaks is a single self-contained Go binary (Apache-2.0). After install it
# runs entirely offline with its embedded ruleset. Nothing here binds a port or
# needs admin.
param(
    [string]$Version = '8.30.1',
    [string]$Sha256  = 'd29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e',
    [switch]$SetGlobalTemplate,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$Setup      = 'C:\Users\mrbla\agentic-setup'
$ToolDir    = Join-Path $Setup 'tools\gitleaks'
$Exe        = Join-Path $ToolDir 'gitleaks.exe'
$TemplateDir = Join-Path $Setup 'configs\gitleaks\git-template'
$asset = "gitleaks_${Version}_windows_x64.zip"
$url   = "https://github.com/gitleaks/gitleaks/releases/download/v$Version/$asset"

if ((Test-Path $Exe) -and -not $Force) {
    Write-Host "gitleaks already installed at $Exe" -ForegroundColor Green
    & $Exe version
} else {
    New-Item -ItemType Directory -Force $ToolDir | Out-Null
    $zip = Join-Path $env:TEMP $asset
    Write-Host "Downloading $asset (one-time, online) ..." -ForegroundColor Cyan
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256.ToLower()) {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        throw "SHA-256 MISMATCH (possible tampering or a corrupt download). expected=$Sha256 actual=$actual. Nothing installed. Re-run to retry; if it keeps mismatching, check your network and the pinned version."
    }
    Write-Host "SHA-256 verified." -ForegroundColor Green
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmpx = Join-Path $env:TEMP ("gl-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpx)
    Copy-Item (Join-Path $tmpx 'gitleaks.exe') $Exe -Force
    Remove-Item $zip, $tmpx -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Installed gitleaks -> $Exe" -ForegroundColor Green
    & $Exe version
}

# Ensure the template-dir hook is executable-ready (the hook file ships in the repo)
$hook = Join-Path $TemplateDir 'hooks\pre-commit'
if (Test-Path $hook) {
    Write-Host "Template hook present: $hook" -ForegroundColor Green
} else {
    Write-Host "WARNING: template hook missing at $hook (expected to ship with the repo)." -ForegroundColor Yellow
}

if ($SetGlobalTemplate) {
    git config --global init.templateDir $TemplateDir
    Write-Host "git init.templateDir -> $TemplateDir" -ForegroundColor Green
    Write-Host "New 'git init' repositories will now inherit the gitleaks pre-commit hook." -ForegroundColor Green
}

Write-Host ""
Write-Host "DONE. Notes:" -ForegroundColor Cyan
Write-Host "  - The overnight fleet (new-agent-task.ps1) already calls the scanner directly; it works as soon as the binary above exists."
Write-Host "  - To protect an EXISTING repo's interactive commits, run:"
Write-Host "      git -C <repo> config core.hooksPath `"$TemplateDir\hooks`"" -ForegroundColor Gray
Write-Host "  - To protect ALL future 'git init' repos, re-run this with -SetGlobalTemplate."
