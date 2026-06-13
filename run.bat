@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "wavify.ps1"
pause
