@echo off
title Supabase Login - ML Expert AI
color 0B
cls
echo.
echo   ============================================================
echo     SUPABASE LOGIN  --  ML Expert AI
echo   ============================================================
echo.
echo   1. Press ENTER when asked
echo   2. Browser opens - click the Authorize button there
echo   3. Come back here - look for "Finished supabase login"
echo.
echo   ------------------------------------------------------------
echo.
"%~dp0tools\supabase.exe" login
echo.
echo   ------------------------------------------------------------
if errorlevel 1 (color 0C) else (color 0A)
if errorlevel 1 (echo   FAILED - send a screenshot to the assistant) else (echo   SUCCESS - go back to chat and say DONE)
echo.
pause