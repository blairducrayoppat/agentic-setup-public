# Diagnostic v4: does removing assistant PROSE content from echoed history stop the turn-3 collapse?
# Same calculator multi-file build, temp 0.7. -Strip omits assistant content on echo (content=null),
# keeping only the structured tool_calls. Compare clean/leak counts vs the baseline (content kept).
param([switch]$Strip, [double]$Temp = 0.7)
$ErrorActionPreference = 'Stop'
$Endpoint = 'http://127.0.0.1:8000/v3'
$model = (Invoke-RestMethod "$Endpoint/models" -TimeoutSec 5).data[0].id
$tools = @(
  @{ type='function'; function=@{ name='write'; description='Write text to a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'}; content=@{type='string'} }; required=@('filePath','content') } } },
  @{ type='function'; function=@{ name='glob'; description='Find files by glob pattern.';
     parameters=@{ type='object'; properties=@{ pattern=@{type='string'} }; required=@('pattern') } } }
)
$messages = New-Object System.Collections.ArrayList
[void]$messages.Add(@{ role='system'; content='You are a coding agent. Act through the provided tools, one step at a time.' })
[void]$messages.Add(@{ role='user';   content='Build a calculator web app here: write index.html, then style.css, then script.js, then glob "*" to confirm. One tool call per step.' })
$clean=0;$leaks=0
for ($turn=1;$turn -le 7;$turn++){
  $body=@{model=$model;messages=@($messages);tools=$tools;tool_choice='auto';temperature=$Temp;top_p=0.8;max_tokens=900}|ConvertTo-Json -Depth 12
  $m=(Invoke-RestMethod -Uri "$Endpoint/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180).choices[0].message
  $tcs=@($m.tool_calls);$c="$($m.content)"
  $leak=($c -match '"tool_calls"' -or $c -match '<tool_call' -or $c -match 'name\s*=\s*"' -or $c -match '<parameter' -or $c -match '"arguments"\s*:')
  if($leak){$leaks++}; if($tcs.Count -ge 1){$clean++}
  $names=if($tcs.Count -ge 1){($tcs|ForEach-Object{$_.function.name})-join ','}else{'(none)'}
  Write-Host ("T$turn strip=$Strip | structured=[{0}] contentChars={1}{2}" -f $names,$c.Trim().Length,$(if($leak){' <<< LEAK'}else{''})) -ForegroundColor $(if($leak){'Red'}elseif($tcs.Count -ge 1){'Green'}else{'Yellow'})
  if($tcs.Count -lt 1 -and -not $leak){Write-Host '   (done/stalled)';break}
  if($Strip){ [void]$messages.Add(@{role='assistant';content=$null;tool_calls=$tcs}) }
  else      { [void]$messages.Add(@{role='assistant';content=$m.content;tool_calls=$tcs}) }
  foreach($tc in $tcs){
    $res=switch($tc.function.name){'write'{'File written successfully.'}'glob'{'index.html style.css script.js'}default{'ok'}}
    [void]$messages.Add(@{role='tool';tool_call_id=$tc.id;content=$res})
  }
}
Write-Host ("`nSTRIP=$Strip temp=$Temp -> clean=$clean leaks=$leaks") -ForegroundColor Cyan
