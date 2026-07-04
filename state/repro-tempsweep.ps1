# Diagnostic v2: does LOW temperature fix the multi-turn tool-call breakdown?
# Replays an OpenCode-like multi-FILE build (the calculator scenario that broke for the user)
# at a given temperature, counting clean structured tool calls vs leaked markup.
# Read-only inference against the loaded model. Pass -Temp 0.7 / 0.1 / 0.0 to compare.
param([double]$Temp = 0.7, [double]$TopP = 0.8, [int]$MaxTurns = 8)
$ErrorActionPreference = 'Stop'
$Endpoint = 'http://127.0.0.1:8000/v3'
$model = (Invoke-RestMethod "$Endpoint/models" -TimeoutSec 5).data[0].id

$tools = @(
  @{ type='function'; function=@{ name='write'; description='Write text to a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'}; content=@{type='string'} }; required=@('filePath','content') } } },
  @{ type='function'; function=@{ name='read'; description='Read a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'} }; required=@('filePath') } } },
  @{ type='function'; function=@{ name='edit'; description='Replace a string in a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'}; oldString=@{type='string'}; newString=@{type='string'} }; required=@('filePath','oldString','newString') } } },
  @{ type='function'; function=@{ name='bash'; description='Run a shell command.';
     parameters=@{ type='object'; properties=@{ command=@{type='string'}; description=@{type='string'} }; required=@('command') } } },
  @{ type='function'; function=@{ name='glob'; description='Find files by glob pattern.';
     parameters=@{ type='object'; properties=@{ pattern=@{type='string'} }; required=@('pattern') } } }
)
$messages = New-Object System.Collections.ArrayList
[void]$messages.Add(@{ role='system'; content='You are a coding agent. Act through the provided tools, one step at a time. After each tool result, take the next step.' })
[void]$messages.Add(@{ role='user';   content='Build a small calculator web app in this folder: create index.html, then style.css, then script.js (each via the write tool). After all three exist, use glob to list them. Do the steps one tool call at a time.' })

$clean = 0; $leaks = 0; $emptyTurns = 0
for ($turn = 1; $turn -le $MaxTurns; $turn++) {
  $body = @{ model=$model; messages=@($messages); tools=$tools; tool_choice='auto'; temperature=$Temp; top_p=$TopP; max_tokens=900 } | ConvertTo-Json -Depth 12
  $r = Invoke-RestMethod -Uri "$Endpoint/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180
  $m = $r.choices[0].message
  $tcs = @($m.tool_calls)
  $c = "$($m.content)"
  $leak = ($c -match '"tool_calls"' -or $c -match '<tool_call' -or $c -match 'name\s*=\s*"' -or $c -match '<parameter' -or $c -match '"arguments"\s*:')
  if ($leak) { $leaks++ }
  if ($tcs.Count -ge 1) { $clean++ }
  $names = if ($tcs.Count -ge 1) { ($tcs | ForEach-Object { $_.function.name }) -join ',' } else { '(none)' }
  $flag = if ($leak) { ' <<< LEAK' } else { '' }
  Write-Host ("T$turn temp=$Temp | structured=[{0}] contentChars={1}{2}" -f $names, $c.Trim().Length, $flag) -ForegroundColor $(if($leak){'Red'}elseif($tcs.Count -ge 1){'Green'}else{'Yellow'})
  if ($leak) { Write-Host "   leaked content tail: ...$($c.Substring([math]::Max(0,$c.Length-160)))" -ForegroundColor DarkGray }
  if ($tcs.Count -lt 1) { $emptyTurns++; if ($emptyTurns -ge 1 -and -not $leak) { Write-Host "   (model stopped calling tools -> done or stalled)"; break } }
  [void]$messages.Add(@{ role='assistant'; content=$m.content; tool_calls=$tcs })
  foreach ($tc in $tcs) {
    $res = switch ($tc.function.name) { 'write'{'File written successfully.'} 'read'{'(file contents)'} 'edit'{'Edit applied.'} 'bash'{'(output)'} 'glob'{'index.html`nstyle.css`nscript.js'} default{'ok'} }
    [void]$messages.Add(@{ role='tool'; tool_call_id=$tc.id; content=$res })
  }
}
Write-Host ("`nRESULT temp=$Temp -> clean_tool_turns=$clean  leak_turns=$leaks") -ForegroundColor Cyan
