@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0app\AndroidScreenShare.ps1"
