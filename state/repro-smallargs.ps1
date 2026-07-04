# Diagnostic v3: do SMALL-argument tool calls survive a long multi-turn loop,
# while LARGE file-content writes break it? Confirms the "big-argument" trigger.
# Read-only inference against the loaded model, at the REAL OpenCode temp (0.7).
param([double]$Temp = 0.7)
$ErrorActionPreference = 'Stop'
$Endpoint = 'http://127.0.0.1:8000/v3'
$model = (Invoke-RestMethod "$Endpoint/models" -TimeoutSec 5).data[0].id
$tools = @(
  @{ type='function'; function=@{ name='read'; description='Read a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'} }; required=@('filePath') } } },
  @{ type='function'; function=@{ name='glob'; description='Find files by glob pattern.';
     parameters=@{ type='object'; properties=@{ pattern=@{type='string'} }; required=@('pattern') } } },
  @{ type='function'; function=@{ name='bash'; description='Run a shell command.';
     parameters=@{ type='object'; properties=@{ command=@{type='string'} }; required=@('command') } } }
)
$messages = New-Object System.Collections.ArrayList
[void]$messages.Add(@{ role='system'; content='You are a coding agent. Act through the provided tools, one step at a time.' })
[void]$messages.Add(@{ role='user';   content='Investigate this project step by step, ONE tool call per step: (1) glob "*" to list files, (2) read package.json, (3) bash "node --version", (4) glob "src/**", (5) read README.md, (6) bash "git status". Do them in order.' })
$clean=0;$leaks=0
for ($turn=1;$turn -le 8;$turn++){
  $body=@{model=$model;messages=@($messages);tools=$tools;tool_choice='auto';temperature=$Temp;top_p=0.8;max_tokens=512}|ConvertTo-Json -Depth 12
  $m=(Invoke-RestMethod -Uri "$Endpoint/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120).choices[0].message
  $tcs=@($m.tool_calls);$c="$($m.content)"
  $leak=($c -match '"tool_calls"' -or $c -match '<tool_call' -or $c -match 'name\s*=\s*"' -or $c -match '<parameter' -or $c -match '"arguments"\s*:')
  if($leak){$leaks++}; if($tcs.Count -ge 1){$clean++}
  $names=if($tcs.Count -ge 1){($tcs|ForEach-Object{$_.function.name})-join ','}else{'(none)'}
  Write-Host ("T$turn | structured=[{0}] contentChars={1}{2}" -f $names,$c.Trim().Length,$(if($leak){' <<< LEAK'}else{''})) -ForegroundColor $(if($leak){'Red'}elseif($tcs.Count -ge 1){'Green'}else{'Yellow'})
  if($tcs.Count -lt 1 -and -not $leak){Write-Host '   (done/stalled)';break}
  [void]$messages.Add(@{role='assistant';content=$m.content;tool_calls=$tcs})
  foreach($tc in $tcs){[void]$messages.Add(@{role='tool';tool_call_id=$tc.id;content='(small result)'})}
}
Write-Host ("`nSMALL-ARGS temp=$Temp -> clean=$clean leaks=$leaks") -ForegroundColor Cyan
