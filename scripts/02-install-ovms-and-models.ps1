# Phase 2: Install OpenVINO Model Server (native Windows) + download models.
# Needs internet. Downloads: OVMS (~100-400MB) + Qwen3-Coder-30B INT4 (~17GB).
# Safe to re-run (skips what already exists).
$ErrorActionPreference = 'Stop'

$OvmsDir  = 'C:\ovms'
$ModelDir = 'C:\models'
New-Item -ItemType Directory -Force $ModelDir | Out-Null

# ---------- 1. OVMS ----------
if (Test-Path "$OvmsDir\ovms.exe" -PathType Leaf) {
    Write-Host "OVMS already present at $OvmsDir" -ForegroundColor Green
} else {
    Write-Host "== Downloading latest OpenVINO Model Server release ==" -ForegroundColor Cyan
    $rel = Invoke-RestMethod 'https://api.github.com/repos/openvinotoolkit/model_server/releases/latest'
    Write-Host "Latest release: $($rel.tag_name)"
    # Prefer the python-off windows zip (smaller, no python needed for LLM serving)
    $asset = $rel.assets | Where-Object name -like 'ovms_windows*python_off*' | Select-Object -First 1
    if (-not $asset) { $asset = $rel.assets | Where-Object name -like 'ovms_windows*' | Select-Object -First 1 }
    if (-not $asset) { throw "No ovms_windows asset found in release $($rel.tag_name) — check https://github.com/openvinotoolkit/model_server/releases" }
    $zip = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size/1MB)) MB)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip
    Expand-Archive $zip -DestinationPath 'C:\' -Force   # zip contains an 'ovms' folder
    if (-not (Test-Path "$OvmsDir\ovms.exe")) {
        # some releases nest differently — find ovms.exe and report
        $found = Get-ChildItem C:\ovms* -Recurse -Filter ovms.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { Write-Host "ovms.exe found at $($found.FullName) — adjust scripts if not C:\ovms\ovms.exe" -ForegroundColor Yellow }
        else { throw "ovms.exe not found after extraction — inspect $zip manually" }
    }
    Write-Host "OVMS installed." -ForegroundColor Green
}
& "$OvmsDir\ovms.exe" --version

# ---------- 2. Models ----------
# Downloads use the Hugging Face CLI via uvx (no permanent install needed).
function Get-HFModel($repoId, $alias) {
    $dest = Join-Path $ModelDir $alias
    if (Test-Path (Join-Path $dest '*.xml')) {
        Write-Host "$alias already downloaded." -ForegroundColor Green
        return
    }
    Write-Host "== Downloading $repoId -> $dest ==" -ForegroundColor Cyan
    uvx --from "huggingface_hub[cli]" hf download $repoId --local-dir $dest
    if ($LASTEXITCODE -ne 0) { throw "Download of $repoId failed. Fallback: pip install huggingface_hub[cli]; hf download $repoId --local-dir $dest" }
}

# Primary coder (the big one, ~17GB)
Get-HFModel 'OpenVINO/Qwen3-Coder-30B-A3B-Instruct-int4-ov' 'coder-30b'

# Everyday tier: you ALREADY have Qwen3-14B INT4 on disk (BlarAI). Decoupled copy is optional:
#   Get-HFModel 'OpenVINO/Qwen3-14B-int4-ov' 'qwen3-14b'
# start-llm.ps1 auto-detects the BlarAI copy first; uncomment the line above for independence.

# Vision: you ALREADY have Qwen3-VL-8B INT4 on disk (BlarAI). Optional decoupled copy:
#   Get-HFModel 'OpenVINO/Qwen3-VL-8B-Instruct-int4-ov' 'qwen3-vl-8b'

Write-Host @"

DONE. Next:
  scripts\start-llm.ps1 -Model coder-30b     (run the lean-profile checklist first! BLUEPRINT.md section 1)
"@ -ForegroundColor Cyan
