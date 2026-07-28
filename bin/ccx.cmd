@echo off
REM Managed by https://github.com/migueltorrezd/claudex
set "CCX_LAUNCHER=%~dp0ccx.ps1"
if exist "%~dp0lib\ccx.ps1" set "CCX_LAUNCHER=%~dp0lib\ccx.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CCX_LAUNCHER%" %*
exit /b %ERRORLEVEL%
