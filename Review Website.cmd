@echo off
REM Review Website.cmd - double-click this to look at a website the coder built (#1343, #1345).
REM
REM Opens the site in your browser next to what the run claimed about it, then walks you through
REM what you asked for one line at a time - your own words - and asks whether the site does it.
REM "I could not tell" is a real answer every time. Your marks and anything else you say are
REM saved against the run so the next iteration can read them.
REM
REM Lives at the repo root on purpose: a deliverable the operator has to go hunting for in a
REM scripts folder is one he will not use.

title Review a website the coder built

set "PS=pwsh"
where pwsh >nul 2>&1 || set "PS=powershell"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\review-website.ps1" %*

echo.
pause
