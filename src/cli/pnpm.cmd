@echo off
setlocal
if not defined COREPACK_ENABLE_DOWNLOAD_PROMPT set "COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
if defined COREPACK_HOME if not exist "%COREPACK_HOME%\v1\pnpm\11.7.0\dist\pnpm.mjs" (
  echo pnpm: downloading pnpm 11.7.0 on first use; this may take a minute... 1>&2
)
if defined DSH_NODE (
  "%DSH_NODE%" "%~dp0..\corepack\dist\corepack.js" pnpm@11.7.0 %*
) else (
  node "%~dp0..\corepack\dist\corepack.js" pnpm@11.7.0 %*
)
exit /b %ERRORLEVEL%
