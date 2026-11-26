@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Unity-AAB-Tool.ps1" %*
set "UNITY_AAB_TOOL_EXIT=%errorlevel%"
echo.
if "%~1"=="" pause
exit /b %UNITY_AAB_TOOL_EXIT%
