@echo off
title Harden (Admin, run once)
echo This applies two reversible protections (firewall rule + update active hours).
echo Windows will ask for permission (UAC) - that is expected.
powershell -NoProfile -Command "Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"C:\Users\mrbla\agentic-setup\scripts\elevated-hardening.ps1\"'"
