@echo off
REM ============================================================================
REM  Coding tool-call fixer (qwen-proxy) for the local coding agent.
REM  Makes Qwen3-Coder-30B's MULTI-TURN tool calling reliable in OpenCode.
REM  OpenCode talks to http://127.0.0.1:8099 ; this forwards to OVMS on :8000,
REM  repairing the tool-call format the model would otherwise garble.
REM
REM  Just double-click this file. Keep the window open while you code.
REM  Close the window (or press Ctrl+C) to stop it. OVMS is NOT affected.
REM ============================================================================
cd /d "%~dp0"

REM If something is already listening on 8099, the fixer is already running.
netstat -ano | findstr /R /C:"127.0.0.1:8099 .*LISTENING" >nul 2>&1
if %errorlevel%==0 (
  echo The tool-call fixer is already running on http://127.0.0.1:8099 - nothing to do.
  echo You can close this window.
  pause
  exit /b 0
)

echo Starting the coding tool-call fixer on http://127.0.0.1:8099 ...
echo Keep this window open while you use the coding agent.  Close it to stop.
echo.
python qwen-proxy.py
echo.
echo The tool-call fixer has stopped.
pause
