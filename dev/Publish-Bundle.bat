@echo off
setlocal

rem Dev-only: stages a release with Publish-Bundle.ps1 in dist\<version> and uploads it to BASE_URL.
rem Usage: Publish-Bundle.bat [version]. Without a version it asks for one.
rem AWS keys come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN), else it asks.

rem Public S3 folder the release is uploaded to. Must end with /.
rem Set it in publish.local.cmd next to this file (not committed), e.g.
rem   set "BASE_URL=https://my-bucket.s3.eu-central-1.amazonaws.com/restic-tool/"
rem or in the RESTIC_TOOL_BASE_URL environment variable, which wins.
set "BASE_URL=https://BUCKET.s3.REGION.amazonaws.com/restic-tool/"
if exist "%~dp0publish.local.cmd" call "%~dp0publish.local.cmd"
if defined RESTIC_TOOL_BASE_URL set "BASE_URL=%RESTIC_TOOL_BASE_URL%"

set "EXIT_CODE=1"

echo %BASE_URL% | findstr /c:"BUCKET.s3.REGION" >nul
if not errorlevel 1 (
    echo Set BASE_URL in %~nx0 first.
    goto done
)

set "VERSION=%~1"
if not defined VERSION set /p "VERSION=Version (e.g. 1.0.0): "
if not defined VERSION (
    echo No version given.
    goto done
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-Bundle.ps1" -Version "%VERSION%" -BaseUrl "%BASE_URL%"
set "EXIT_CODE=%ERRORLEVEL%"

:done
echo.
pause
exit /b %EXIT_CODE%
