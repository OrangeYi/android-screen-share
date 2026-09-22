@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0Update.ps1"
if errorlevel 1 pause
