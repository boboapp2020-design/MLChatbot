@echo off
title Push Knowledge Base to Supabase - ML Expert AI
color 0B
cls
cd /d "%~dp0"
echo.
echo   ============================================================
echo     PUSH TO SUPABASE  --  ML Expert AI
echo   ============================================================
echo.
echo   1. bok Supabase hai luem 003 (khlang khwam ru) lae 004 (persona)
echo      phro song fai ni thuk sang mai thuk khrang thi khlang plian
echo      tae Supabase jam wa "run laeo" lae ja mai run sam
echo.
echo   2. push migration thang mot
echo.
echo   chai wela pramarn 5-15 nathi - ya pid natang ni
echo.
echo   ------------------------------------------------------------
echo.

if not exist "%~dp0tools\supabase.exe" (
  color 0C
  echo   ERROR - mai jer tools\supabase.exe
  pause
  exit /b 1
)

echo   [1/3] repair 003 ...
"%~dp0tools\supabase.exe" migration repair --status reverted 003 --linked
echo.
echo   [2/3] repair 004 ...
"%~dp0tools\supabase.exe" migration repair --status reverted 004 --linked
echo.
echo   [3/3] push ...
rem --include-all jam pen tong sai phro 003/004 yu kon migration lasut (006)
rem tha mai sai ja khuen wa "Found local migration files to be inserted before
rem the last migration" laeo mai run arai loei
"%~dp0tools\supabase.exe" db push --include-all --yes
set RC=%errorlevel%

echo.
echo   ------------------------------------------------------------
if %RC% NEQ 0 (color 0C) else (color 0A)
if %RC% NEQ 0 (echo   FAILED - exit code %RC%) else (echo   SUCCESS)
echo.
echo   pim DONE nai chat
echo.
pause
