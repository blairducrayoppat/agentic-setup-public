param([Parameter(Mandatory)][string]$Path)
$gf = Join-Path $Path 'greet.py'
if (-not (Test-Path $gf)) { Write-Output 'greet.py missing'; exit 1 }
Push-Location $Path
try { $out = & python -c "from greet import greet; print(greet('World'))" 2>&1; $code = $LASTEXITCODE }
finally { Pop-Location }
if ($code -ne 0) { Write-Output "import/run failed: $out"; exit 1 }
if ((@($out) -join "`n") -match 'Hello, World!') { Write-Output 'greet returns the expected string'; exit 0 }
Write-Output "wrong output: $out"; exit 1
