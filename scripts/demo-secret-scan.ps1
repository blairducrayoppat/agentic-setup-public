# demo-secret-scan.ps1 - one-command demo of the secret scanner.
# Creates a THROWAWAY repo, plants a FAKE key (you see it BLOCKED), then clean code
# (you see it CLEAN), and cleans up after itself. No typing, nothing to paste wrong.
#   .\demo-secret-scan.ps1
$ErrorActionPreference = 'Continue'
$ss  = Join-Path $PSScriptRoot 'secret-scan.ps1'
$tmp = Join-Path $env:TEMP ("secretscan-demo-" + (Get-Random))
New-Item -ItemType Directory -Force $tmp | Out-Null
git -C $tmp init -q
git -C $tmp -c user.email=demo@local -c user.name=demo commit --allow-empty -q -m start

Write-Host ""
Write-Host "1) Planting a FAKE secret, then scanning the staged change..." -ForegroundColor Cyan
@('-----BEGIN RSA PRIVATE KEY-----',
  'MIIEoFAKEnotARealKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  '-----END RSA PRIVATE KEY-----') | Set-Content "$tmp\config.txt"
git -C $tmp add -A 2>$null
$r1 = & $ss -Repo $tmp
$c1 = if ($r1.status -eq 'blocked') { 'Green' } else { 'Red' }
Write-Host ("   -> status: {0}   ({1})" -f $r1.status, $r1.detail) -ForegroundColor $c1

Write-Host ""
Write-Host "2) Replacing it with ordinary clean code, then scanning again..." -ForegroundColor Cyan
Remove-Item "$tmp\config.txt"
'def add(a, b):  return a + b' | Set-Content "$tmp\app.py"
git -C $tmp add -A 2>$null
$r2 = & $ss -Repo $tmp
$c2 = if ($r2.status -eq 'clean') { 'Green' } else { 'Red' }
Write-Host ("   -> status: {0}" -f $r2.status) -ForegroundColor $c2

Write-Host ""
if ($r1.status -eq 'blocked' -and $r2.status -eq 'clean') {
    Write-Host "RESULT: PASS - the scanner blocks secrets and passes clean code." -ForegroundColor Green
} else {
    Write-Host ("RESULT: unexpected (secret={0}, clean={1}) - tell your assistant." -f $r1.status, $r2.status) -ForegroundColor Yellow
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
