# CHECK-ONLY update report. Never installs anything.
# Rule of the house: updates happen deliberately, after reading release notes -
# never 'npm update -g' on autopilot (OpenCode ships several releases a day;
# OpenClaw had 137+ security advisories in two months).
$ErrorActionPreference = 'Continue'
Write-Host "=============== UPDATE CHECK (read-only) ===============" -ForegroundColor Cyan

# OpenCode
$cur = (opencode --version) 2>$null
$latest = (npm view opencode-ai version) 2>$null
Write-Host "OpenCode  : installed $cur / latest $latest"
if ($cur -and $latest -and $cur -ne $latest) { Write-Host "            release notes: https://github.com/anomalyco/opencode/releases" -ForegroundColor Yellow }

# OVMS
$ovmsCur = (& C:\ovms\ovms.exe --version 2>$null | Select-Object -First 1)
try { $rel = Invoke-RestMethod 'https://api.github.com/repos/openvinotoolkit/model_server/releases/latest' -TimeoutSec 10 } catch { $rel = $null }
Write-Host "OVMS      : installed '$ovmsCur' / latest $($rel.tag_name)"
if ($rel) { Write-Host "            release notes: $($rel.html_url)" }

# OpenClaw (if installed)
$ocCur = (openclaw --version) 2>$null
if ($ocCur) {
    $ocLatest = (npm view openclaw version) 2>$null
    Write-Host "OpenClaw  : installed $ocCur / latest $ocLatest"
    Write-Host "            SECURITY-CHECK before any update: https://github.com/openclaw/openclaw/security/advisories" -ForegroundColor Yellow
} else { Write-Host "OpenClaw  : not installed" }

# GPU driver
$drv = (Get-CimInstance Win32_VideoController | Where-Object Name -like '*Arc*').DriverVersion
Write-Host "GPU driver: $drv (known-good: 32.0.101.8826 - keep the installer of a working version before updating)"
Write-Host ""
Write-Host "To update OpenCode deliberately:  npm install -g opencode-ai@<version>  then re-run a coding session to verify." -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
