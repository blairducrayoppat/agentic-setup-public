# fleet-report.ps1 - aggregate the per-task reports the fleet writes into a plain
# trend so the novice can SEE how nights are going: how many tasks merged vs were
# parked/blocked, and whether the guardrails are firing (test/verify fails, secret
# blocks, loop anomalies). Pure parsing of existing files - offline, read-only.
#
#   .\fleet-report.ps1            # summarize recent task reports
#   .\fleet-report.ps1 -Last 100
param(
    [string]$ReportDir = 'C:\Users\mrbla\agentic-setup\state\reports',
    [int]$Last = 50
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ReportDir)) { Write-Host "No reports yet at $ReportDir (run some tasks first)." -ForegroundColor Yellow; exit 0 }
$files = @(Get-ChildItem $ReportDir -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Last)
if ($files.Count -eq 0) { Write-Host "No task reports found in $ReportDir." -ForegroundColor Yellow; exit 0 }

$merged = 0; $parked = 0; $blocked = 0; $nochange = 0
$testFail = 0; $verifyFail = 0; $secretBlk = 0; $anom = 0
$recent = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    $t = Get-Content $f.FullName -Raw
    $result = ([regex]::Match($t, '(?m)^RESULT:\s*(.*)$')).Groups[1].Value
    # Order matters: "-match" is case-insensitive, and the parked message contains
    # the word "merged" ("NOT merged. ... parked"), so check the specific phrases
    # BEFORE the generic MERGED.
    $outcome = if ($result -match 'BLOCKED') { 'blocked' }
               elseif ($result -match 'NOT merged') { 'parked' }
               elseif ($result -match 'Nothing to merge') { 'no-change' }
               elseif ($result -match 'MERGED') { 'merged' }
               else { 'parked' }
    switch ($outcome) { 'merged' { $merged++ } 'blocked' { $blocked++ } 'no-change' { $nochange++ } default { $parked++ } }
    if ($t -match '(?m)^TESTS:\s*fail') { $testFail++ }
    if ($t -match '(?m)^VERIFY:\s*fail') { $verifyFail++ }
    if ($t -match '(?m)^SECRETS:\s*BLOCKED') { $secretBlk++ }
    if ($t -match '(?m)^ANOMALIES:\s*(?!none)\S') { $anom++ }
    if ($recent.Count -lt 12) { [void]$recent.Add([pscustomobject]@{ when = $f.LastWriteTime.ToString('MM-dd HH:mm'); name = $f.BaseName; outcome = $outcome }) }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("FLEET ACTIVITY  ($($files.Count) most recent task reports)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine("  merged (auto):   $merged")
[void]$sb.AppendLine("  parked (review): $parked")
[void]$sb.AppendLine("  blocked (secret):$blocked")
[void]$sb.AppendLine("  no change made:  $nochange")
[void]$sb.AppendLine('')
[void]$sb.AppendLine("  guardrails fired -> test-fail:$testFail  verify-fail:$verifyFail  secret-block:$secretBlk  loop/anomaly:$anom")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('  recent:')
foreach ($r in $recent) { [void]$sb.AppendLine(("    {0}  {1,-9}  {2}" -f $r.when, $r.outcome, $r.name)) }

$out = $sb.ToString()
Write-Host $out
$savePath = Join-Path (Split-Path $ReportDir -Parent) 'fleet-report.txt'
Set-Content $savePath $out
Write-Host "Saved: $savePath" -ForegroundColor Cyan
