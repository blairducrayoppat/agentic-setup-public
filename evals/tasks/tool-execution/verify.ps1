param([Parameter(Mandatory)][string]$Path)
# Reliability regression for the malformed-tool-call failure mode.
# The agent can only pass by actually executing a tool to inspect the filesystem
# and writing the correct result. If tool-calling breaks, count.txt is wrong/absent.
$n = (Get-ChildItem -Path $Path -Filter *.log -File -ErrorAction SilentlyContinue).Count
$cf = Join-Path $Path 'count.txt'
if (-not (Test-Path $cf)) {
    Write-Output 'FAIL: count.txt was not created (tool call likely never executed)'
    exit 1
}
$val = (Get-Content $cf -Raw -ErrorAction SilentlyContinue).Trim()
if ($val -match ('^' + [regex]::Escape("$n") + '$')) {
    Write-Output "PASS: count.txt = $n, matches the $n .log files (tools executed and produced correct output)"
    exit 0
}
Write-Output "FAIL: count.txt = '$val' but there are $n .log files in the directory"
exit 1
