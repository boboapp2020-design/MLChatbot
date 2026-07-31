@echo off
cd /d "%~dp0"
echo STARTED %date% %time% > "%~dp0push-log.txt"
title Push Knowledge Base to Supabase - ML Expert AI
color 0B
cls
echo.
echo   ============================================================
echo     PUSH TO SUPABASE  --  ML Expert AI
echo   ============================================================
echo.
echo   folder : %cd%
echo.
if not exist "%~dp0tools\supabase.exe" (
  color 0C
  echo   ERROR - mai jer tools\supabase.exe
  echo   ERROR - supabase.exe not found >> "%~dp0push-log.txt"
  echo.
  pause
  exit /b 1
)
echo   chai wela pramarn 5-15 nathi - ya pid natang ni
echo.
echo   ------------------------------------------------------------
echo.
"%~dp0tools\supabase.exe" db push --yes >> "%~dp0push-log.txt" 2>&1
set RC=%errorlevel%
type "%~dp0push-log.txt"
echo.
echo   ------------------------------------------------------------
if %RC% NEQ 0 (color 0C) else (color 0A)
if %RC% NEQ 0 (echo   FAILED - exit code %RC%) else (echo   SUCCESS)
echo   EXITCODE %RC% >> "%~dp0push-log.txt"
echo.
echo   pim DONE nai chat
echo.
pause
