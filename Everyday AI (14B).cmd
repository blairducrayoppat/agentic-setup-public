@echo off
title Everyday AI (14B)
echo Starting the EVERYDAY model.
echo.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1" -Model qwen3-14b
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1" -Model qwen3-14b
)
if errorlevel 1 ( echo Something went wrong above - read the message. & pause )
