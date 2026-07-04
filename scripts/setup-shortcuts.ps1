# Creates / rebuilds all Start Menu > AI Coding shortcuts with the BlarAI icon.
# Safe to re-run (idempotent).
$ErrorActionPreference = 'Stop'

$root  = 'C:\Users\mrbla\agentic-setup'
$icon  = 'C:\Users\mrbla\blarai\branding\blair_gold.ico,0'
$sm    = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\AI Coding"
$shell = New-Object -ComObject WScript.Shell

New-Item -ItemType Directory -Force $sm | Out-Null

$shortcuts = @(
    @{ Name = 'AI Control Panel';       Cmd = 'AI Control Panel.cmd';      Title = 'AI Control Panel' },
    @{ Name = 'Open Coding Chat';       Cmd = 'Open Coding Chat.cmd';      Title = 'Open Coding Chat' },
    @{ Name = 'Deep Coding (30B)';      Cmd = 'Deep Coding (30B).cmd';     Title = 'Deep Coding 30B' },
    @{ Name = 'Everyday AI (14B)';      Cmd = 'Everyday AI (14B).cmd';     Title = 'Everyday AI 14B' },
    @{ Name = 'Screenshot Vision (8B)'; Cmd = 'Screenshot Vision (8B).cmd';Title = 'Screenshot Vision 8B' },
    @{ Name = 'Stop AI Models';         Cmd = 'Stop AI Models.cmd';        Title = 'Stop AI Models' },
    @{ Name = 'AI Status';              Cmd = 'AI Status.cmd';             Title = 'AI Status' },
    @{ Name = 'GPU Monitor';            Cmd = 'GPU Monitor.cmd';           Title = 'GPU Monitor' },
    @{ Name = 'Undo AI Changes';        Cmd = 'Undo AI Changes.cmd';       Title = 'Undo AI Changes' },
    @{ Name = 'Backup AI Configs';      Cmd = 'Backup AI Configs.cmd';     Title = 'Backup AI Configs' },
    @{ Name = 'Check AI Updates';       Cmd = 'Check AI Updates.cmd';      Title = 'Check AI Updates' },
    @{ Name = 'Harden (Admin, run once)'; Cmd = 'Harden (Admin, run once).cmd'; Title = 'Harden Admin' }
)

foreach ($s in $shortcuts) {
    $target = Join-Path $root $s.Cmd
    if (-not (Test-Path $target)) { Write-Warning "Missing cmd: $target"; continue }
    $lnk = $shell.CreateShortcut("$sm\$($s.Name).lnk")
    $lnk.TargetPath    = $target
    $lnk.IconLocation  = $icon
    $lnk.Description   = $s.Title
    $lnk.Save()
    Write-Host "OK  $($s.Name)" -ForegroundColor Green
}

Write-Host "`nStart Menu shortcuts are up to date." -ForegroundColor Cyan