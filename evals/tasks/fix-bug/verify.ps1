param([Parameter(Mandatory)][string]$Path)
Push-Location $Path
try { $out = & python -c "from calc import add; assert add(2,3)==5; print('ok')" 2>&1; $code = $LASTEXITCODE }
finally { Pop-Location }
if ($code -eq 0 -and ((@($out) -join "`n") -match '\bok\b')) { Write-Output 'add(2,3) == 5'; exit 0 }
Write-Output "test still failing: $out"; exit 1
