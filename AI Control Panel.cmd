@echo off
title AI Control Panel

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\control-panel.ps1" 
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\control-panel.ps1" 
)
if errorlevel 1 ( echo Something went wrong above - read the message. & pause )
