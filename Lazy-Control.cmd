@echo off
setlocal
cd /d "%~dp0"

set "ACTION=%~1"

if "%ACTION%"=="" goto usage
if not "%~2"=="" goto usage

if /I "%ACTION%"=="install" goto run
if /I "%ACTION%"=="start" goto run
if /I "%ACTION%"=="status" goto run
if /I "%ACTION%"=="stop" goto run
if /I "%ACTION%"=="uninstall" goto run
goto usage

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\lazy-control.ps1" -Action "%~1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  pause
)
exit /b %EXIT_CODE%

:usage
echo Usage: Lazy-Control.cmd install^|start^|status^|stop^|uninstall
echo.
echo   install    Register the current-user logon task and render the lazy tunnel profile.
echo   start      Start the tunnel/proxy supervisor now, without installing auto-start.
echo   status     Show tunnel/proxy/Serena status without exposing secrets.
echo   stop       Stop the tunnel/proxy stack after verifying the managed processes.
echo   uninstall  Remove the logon task, stop the stack, and restore the previous profile.
pause
exit /b 1
