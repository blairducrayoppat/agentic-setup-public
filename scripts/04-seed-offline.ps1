# Phase 5: Seed offline caches (run while ONLINE; takes a while; safe to re-run).
# Covers: Python wheelhouse, Verdaccio npm registry, pnpm, .NET feed seed, agent docs.
# Manual items NOT scripted (see BLUEPRINT.md section 9): VS Build Tools layout,
# Android Studio/SDK/Gradle seeding, .NET 10 SDK installer, Zeal.
$ErrorActionPreference = 'Continue'   # keep going section-by-section

$Offline = 'C:\offline'
New-Item -ItemType Directory -Force "$Offline\wheelhouse", "$Offline\nuget-feed", "$Offline\docs" | Out-Null

# ---------- 1. Python ----------
Write-Host "`n== [1/5] Python: interpreters + wheelhouse ==" -ForegroundColor Cyan
uv python install 3.12 3.13 3.14
$req = Join-Path $PSScriptRoot '..\configs\requirements-all.txt'
# --with pip: uv-managed interpreters ship WITHOUT pip
# cp312 wheelhouse (the workhorse — OCR/ML wheels are most complete here)
uv run --python 3.12 --with pip -- python -m pip download -r $req -d "$Offline\wheelhouse" --only-binary=:all:
# cp314 wheelhouse (best effort — some packages won't have wheels yet; that's expected)
uv run --python 3.14 --with pip -- python -m pip download -r $req -d "$Offline\wheelhouse" --only-binary=:all:
Write-Host "Wheelhouse done. Offline use:  uv pip install --offline --no-index --find-links $Offline\wheelhouse <pkg>" -ForegroundColor Green
Write-Host "NEVER run 'uv cache clean' — the existing uv cache is your offline safety net." -ForegroundColor Yellow

# ---------- 2. Verdaccio (npm offline backbone) ----------
Write-Host "`n== [2/5] Verdaccio local npm registry ==" -ForegroundColor Cyan
npm install -g verdaccio verdaccio-offline-storage pnpm
# Autostart at logon via Task Scheduler (Verdaccio has no Windows service installer)
$verdaccioCmd = (Get-Command verdaccio.cmd -ErrorAction SilentlyContinue).Source
if ($verdaccioCmd) {
    $action  = New-ScheduledTaskAction -Execute $verdaccioCmd
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'Verdaccio' -Action $action -Trigger $trigger -Force | Out-Null
    Start-ScheduledTask -TaskName 'Verdaccio'
    Start-Sleep 10
} else {
    Write-Host "verdaccio.cmd not found after install — fix the npm global install before continuing." -ForegroundColor Red
}
# Only point npm/pnpm at Verdaccio if it actually answers — otherwise EVERY future
# npm install on this machine breaks until the registry is switched back.
$ping = $null
try { $ping = Invoke-WebRequest 'http://localhost:4873/-/ping' -TimeoutSec 5 -UseBasicParsing } catch {}
if ($ping) {
    npm config set registry http://localhost:4873/
    pnpm config set registry http://localhost:4873/
    Write-Host "npm + pnpm now use the local Verdaccio registry." -ForegroundColor Green
} else {
    Write-Host "Verdaccio is NOT answering at :4873 — registry NOT switched (npm stays on npmjs.org)." -ForegroundColor Red
    Write-Host "Start verdaccio manually and re-run this script. Revert anytime: npm config delete registry" -ForegroundColor Yellow
}
Write-Host @"
Verdaccio at http://localhost:4873 (npm + pnpm now point at it).
MANUAL (important): enable the offline-storage plugin in %APPDATA%\verdaccio\config.yaml:
    store:
      offline-storage: {}
Then SEED by scaffolding each stack once while online (every tarball gets cached):
    npm create vite@latest seed-react -- --template react-ts ; cd seed-react ; npm i ; cd ..
    npx create-next-app@latest seed-next --yes
    npm i -D typescript eslint prettier vitest tailwindcss
"@ -ForegroundColor Yellow

# ---------- 3. .NET feed seed ----------
Write-Host "`n== [3/5] .NET: kitchen-sink NuGet feed ==" -ForegroundColor Cyan
$seed = "$env:TEMP\dotnet-seed"
if (Test-Path $seed) { Remove-Item -Recurse -Force $seed }
dotnet new webapi -o $seed --no-restore
Push-Location $seed
foreach ($p in 'Microsoft.EntityFrameworkCore.Sqlite','Dapper','Serilog.AspNetCore','Swashbuckle.AspNetCore','Polly','xunit','Moq','System.CommandLine') {
    dotnet add package $p 2>$null
}
dotnet restore --packages "$Offline\nuget-feed"
Pop-Location
Write-Host "Feed seeded at $Offline\nuget-feed. Add it in %APPDATA%\NuGet\NuGet.Config; use lockfiles + --locked-mode offline." -ForegroundColor Green
Write-Host "REMINDER: .NET 8 EOL 2026-11-10 — download the .NET 10 SDK offline installer from dotnet.microsoft.com now." -ForegroundColor Yellow

# ---------- 4. Agent-greppable docs ----------
Write-Host "`n== [4/5] Offline docs (Markdown clones — agents grep these) ==" -ForegroundColor Cyan
foreach ($r in @(
    @{u='https://github.com/mdn/content';        d="$Offline\docs\mdn"},
    @{u='https://github.com/dotnet/docs';        d="$Offline\docs\dotnet"},
    @{u='https://github.com/reactjs/react.dev';  d="$Offline\docs\react"},
    @{u='https://github.com/vuejs/docs';         d="$Offline\docs\vue"}
)) {
    if (-not (Test-Path $r.d)) { git clone --depth 1 $r.u $r.d }
}
Write-Host "Python docs: download the PLAIN TEXT archive from docs.python.org/3.12/download.html into $Offline\docs\python" -ForegroundColor Yellow

# ---------- 5. vcpkg asset cache env ----------
Write-Host "`n== [5/5] vcpkg asset-cache environment variable ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force "$Offline\vcpkg-assets" | Out-Null
setx X_VCPKG_ASSET_SOURCES "clear;x-azurl,file:///C:/offline/vcpkg-assets,,readwrite" | Out-Null
Write-Host "Set. When fully offline, append ';x-block-origin' to forbid network." -ForegroundColor Green

Write-Host "`nVERIFY (airplane mode): uv pip install --offline from wheelhouse; npm create vite; dotnet build with a cached package. See BLUEPRINT.md section 9." -ForegroundColor Cyan
