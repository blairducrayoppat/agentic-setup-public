# test-guided-gen.ps1 - morning smoke test for tool-call reliability.
# Sends several tool-call requests to whatever model is currently loaded and reports
# how many came back as WELL-FORMED tool calls (correct name + valid JSON arguments
# + the required field present). Use it to decide whether the opt-in
# --enable_tool_guided_generation flag is safe for the everyday/fleet model:
#
#   1) Start the Everyday model NORMALLY:   start-llm.ps1 -Model qwen3-14b
#      .\test-guided-gen.ps1                 # note the score (baseline)
#   2) Start it WITH the guardrail:         start-llm.ps1 -Model qwen3-14b -GuidedGen
#      .\test-guided-gen.ps1                 # compare
#   If guided-gen scores EQUAL-OR-BETTER with no malformed/no-call results, adopt it
#   (launch the Everyday model with -GuidedGen). If it regresses, leave it off.
param(
    [int]$Trials = 5,
    [string]$Endpoint = 'http://127.0.0.1:8000/v3'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$model = Get-LoadedModelId
if (-not $model) { throw "Model server not ready at $Endpoint. Start a model first (e.g. 'Everyday AI 14B')." }
Write-Host "Tool-call smoke test on loaded model: $model  ($Trials trials)" -ForegroundColor Cyan

$tool = @{
    type     = 'function'
    function = @{
        name        = 'get_weather'
        description = 'Get the current weather for a city.'
        parameters  = @{ type = 'object'; properties = @{ city = @{ type = 'string'; description = 'City name' } }; required = @('city') }
    }
}
$prompts = @(
    'What is the weather in Paris right now? Use the get_weather tool.',
    'Check the weather in Tokyo using the tool.',
    'I need the current weather for New York. Call the tool.',
    'Use get_weather to tell me the weather in Berlin.',
    'Weather in Sydney? Use the available tool.'
)

$wellFormed = 0
$details = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $Trials; $i++) {
    $body = @{
        model       = $model
        messages    = @(@{ role = 'user'; content = $prompts[$i % $prompts.Count] })
        tools       = @($tool)
        tool_choice = 'auto'
        temperature = 0.7
        top_p       = 0.8
        max_tokens  = 512
    } | ConvertTo-Json -Depth 8
    try {
        $r = Invoke-RestMethod -Uri "$Endpoint/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
        if (-not $r.choices -or @($r.choices).Count -eq 0) { [void]$details.Add("trial $($i+1): no choices in response"); continue }
        $tc = $r.choices[0].message.tool_calls
        if ($tc -and @($tc).Count -ge 1) {
            $fn = $tc[0].function
            $argsOk = $false; $hasCity = $false
            try { $a = $fn.arguments | ConvertFrom-Json; $argsOk = $true; $hasCity = [bool]$a.city } catch {}
            if ($fn.name -eq 'get_weather' -and $argsOk -and $hasCity) {
                $wellFormed++; [void]$details.Add("trial $($i+1): OK")
            } else {
                [void]$details.Add("trial $($i+1): MALFORMED (name=$($fn.name) argsParse=$argsOk hasCity=$hasCity raw=$($fn.arguments))")
            }
        } else {
            [void]$details.Add("trial $($i+1): no tool_call emitted")
        }
    } catch {
        [void]$details.Add("trial $($i+1): request error - $($_.Exception.Message)")
    }
}

Write-Host ""
$details | ForEach-Object { Write-Host "  $_" }
Write-Host ""
$color = if ($wellFormed -eq $Trials) { 'Green' } elseif ($wellFormed -ge [math]::Ceiling($Trials / 2)) { 'Yellow' } else { 'Red' }
Write-Host ("WELL-FORMED TOOL CALLS: {0}/{1}" -f $wellFormed, $Trials) -ForegroundColor $color
Write-Host "Compare this score with and without 'start-llm.ps1 -GuidedGen' to decide if the guardrail helps." -ForegroundColor Cyan
