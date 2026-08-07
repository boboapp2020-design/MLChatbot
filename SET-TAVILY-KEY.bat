@echo off
title Set TAVILY_API_KEY - ML Expert AI
color 0B
cls
cd /d "%~dp0"
echo.
echo   ============================================================
echo     TANG KHI TAVILY (KHON NET)  --  ML Expert AI
echo   ============================================================
echo.
echo   khi ni chai hai chatbot khon net tor  mua khlang mai mi kham top
echo   samak free mai tong phuk bat  thi  https://app.tavily.com
echo   khi kho tang khuen ton duai  tvly-
echo.
echo   ------------------------------------------------------------
echo.

if not exist "%~dp0tools\supabase.exe" (
  color 0C
  echo   ERROR - mai jer tools\supabase.exe
  pause
  exit /b 1
)

set /p TKEY=  wang khi laeo kot Enter :
echo.

if "%TKEY%"=="" (
  color 0C
  echo   mai dai sai khi - yok lerk
  pause
  exit /b 1
)

echo   kamlang tang secret ...
"%~dp0tools\supabase.exe" secrets set TAVILY_API_KEY=%TKEY%
set RC=%errorlevel%
set TKEY=

echo.
echo   ------------------------------------------------------------
if %RC% NEQ 0 (color 0C) else (color 0A)
if %RC% NEQ 0 (echo   FAILED - exit code %RC%) else (echo   SUCCESS - bok Claude wa "tang tavily laeo")
echo.
pause
