# Phase 4: Install OpenClaw — PINNED version, hardened BEFORE first start.
# Read BLUEPRINT.md section 5 first. Native-Windows install; migrating the
# gateway into a memory-capped WSL2 distro later is the recommended hardening
# step (configs\wslconfig-snippet.txt).
$ErrorActionPreference = 'Stop'

# Pin: latest verified during research was 2026.6.5. Update this pin deliberately,
# after reading release notes — OpenClaw had 137+ advisories Feb-Apr 2026.
$Pin = '2026.6.5'

Write-Host "== Hardening environment BEFORE install ==" -ForegroundColor Cyan
# Persistent user env vars — effective for all future shells/services
setx OPENCLAW_NO_AUTO_UPDATE 1 | Out-Null
setx OPENCLAW_DISABLE_BONJOUR 1 | Out-Null
setx CLAWHUB_DISABLE_TELEMETRY 1 | Out-Null
$env:OPENCLAW_NO_AUTO_UPDATE='1'; $env:OPENCLAW_DISABLE_BONJOUR='1'; $env:CLAWHUB_DISABLE_TELEMETRY='1'

Write-Host "== Placing hardened config BEFORE install ==" -ForegroundColor Cyan
$dir = Join-Path $env:USERPROFILE '.openclaw'
New-Item -ItemType Directory -Force $dir | Out-Null
$dst = Join-Path $dir 'openclaw.json'
if (Test-Path $dst) { Copy-Item $dst "$dst.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" }
Copy-Item (Join-Path $PSScriptRoot '..\configs\openclaw.json5') $dst -Force

Write-Host "== Installing openclaw@$Pin (pinned) ==" -ForegroundColor Cyan
npm install -g "openclaw@$Pin"
openclaw --version

Write-Host @"

INSTALLED — now finish hardening by hand:
 1. openclaw doctor --generate-gateway-token     (token auth for the loopback gateway)
 2. openclaw security audit --fix                (their built-in checker)
 3. Start the gateway:  openclaw gateway run     (or 'openclaw gateway install' for a Windows service)
 4. Open the WebChat Control UI it prints (loopback URL) — that is your only channel for now.
 5. NEVER run 'clawhub install'. Write skills by hand (BLUEPRINT.md section 5, point 4).
 6. Default model is ovms/qwen3-14b — make sure start-llm.ps1 -Model qwen3-14b is running.
"@ -ForegroundColor Yellow
