@echo off
title Set VOYAGE_API_KEY - ML Expert AI
color 0B
cls
cd /d "%~dp0"
echo.
echo   ============================================================
echo     TANG KHI VOYAGE  --  ML Expert AI
echo   ============================================================
echo.
echo   khi ni chai samrap sang embedding hai khlang khwam ru
echo   ao ma jak  https://dashboard.voyageai.com/api-keys
echo   run thi chai khu  voyage-3
echo.
echo   ------------------------------------------------------------
echo.

if not exist "%~dp0tools\supabase.exe" (
  color 0C
  echo   ERROR - mai jer tools\supabase.exe
  pause
  exit /b 1
)

set /p VKEY=  wang khi laeo kot Enter :
echo.

if "%VKEY%"=="" (
  color 0C
  echo   mai dai sai khi - yok lerk
  pause
  exit /b 1
)

echo   kamlang tang secret ...
"%~dp0tools\supabase.exe" secrets set VOYAGE_API_KEY=%VKEY%
set RC=%errorlevel%
set VKEY=

echo.
echo   ------------------------------------------------------------
if %RC% NEQ 0 (color 0C) else (color 0A)
if %RC% NEQ 0 (echo   FAILED - exit code %RC%) else (echo   SUCCESS - bok Claude wa "tang khi laeo")
echo.
pause
