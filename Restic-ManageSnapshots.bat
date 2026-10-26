@echo off
setlocal

rem Interactive launcher. Scheduled runs call the .ps1 directly (registered by Setup).
rem Without arguments it opens the main window (-Mode Gui); arguments are passed through.
rem The script and everything it needs live in ResticTools\ next to this file.
rem Full paths: cmd looks in the current folder first, and this folder may be writable by anyone.

rem The script needs administrator rights (VSS and the protected secrets file).
rem Relaunching elevated drops any arguments, so the main window opens.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%SystemRoot%\System32\net.exe" session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    "%PS%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "ARGS=%*"
if not defined ARGS set "ARGS=-Mode Gui"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ResticTools\Restic-ManageSnapshots.ps1" %ARGS%

set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    if "%EXIT_CODE%"=="3" (
        echo Finished with warnings ^(exit code 3^).
    ) else (
        echo Failed with exit code %EXIT_CODE%.
    )
    pause
)

exit /b %EXIT_CODE%
