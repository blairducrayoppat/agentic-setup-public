' Runs the watchdog with no console window flash (Task Scheduler calls this).
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\mrbla\agentic-setup\scripts\watchdog.ps1""", 0, False
