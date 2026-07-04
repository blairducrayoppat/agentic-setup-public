# Diagnostic: reproduce the OpenCode multi-turn tool-call breakdown directly against OVMS.
# Read-only inference against the loaded model. Mirrors OpenCode's agentic loop:
# define tools, let the model call one, feed the result back as assistant+tool messages,
# continue. We watch whether turn 2/3 returns a CLEAN structured tool_call or leaks a
# JSON/`name=...` envelope into `content` (the failure the user saw).
$ErrorActionPreference = 'Stop'
$Endpoint = 'http://127.0.0.1:8000/v3'
$model = (Invoke-RestMethod "$Endpoint/models" -TimeoutSec 5).data[0].id
Write-Host "MODEL: $model" -ForegroundColor Cyan

# Three tools, closer to OpenCode's surface than the 1-tool weather smoke test.
$tools = @(
  @{ type='function'; function=@{ name='write'; description='Write text to a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'}; content=@{type='string'} }; required=@('filePath','content') } } },
  @{ type='function'; function=@{ name='read'; description='Read a file.';
     parameters=@{ type='object'; properties=@{ filePath=@{type='string'} }; required=@('filePath') } } },
  @{ type='function'; function=@{ name='bash'; description='Run a shell command.';
     parameters=@{ type='object'; properties=@{ command=@{type='string'}; description=@{type='string'} }; required=@('command') } } }
)

# Conversation seeded to FORCE a multi-step tool sequence (write -> read -> done),
# the exact pattern that broke in the OpenCode session.
$messages = New-Object System.Collections.ArrayList
[void]$messages.Add(@{ role='system'; content='You are a coding agent. Use the provided tools to act. Take one step at a time.' })
[void]$messages.Add(@{ role='user';   content='Create a file hello.txt containing the text "hi there", then read it back to confirm. Use the tools.' })

function Show-Turn($n, $msg) {
  Write-Host "`n===== TURN $n : assistant response =====" -ForegroundColor Yellow
  $hasTC = $msg.tool_calls -and @($msg.tool_calls).Count -ge 1
  Write-Host ("finish/has_tool_calls: structured_tool_calls={0}" -f $hasTC)
  if ($null -ne $msg.content -and "$($msg.content)".Trim().Length -gt 0) {
    Write-Host "--- content (should normally be prose or empty when calling a tool) ---" -ForegroundColor Magenta
    Write-Host $msg.content
    # Leak detectors: the forbidden shapes from AGENTS.md
    $c = "$($msg.content)"
    if ($c -match '"tool_calls"' -or $c -match '<tool_call' -or $c -match 'name\s*=\s*"' -or $c -match '<parameter') {
      Write-Host ">>> LEAK DETECTED: tool-call syntax leaked into content <<<" -ForegroundColor Red
    }
  } else { Write-Host "(content empty)" }
  if ($hasTC) {
    foreach ($tc in $msg.tool_calls) {
      Write-Host ("--- structured tool_call: {0}  args={1}" -f $tc.function.name, $tc.function.arguments) -ForegroundColor Green
    }
  }
}

for ($turn = 1; $turn -le 4; $turn++) {
  $body = @{
    model       = $model
    messages    = @($messages)
    tools       = $tools
    tool_choice = 'auto'
    temperature = 0.7
    top_p       = 0.8
    max_tokens  = 768
  } | ConvertTo-Json -Depth 12
  $r = Invoke-RestMethod -Uri "$Endpoint/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180
  $m = $r.choices[0].message
  Show-Turn $turn $m

  $tcs = @($m.tool_calls)
  if ($tcs.Count -lt 1) { Write-Host "`n(no structured tool call -> loop ends; model is talking, not acting)" -ForegroundColor Yellow; break }

  # Echo the assistant turn back (exactly as an OpenAI client would), then synthesize tool results.
  [void]$messages.Add(@{ role='assistant'; content=$m.content; tool_calls=$tcs })
  foreach ($tc in $tcs) {
    $result = switch ($tc.function.name) {
      'write' { 'File written successfully.' }
      'read'  { 'hi there' }
      'bash'  { '(command output)' }
      default { 'ok' }
    }
    [void]$messages.Add(@{ role='tool'; tool_call_id=$tc.id; content=$result })
  }
}
Write-Host "`n===== DONE =====" -ForegroundColor Cyan
