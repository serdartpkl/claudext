@echo off
rem Opens the ClaudExt browser interface. Double-click it on a machine that
rem has PowerShell 7; when that is missing, it says how to get it.
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
  echo ClaudExt needs PowerShell 7, which is not installed on this machine.
  echo.
  echo Install it with:  winget install --id Microsoft.PowerShell
  echo or download it from https://aka.ms/powershell-release?tag=stable
  echo and run this file again.
  echo.
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui.ps1" %*
if errorlevel 1 pause
