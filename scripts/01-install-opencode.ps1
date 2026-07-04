# Phase 1: Install OpenCode + place the global config.
# Safe to re-run.
$ErrorActionPreference = 'Stop'

Write-Host "== Installing OpenCode (opencode-ai) globally via npm ==" -ForegroundColor Cyan
npm install -g opencode-ai
opencode --version

# Global config lives at %USERPROFILE%\.config\opencode\opencode.json (yes, .config on Windows)
$cfgDir = Join-Path $env:USERPROFILE '.config\opencode'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$src = Join-Path $PSScriptRoot '..\configs\opencode.json'
$dst = Join-Path $cfgDir 'opencode.json'
if (Test-Path $dst) {
    Copy-Item $dst "$dst.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Existing opencode.json backed up." -ForegroundColor Yellow
}
Copy-Item $src $dst -Force
Write-Host "Config installed to $dst" -ForegroundColor Green

# Plugins: deploy the fleet opencode plugins to the auto-loaded global plugin dir.
# command-timeout.js hard-caps every bash command's timeout (OPENCODE_BASH_MAX_MS, 5 min
# default) so a single hung command can NEVER eat the agent's 30-min build budget (the
# #676 dotnet-run hang). opencode auto-discovers ~/.config/opencode/plugin/*.js.
$pluginSrc = Join-Path $PSScriptRoot '..\configs\opencode-plugins'
$pluginDst = Join-Path $cfgDir 'plugin'
if (Test-Path $pluginSrc) {
    New-Item -ItemType Directory -Force $pluginDst | Out-Null
    Copy-Item (Join-Path $pluginSrc '*.js') $pluginDst -Force
    Write-Host "Fleet opencode plugins deployed to $pluginDst" -ForegroundColor Green
}

Write-Host @"

NEXT STEPS:
 1. Run scripts\02-install-ovms-and-models.ps1 (needs internet, downloads ~17GB)
 2. Start a model:  scripts\start-llm.ps1 -Model coder-30b
 3. cd into any repo and run:  opencode   (in Windows Terminal — not cmd/git-bash)
 4. Run opencode ONCE while online so it caches the models.dev catalog
    (required for offline starts later — see BLUEPRINT.md section 4).
"@ -ForegroundColor Cyan
