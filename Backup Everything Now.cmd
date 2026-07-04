@echo off
title Backup Everything Now
echo Running full system backup (GitHub + OneDrive + local secrets staging)...
echo.

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\backup-system.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\backup-system.ps1"
)

echo.
if errorlevel 1 ( echo Backup finished WITH FAILURES - read the log above. & pause ) else ( echo Backup OK. & timeout /t 10 )
