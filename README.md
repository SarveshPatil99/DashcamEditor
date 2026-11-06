Dashcam Editor
==============

A small app for quick edits to dashcam clips: trim, remove audio, crop, resize, speed up
and stitch clips together. It runs ffmpeg on your PC; nothing is uploaded anywhere.


1. Setup (once)
---------------
The app needs ffmpeg.exe and ffprobe.exe (not included):

  a. Download "ffmpeg-release-essentials.zip" from https://www.gyan.dev/ffmpeg/builds/
  b. From its bin folder, copy ffmpeg.exe and ffprobe.exe into a folder named "bin"
     next to dashcam-gui.ps1:

       DashcamEditor\
         bin\ffmpeg.exe
         bin\ffprobe.exe
         dashcam-gui.ps1
         ...

The app also finds ffmpeg if it is on your PATH or in %USERPROFILE%\tools\ffmpeg\bin.


2. Starting
-----------
Double-click "Start Dashcam Editor.bat". A small console window (the server) and the app
window open. Windows may ask you to confirm running it the first time.

  - Clips: choose the folder at the top left. The menu lists recent folders and any SD
    card or USB drive that is plugged in. "Browse..." opens the Windows folder dialog,
    and subfolders (such as RO for locked clips) appear in the list.
  - The list updates by itself when files are copied in or deleted.
  - Exports go to Videos\Dashcam Editor ("Open folder" in the Exports list).
    Original clips are never changed.
  - The server stops a few minutes after you close the app window, or click Quit.

Options (add them after the .bat name, or to the end of the powershell line inside it):
  -MediaDir E:\DCIM\Movie   start in this folder
  -OutputDir D:\Dashcam     save exports here instead
  -Browser Firefox          use Firefox instead of Edge


3. Keyboard shortcuts
---------------------
  Space     play / pause
  I / O     set trim start / end at the current frame
  P         play the trimmed part
  , / .     step back / forward one frame
  Esc       stop drawing a crop box
