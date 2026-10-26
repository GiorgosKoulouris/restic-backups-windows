@echo off
setlocal

rem Dev-only: installs or updates this machine from the working copy, without S3.
rem Stages dist\local with Publish-Bundle.ps1 -Local and runs that installer (it asks for elevation).
rem Usage: Install-Local.bat [version]. Without a version: dev-<date>-<time>.

set "VERSION_ARG="
if not "%~1"=="" set "VERSION_ARG=-Version "%~1""

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-Bundle.ps1" -Local %VERSION_ARG%
exit /b %ERRORLEVEL%
