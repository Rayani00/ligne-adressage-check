@echo off
setlocal EnableDelayedExpansion
REM Lanceur Windows de ligne_full_check.ps1 (contourne la politique d'execution).
REM Usage : run.cmd [SIREN] [false]
REM Apres chaque execution : tapez un autre SIREN pour relancer, ou 'q' pour fermer.

set "args=%*"

:loop
if "!args!"=="" set /p "args=SIREN a verifier (q ou Entree pour quitter) : "
if /i "!args!"=="q" exit /b 0
if "!args!"=="" exit /b 0

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ligne_full_check.ps1" !args! <nul
echo.
echo --- Termine. Tapez un autre SIREN, ou 'q' pour fermer. ---

set "args="
goto loop
