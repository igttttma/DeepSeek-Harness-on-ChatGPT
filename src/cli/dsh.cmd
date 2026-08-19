@echo off
setlocal
if defined DSH_NODE (
  "%DSH_NODE%" "%~dp0..\..\apps\cli\lib\bin.js" %*
) else (
  node "%~dp0..\..\apps\cli\lib\bin.js" %*
)
exit /b %ERRORLEVEL%
