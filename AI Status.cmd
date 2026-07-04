@echo off
title AI Status

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\ai-status.ps1" 
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\ai-status.ps1" 
)
if errorlevel 1 ( echo Something went wrong above - read the message. & pause )
