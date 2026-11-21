@echo off
cd /d "%~dp0.."
py -3.14 -c "import tkinter; from compression import zstd" >nul 2>&1
if errorlevel 1 (
  echo Install Python 3.14 from python.org with Tcl/Tk and the Python launcher.
  pause
  exit /b 1
)
start "" pyw -3.14 "%~dp0..\LMCost\windows_app.py"
