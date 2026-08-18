@echo off
setlocal
cd /d "%~dp0"

echo Installing/refreshing OpenAI tunnel-client...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if errorlevel 1 (
  echo.
  echo Setup failed. Review the message above.
  pause
  exit /b 1
)

echo.
echo Configure your Tunnel ID and Runtime API key...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure.ps1"
if errorlevel 1 (
  echo.
  echo Configuration failed. You can run Configure.cmd later.
  pause
  exit /b 1
)

echo.
echo ========================================
echo  Setup complete
echo ========================================
echo.
echo Next time, just run Start.cmd
echo.
pause
