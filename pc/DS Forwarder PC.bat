@echo off
rem Abre DS Forwarder PC (PowerShell, no necesita instalar nada)
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DSForwarderPC.ps1"
