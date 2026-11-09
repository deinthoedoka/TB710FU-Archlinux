@echo off
setlocal
rem flash.cmd - Windows launcher for flash.ps1.
rem
rem   flash.cmd dual      keep ZUXOS; shrink userdata, create an arch partition
rem   flash.cmd single    erase Android data; rename userdata to arch
rem
rem The PowerShell script elevates itself (firewall + USB network setup need
rem administrator rights).

if "%~1"=="" (
    echo usage: flash.cmd dual^|single
    pause
    exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo Flash failed with exit code %RC%. Read the messages above.
) else (
    echo Flash finished.
)
pause
exit /b %RC%
