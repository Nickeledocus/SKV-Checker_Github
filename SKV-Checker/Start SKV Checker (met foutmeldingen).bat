@echo off
echo SKV Checker wordt gestart. Foutmeldingen verschijnen in dit venster.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SKV-Checker.ps1"
echo.
echo Het programma is afgesloten. Staat hierboven een rode foutmelding? Kopieer die tekst.
pause

