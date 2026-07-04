@echo off
title Screenshot Vision (8B)
echo Starting the VISION model for screenshots.
echo.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1" -Model vision
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1" -Model vision
)
if errorlevel 1 ( echo Something went wrong above - read the message. & pause )
