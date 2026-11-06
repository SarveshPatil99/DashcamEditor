@echo off
rem Starts the Dashcam Editor. Pick the clips folder in the app (it remembers recent ones and
rem lists SD cards); exports go to Videos\Dashcam Editor. Extra arguments are passed through, e.g.
rem   "Start Dashcam Editor.bat" -MediaDir E:\DCIM\Movie
rem   "Start Dashcam Editor.bat" -OutputDir D:\Dashcam
rem   "Start Dashcam Editor.bat" -Browser Firefox
rem To always use Firefox, add  -Browser Firefox  to the end of the powershell line below.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dashcam-gui.ps1" %*
if errorlevel 1 pause
