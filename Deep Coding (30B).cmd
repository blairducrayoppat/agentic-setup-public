@echo off
title Deep Coding (30B)
echo Starting the DEEP CODING model. The assistant will help free memory if needed.
echo.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1" -Model coder-30b
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1" -Model coder-30b
)
if errorlevel 1 ( echo Something went wrong above - read the message. & pause )
