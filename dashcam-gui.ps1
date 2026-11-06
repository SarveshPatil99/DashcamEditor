#Requires -Version 5.1
<#
.SYNOPSIS
  Local browser GUI for quick dashcam edits with ffmpeg: trim, remove audio, crop,
  resize, speed up and stitch.

.DESCRIPTION
  Starts a small web server on http://localhost:<Port>/ (reachable from this PC only),
  opens it in an Edge app window, and runs ffmpeg when you click Export or Stitch.
  Original clips are never modified; results are written to the output folder.

  Every request must carry a random per-session token, so other websites open in your
  browser cannot drive the server. The server stops by itself a few minutes after the
  window is closed (unless a job is still running), or press Ctrl+C in the console.

.PARAMETER MediaDir
  Folder to open first. You can switch folders in the app at any time. Default: the folder
  used last time, or the folder this script is in.

.PARAMETER OutputDir
  Folder for exported files. Default: <your Videos folder>\Dashcam Editor.

.PARAMETER Port
  Preferred port. If it is taken, the next free port is used. Default: 8765.

.PARAMETER FfmpegDir
  Folder containing ffmpeg.exe and ffprobe.exe. Default: searched automatically
  (.\bin, PATH, %USERPROFILE%\tools\ffmpeg\bin, winget links).

.PARAMETER Browser
  Edge (default) opens a clean app window with no tabs or address bar. Firefox opens a
  normal Firefox window. Default uses your default browser.

.PARAMETER NoBrowser
  Do not open a window; just print the URL.

.EXAMPLE
  .\dashcam-gui.ps1

.EXAMPLE
  .\dashcam-gui.ps1 -MediaDir 'E:\DCIM\Movie' -OutputDir 'D:\Videos\Dashcam'
#>
[CmdletBinding()]
param(
  [string]$MediaDir = '',
  [string]$OutputDir = '',
  [ValidateRange(1024, 65535)][int]$Port = 8765,
  [string]$FfmpegDir = '',
  [ValidateSet('Edge', 'Firefox', 'Default')][string]$Browser = 'Edge',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$Invariant = [Globalization.CultureInfo]::InvariantCulture
$VideoExtensions = @('.mp4', '.mov', '.m4v', '.mkv', '.avi')
$ChunkBytes = 2MB          # max bytes per video range response; the player asks for the next range
$StuckWriteSeconds = 30    # drop a video response the browser has stopped reading
$IdleMinutes = 3           # stop after this long without any request from the window
$MaxBodyBytes = 1MB
$MaxRecent = 8             # folders remembered in the folder menu
$CopyCheckMinutes = 30     # only files created or changed this recently are checked for "still copying"
$SettingsPath = Join-Path $env:APPDATA 'DashcamEditor\settings.json'
$GpuLabels = @{
  'h264_qsv'   = 'Intel Quick Sync'
  'h264_nvenc' = 'NVIDIA NVENC'
  'h264_amf'   = 'AMD AMF'
}

# ---------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------

function New-Token {
  $bytes = New-Object byte[] 16
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function New-BadRequest([string]$Message) {
  New-Object ArgumentException $Message
}

function Format-Num([double]$Value) {
  $Value.ToString('0.###', $Invariant)
}

function Get-Opt($Obj, [string]$Name, $Default) {
  if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) {
    return $Obj.$Name
  }
  $Default
}

function ConvertTo-Number($Value, [string]$Name) {
  $parsed = 0.0
  if ($Value -is [string]) {
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, $Invariant, [ref]$parsed)) {
      throw (New-BadRequest "$Name must be a number.")
    }
    return $parsed
  }
  if ($Value -is [ValueType]) { return [double]$Value }
  throw (New-BadRequest "$Name must be a number.")
}

# Quote one argument using the Windows (CommandLineToArgvW) rules.
function Format-Arg([string]$Value) {
  if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($ch in $Value.ToCharArray()) {
    if ($ch -eq [char]'\') { $slashes++; continue }
    if ($ch -eq [char]'"') {
      [void]$sb.Append([char]'\', 2 * $slashes + 1)
    } else {
      [void]$sb.Append([char]'\', $slashes)
    }
    [void]$sb.Append($ch)
    $slashes = 0
  }
  [void]$sb.Append([char]'\', 2 * $slashes)
  [void]$sb.Append('"')
  $sb.ToString()
}

function ConvertTo-ArgString([string[]]$Arguments) {
  ($Arguments | ForEach-Object { Format-Arg $_ }) -join ' '
}

# Run a console program and capture stdout without letting stderr become a terminating error.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Exe @Arguments 2>$null
    [pscustomobject]@{ Output = ($output -join "`n"); ExitCode = $LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Read-Tail([string]$Path, [int]$MaxBytes = 4096) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $share = [IO.FileShare]'ReadWrite, Delete'
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
  try {
    if ($stream.Length -gt $MaxBytes) { $stream.Position = $stream.Length - $MaxBytes }
    (New-Object IO.StreamReader($stream)).ReadToEnd()
  } finally {
    $stream.Dispose()
  }
}

# ---------------------------------------------------------------------------------------
# ffmpeg discovery and media info
# ---------------------------------------------------------------------------------------

function Find-FfmpegDir([string]$Hint) {
  $candidates = New-Object Collections.Generic.List[string]
  if ($Hint) { $candidates.Add($Hint) }
  $candidates.Add((Join-Path $PSScriptRoot 'bin'))
  $onPath = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
  if ($onPath) { $candidates.Add((Split-Path $onPath.Source)) }
  $candidates.Add((Join-Path $env:USERPROFILE 'tools\ffmpeg\bin'))
  $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'))
  foreach ($dir in $candidates) {
    $hasBoth = (Test-Path (Join-Path $dir 'ffmpeg.exe')) -and (Test-Path (Join-Path $dir 'ffprobe.exe'))
    if ($hasBoth) { return $dir }
  }
  $null
}

function Find-GpuEncoder {
  foreach ($encoder in 'h264_qsv', 'h264_nvenc', 'h264_amf') {
    $test = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-f', 'lavfi',
      '-i', 'color=s=640x360:d=0.2', '-c:v', $encoder, '-f', 'null', '-')
    if ((Invoke-Native $App.Ffmpeg $test).ExitCode -eq 0) { return $encoder }
  }
  $null
}

function Assert-Ffmpeg {
  if (-not $App.Ffmpeg) {
    throw (New-BadRequest 'ffmpeg was not found. Install it, then restart the app.')
  }
}

function Get-MediaInfo([string]$Path) {
  Assert-Ffmpeg
  $item = Get-Item -LiteralPath $Path
  $key = '{0}|{1}|{2}' -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks
  if ($App.ProbeCache.ContainsKey($key)) { return $App.ProbeCache[$key] }

  $probeArgs = @('-v', 'error', '-of', 'json', '-show_entries',
    'format=duration:stream=codec_type,codec_name,width,height,r_frame_rate', $item.FullName)
  $result = Invoke-Native $App.Ffprobe $probeArgs
  if ($result.ExitCode -ne 0) { throw (New-BadRequest "ffprobe could not read $($item.Name).") }
  $data = $result.Output | ConvertFrom-Json

  $video = @($data.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
  $audio = @($data.streams | Where-Object { $_.codec_type -eq 'audio' }) | Select-Object -First 1
  if (-not $video) { throw (New-BadRequest "$($item.Name) has no video stream.") }

  $fps = 0.0
  $fpsText = [string]$video.r_frame_rate
  if ($fpsText -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) {
    $fps = [double]$Matches[1] / [double]$Matches[2]
  } else {
    $fpsText = '30'
  }

  $info = [pscustomobject]@{
    duration   = [double]::Parse([string]$data.format.duration, $Invariant)
    width      = [int]$video.width
    height     = [int]$video.height
    fps        = [Math]::Round($fps, 3)
    fpsText    = $fpsText
    videoCodec = [string]$video.codec_name
    audioCodec = if ($audio) { [string]$audio.codec_name } else { '' }
    size       = $item.Length
  }
  $App.ProbeCache[$key] = $info
  $info
}

# ---------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------

function Get-FolderPath([string]$Folder) {
  switch ($Folder) {
    'media' { return $App.MediaDir }
    'output' { return $App.OutputDir }
  }
  throw (New-BadRequest "Unknown folder '$Folder'.")
}

# Map a (folder, file name) pair from the browser to a real path, refusing anything else.
function Resolve-MediaPath([string]$Folder, [string]$Name) {
  $dir = Get-FolderPath $Folder
  $badName = [string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:*?"<>|]' -or $Name -match '^\.+$'
  if ($badName) { throw (New-BadRequest 'Invalid file name.') }
  if ($VideoExtensions -notcontains [IO.Path]::GetExtension($Name).ToLowerInvariant()) {
    throw (New-BadRequest 'Not a supported video file.')
  }
  $path = Join-Path $dir $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw (New-Object IO.FileNotFoundException "File not found: $Name")
  }
  $path
}

function Get-RunningOutputs {
  @($App.Jobs.Values | Where-Object { $_.status -eq 'running' } | ForEach-Object { $_.output })
}

# Full path without a trailing backslash, except for a drive root ("E:\", not "E:").
function Get-CleanDir([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($full)
  if ($full.TrimEnd('\') -eq $root.TrimEnd('\')) { return $root }
  $full.TrimEnd('\')
}

# Video files in $Dir as FileInfo objects. Skips hidden files (including the "._" files
# macOS leaves on SD cards) and outputs of running jobs. Nothing if the folder is missing.
function Get-VideoFiles([string]$Dir) {
  $info = New-Object IO.DirectoryInfo $Dir
  if (-not $info.Exists) { return }
  try { $files = $info.GetFiles() } catch { return }
  $busy = Get-RunningOutputs
  foreach ($file in $files) {
    if ($VideoExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
    if (($file.Attributes -band 2) -or $file.Name.StartsWith('._') -or $busy -contains $file.FullName) { continue }
    $file
  }
}

function Get-Subfolders([string]$Dir) {
  $info = New-Object IO.DirectoryInfo $Dir
  if (-not $info.Exists) { return }
  try { $dirs = $info.GetDirectories() } catch { return }
  $dirs | Where-Object { ([int]$_.Attributes -band 6) -eq 0 } | Sort-Object Name |  # 6 = hidden or system
    ForEach-Object { @{ name = $_.Name; path = $_.FullName } }
}

# A file another program is still writing (for example Explorer copying it in) cannot be
# opened while refusing other writers.
function Test-FileBusy([string]$Path) {
  try {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $stream.Dispose()
    $false
  } catch {
    $true
  }
}

function Get-ClipList {
  $copying = New-Object Collections.Generic.List[string]
  $cutoff = [DateTime]::UtcNow.AddMinutes(-$CopyCheckMinutes)
  foreach ($folder in 'media', 'output') {
    $files = @(Get-VideoFiles (Get-FolderPath $folder)) | Sort-Object Name
    foreach ($file in $files) {
      # Only new files can still be copying. Robocopy stamps unfinished files with 1980.
      $isNew = $file.CreationTimeUtc -gt $cutoff -or $file.LastWriteTimeUtc -gt $cutoff -or $file.LastWriteTimeUtc.Year -lt 1981
      $isCopying = $isNew -and (Test-FileBusy $file.FullName)
      if ($isCopying) { $copying.Add($file.FullName) }
      [pscustomobject]@{
        folder   = $folder
        name     = $file.Name
        size     = $file.Length
        modified = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        copying  = $isCopying
      }
    }
  }
  $App.Copying = $copying.ToArray()
}

# Folders on removable drives (SD cards, USB sticks), preferring the usual dashcam layout.
function Get-CameraFolders {
  foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    if ($drive.DriveType -ne [IO.DriveType]::Removable -or -not $drive.IsReady) { continue }
    $root = $drive.RootDirectory.FullName
    $sub = @('DCIM\Movie', 'DCIM') | Where-Object { [IO.Directory]::Exists([IO.Path]::Combine($root, $_)) } | Select-Object -First 1
    $letter = $root.TrimEnd('\')
    $name = if ($drive.VolumeLabel) { "$letter $($drive.VolumeLabel)" } else { "$letter Removable drive" }
    @{
      label = if ($sub) { "$name - $sub" } else { $name }
      path  = if ($sub) { [IO.Path]::Combine($root, $sub) } else { $root }
    }
  }
}

# A cheap fingerprint of everything the file list shows. The page polls it and reloads the
# list when it changes, so copied, deleted and renamed files show up on their own.
function Get-Stamp {
  $busy = Get-RunningOutputs
  $sb = New-Object Text.StringBuilder
  foreach ($dir in $App.MediaDir, $App.OutputDir) {
    [void]$sb.Append("|$dir")
    $info = New-Object IO.DirectoryInfo $dir
    if (-not $info.Exists) { [void]$sb.Append('|missing'); continue }
    try { $entries = $info.GetFileSystemInfos() } catch { [void]$sb.Append('|unreadable'); continue }
    foreach ($entry in $entries) {
      if ($entry -isnot [IO.FileInfo]) {
        [void]$sb.Append("|<$($entry.Name)>")
      } elseif ($VideoExtensions -contains $entry.Extension.ToLowerInvariant() -and $busy -notcontains $entry.FullName) {
        [void]$sb.Append("|$($entry.Name):$($entry.Length):$($entry.LastWriteTimeUtc.Ticks)")
      }
    }
  }
  foreach ($card in Get-CameraFolders) { [void]$sb.Append("|card:$($card.path)") }
  foreach ($path in $App.Copying) { [void]$sb.Append("|busy:$(Test-FileBusy $path)") }
  [string]$sb.ToString().GetHashCode()
}

function Read-RecentFolders {
  try {
    if (Test-Path -LiteralPath $SettingsPath) {
      $settings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
      return @($settings.recent | Where-Object { $_ -is [string] -and $_ })
    }
  } catch {
    Write-Host "  Could not read $SettingsPath, starting with no recent folders." -ForegroundColor Yellow
  }
  @()
}

function Add-RecentFolder([string]$Path) {
  $list = New-Object Collections.Generic.List[string]
  $list.Add($Path)
  foreach ($old in $App.Recent) {
    if ($list.Count -ge $MaxRecent) { break }
    if ($old -ne $Path) { $list.Add($old) }  # -ne ignores case, like Windows paths
  }
  $App.Recent = $list.ToArray()
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath) | Out-Null
    $json = ConvertTo-Json -InputObject @{ recent = $App.Recent }
    [IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding $false))
  } catch {
    Write-Host "  Could not save recent folders: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

function Set-MediaFolder([string]$Path) {
  $Path = $Path.Trim().Trim('"')
  if (-not $Path) { throw (New-BadRequest 'Enter a folder path.') }
  $isFullPath = $Path -match '^[A-Za-z]:\\' -or $Path.StartsWith('\\')
  if (-not $isFullPath) { throw (New-BadRequest "Use a full path, such as E:\DCIM\Movie.") }
  try { $full = Get-CleanDir $Path } catch { throw (New-BadRequest "'$Path' is not a valid folder path.") }
  if (-not [IO.Directory]::Exists($full)) { throw (New-BadRequest "Folder not found: $full") }
  $App.MediaDir = $full
  Add-RecentFolder $full
  Write-Host "  Clips:   $full"
}

# ---------------------------------------------------------------------------------------
# Folder picker (the standard Windows "Select folder" dialog)
# ---------------------------------------------------------------------------------------

# Compiled on first use. The dialog runs on its own thread so the server keeps answering
# (job progress, video) while it is open. It is owned by an invisible always-on-top window
# so it opens in front of the app window instead of behind it.
$FolderPickerSource = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

public static class DashcamFolderPicker {
  [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
  private class FileOpenDialog { }

  [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IFileDialog {
    [PreserveSig] int Show(IntPtr parent);
    void SetFileTypes(uint count, IntPtr specs);
    void SetFileTypeIndex(uint index);
    void GetFileTypeIndex(out uint index);
    void Advise(IntPtr events, out uint cookie);
    void Unadvise(uint cookie);
    void SetOptions(uint options);
    void GetOptions(out uint options);
    void SetDefaultFolder(IShellItem item);
    void SetFolder(IShellItem item);
    void GetFolder(out IShellItem item);
    void GetCurrentSelection(out IShellItem item);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
    void GetResult(out IShellItem item);
  }

  [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IShellItem {
    void BindToHandler(IntPtr bc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem parent);
    void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
    void GetAttributes(uint mask, out uint attributes);
    void Compare(IShellItem other, uint hint, out int order);
  }

  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  private static extern void SHCreateItemFromParsingName(string path, IntPtr bc,
    [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem item);

  private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint threadId, EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder name, int max);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr processId);
  [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
  [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hwnd);
  [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

  // Windows only lets a background process bring a window to the front in some cases, so
  // the dialog could open behind the browser. Once it is visible, make it always-on-top and
  // borrow the foreground window's input queue to activate it.
  private static bool BringDialogForward(uint thread) {
    IntPtr dialog = IntPtr.Zero;
    EnumThreadWindows(thread, (hwnd, _) => {
      var name = new System.Text.StringBuilder(64);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == "#32770" && IsWindowVisible(hwnd)) { dialog = hwnd; return false; }
      return true;
    }, IntPtr.Zero);
    if (dialog == IntPtr.Zero) return false;
    SetWindowPos(dialog, new IntPtr(-1), 0, 0, 0, 0, 0x0013);  // HWND_TOPMOST; NOSIZE | NOMOVE | NOACTIVATE
    uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    bool attached = foreground != 0 && foreground != thread && AttachThreadInput(thread, foreground, true);
    BringWindowToTop(dialog);
    SetForegroundWindow(dialog);
    if (attached) AttachThreadInput(thread, foreground, false);
    return true;
  }

  private const uint FOS_PICKFOLDERS = 0x20;
  private const uint FOS_FORCEFILESYSTEM = 0x40;
  private const uint FOS_PATHMUSTEXIST = 0x800;
  private const uint SIGDN_FILESYSPATH = 0x80058000;

  // Completes with the chosen folder, or null if the dialog was cancelled.
  public static Task<string> PickAsync(string title, string startFolder) {
    var done = new TaskCompletionSource<string>();
    var thread = new Thread(() => {
      try { done.SetResult(Pick(title, startFolder)); }
      catch (Exception ex) { done.SetException(ex); }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.IsBackground = true;
    thread.Start();
    return done.Task;
  }

  private static string Pick(string title, string startFolder) {
    using (var owner = new Form()) {
      owner.TopMost = true;
      owner.ShowInTaskbar = false;
      owner.FormBorderStyle = FormBorderStyle.None;
      owner.StartPosition = FormStartPosition.CenterScreen;
      owner.Size = new Size(1, 1);
      owner.Opacity = 0;
      owner.Show();
      owner.Activate();
      var dialog = (IFileDialog)new FileOpenDialog();
      try {
        uint options;
        dialog.GetOptions(out options);
        dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
        dialog.SetTitle(title);
        if (!string.IsNullOrEmpty(startFolder) && System.IO.Directory.Exists(startFolder)) {
          try {
            IShellItem start;
            SHCreateItemFromParsingName(startFolder, IntPtr.Zero, typeof(IShellItem).GUID, out start);
            dialog.SetFolder(start);
          } catch (COMException) {
            // Start wherever the dialog likes.
          }
        }
        // The timer ticks inside the dialog's message loop, i.e. once the dialog exists.
        uint thread = GetCurrentThreadId();
        using (var timer = new System.Windows.Forms.Timer()) {
          int tries = 0;
          timer.Interval = 50;
          timer.Tick += (s, e) => { if (BringDialogForward(thread) || ++tries > 40) timer.Stop(); };
          timer.Start();
          if (dialog.Show(owner.Handle) != 0) return null;
        }
        IShellItem item;
        dialog.GetResult(out item);
        string path;
        item.GetDisplayName(SIGDN_FILESYSPATH, out path);
        return path;
      } finally {
        Marshal.ReleaseComObject(dialog);
      }
    }
  }
}
'@

function Start-FolderBrowse {
  if ($App.Browse) { return }  # already open
  if (-not ('DashcamFolderPicker' -as [type])) {
    try {
      Add-Type -TypeDefinition $FolderPickerSource -ReferencedAssemblies System.Windows.Forms, System.Drawing
    } catch {
      Write-Host "Folder picker unavailable: $($_.Exception.Message)" -ForegroundColor Red
      throw (New-BadRequest 'The folder picker is not available on this PC. Choose "Type a path..." in the folder menu instead.')
    }
  }
  $App.Browse = [DashcamFolderPicker]::PickAsync('Choose the folder with your dashcam clips', $App.MediaDir)
}

# Called from the main loop. The page notices the new folder through the stamp.
function Complete-FolderBrowse {
  $task = $App.Browse
  if (-not $task -or -not $task.IsCompleted) { return }
  $App.Browse = $null
  if ($task.IsFaulted) {
    Write-Host "Folder picker failed: $($task.Exception.InnerException.Message)" -ForegroundColor Red
    return
  }
  if (-not $task.Result) { return }  # cancelled
  try {
    Set-MediaFolder $task.Result
  } catch {
    Write-Host "Could not open $($task.Result): $($_.Exception.Message)" -ForegroundColor Red
  }
}

# Pick a fresh output file name; never overwrite an existing file or a running job's output.
function Get-OutputPath([string]$Stem, [string]$Suffix) {
  $busy = Get-RunningOutputs
  $base = '{0}_{1}' -f $Stem, $Suffix
  $path = Join-Path $App.OutputDir "$base.mp4"
  $n = 2
  while ((Test-Path -LiteralPath $path) -or $busy -contains $path) {
    $path = Join-Path $App.OutputDir ('{0}_{1}.mp4' -f $base, $n)
    $n++
  }
  $path
}

# ---------------------------------------------------------------------------------------
# Building ffmpeg commands
# ---------------------------------------------------------------------------------------

function Get-TargetBitrate([int]$Height) {
  if ($Height -ge 1440) { return 16 }
  if ($Height -ge 1080) { return 10 }
  if ($Height -ge 720) { return 6 }
  3
}

function Get-EncoderArgs([string]$Encoder, [int]$Mbps) {
  $rate = @('-b:v', "${Mbps}M", '-maxrate', "$([int]($Mbps * 1.5))M", '-bufsize', "$($Mbps * 2)M")
  switch ($Encoder) {
    'h264_qsv' { return @('-c:v', 'h264_qsv', '-preset', 'medium') + $rate }
    'h264_nvenc' { return @('-c:v', 'h264_nvenc', '-preset', 'p5') + $rate }
    'h264_amf' { return @('-c:v', 'h264_amf', '-quality', 'balanced') + $rate }
  }
  @('-c:v', 'libx264', '-preset', 'fast') + $rate
}

# Pitch-preserving audio speed-up. Each atempo stage is limited to 2x here, so higher
# speeds are chained (8x = atempo=2,atempo=2,atempo=2).
function Get-AtempoFilter([double]$Speed) {
  $stages = New-Object Collections.Generic.List[string]
  $left = $Speed
  while ($left -gt 2.0 + 1e-9) {
    $stages.Add('atempo=2')
    $left /= 2
  }
  if ([Math]::Abs($left - 1) -gt 1e-9) { $stages.Add("atempo=$(Format-Num $left)") }
  $stages -join ','
}

function New-EditPlan($Request) {
  Assert-Ffmpeg
  $source = Resolve-MediaPath (Get-Opt $Request 'folder' '') (Get-Opt $Request 'name' '')
  $info = Get-MediaInfo $source

  # Trim
  $start = ConvertTo-Number (Get-Opt $Request 'start' 0) 'Start'
  $end = ConvertTo-Number (Get-Opt $Request 'end' 0) 'End'
  if ($start -lt 0) { $start = 0 }
  if ($end -le 0 -or $end -gt $info.duration) { $end = $info.duration }
  if ($end - $start -lt 0.1) { throw (New-BadRequest 'The trim end must be after the start.') }
  $isTrimmed = ($start -gt 0.05) -or ($end -lt $info.duration - 0.05)

  # Speed and audio
  $speed = ConvertTo-Number (Get-Opt $Request 'speed' 1) 'Speed'
  if ($speed -lt 1 -or $speed -gt 64) { throw (New-BadRequest 'Speed must be between 1x and 64x.') }
  $hasAudio = [bool]$info.audioCodec
  $muteRequested = (Get-Opt $Request 'mute' $false) -eq $true
  $keepAudio = $hasAudio -and -not $muteRequested

  # Crop, resize and speed filters
  $filters = New-Object Collections.Generic.List[string]
  $tags = New-Object Collections.Generic.List[string]
  if ($isTrimmed) { $tags.Add('trim') }
  if ($hasAudio -and $muteRequested) { $tags.Add('mute') }
  $outHeight = $info.height

  $crop = Get-Opt $Request 'crop' $null
  if ($null -ne $crop) {
    $cx = [int][Math]::Floor((ConvertTo-Number (Get-Opt $crop 'x' 0) 'Crop x'))
    $cy = [int][Math]::Floor((ConvertTo-Number (Get-Opt $crop 'y' 0) 'Crop y'))
    $cw = [int][Math]::Floor((ConvertTo-Number (Get-Opt $crop 'w' 0) 'Crop width'))
    $ch = [int][Math]::Floor((ConvertTo-Number (Get-Opt $crop 'h' 0) 'Crop height'))
    $cx = [Math]::Max(0, [Math]::Min($cx, $info.width - 16))
    $cy = [Math]::Max(0, [Math]::Min($cy, $info.height - 16))
    $cw = [Math]::Min($cw, $info.width - $cx)
    $ch = [Math]::Min($ch, $info.height - $cy)
    $cw -= $cw % 2
    $ch -= $ch % 2
    if ($cw -lt 16 -or $ch -lt 16) { throw (New-BadRequest 'The crop box is too small.') }
    if ($cw -lt $info.width -or $ch -lt $info.height) {
      $filters.Add("crop=${cw}:${ch}:${cx}:${cy}")
      $tags.Add('crop')
      $outHeight = $ch
    }
  }

  $height = [int](ConvertTo-Number (Get-Opt $Request 'height' 0) 'Height')
  if (@(0, 480, 720, 1080, 1440) -notcontains $height) { throw (New-BadRequest 'Unsupported output size.') }
  if ($height -gt 0 -and $height -lt $outHeight) {
    $filters.Add("scale=-2:$height")
    $tags.Add("${height}p")
    $outHeight = $height
  }

  if ($speed -ne 1) {
    $filters.Add("setpts=PTS/$(Format-Num $speed)")
    $filters.Add("fps=$($info.fpsText)")
    $tags.Add("$(Format-Num $speed)x")
  }

  if ($tags.Count -eq 0) {
    throw (New-BadRequest 'Nothing to do yet: set a trim, crop, size or speed, or tick Remove audio.')
  }

  $precise = (Get-Opt $Request 'precise' $false) -eq $true
  $reencode = $filters.Count -gt 0 -or ($precise -and $isTrimmed)
  $useCpu = (Get-Opt $Request 'encoder' 'auto') -eq 'cpu' -or -not $App.GpuEncoder
  $encoder = if ($useCpu) { 'libx264' } else { $App.GpuEncoder }

  # Assemble the command
  $ffArgs = New-Object Collections.Generic.List[string]
  $ffArgs.AddRange([string[]]@('-hide_banner', '-nostdin', '-y'))
  if ($isTrimmed) { $ffArgs.AddRange([string[]]@('-ss', (Format-Num $start), '-to', (Format-Num $end))) }
  $ffArgs.AddRange([string[]]@('-i', $source))
  if ($reencode) {
    if ($filters.Count -gt 0) { $ffArgs.AddRange([string[]]@('-vf', ($filters -join ','))) }
    $mbps = Get-TargetBitrate $outHeight
    $ffArgs.AddRange([string[]](Get-EncoderArgs $encoder $mbps))
    $where = if ($useCpu) { 'CPU (libx264)' } else { "GPU ($($GpuLabels[$encoder]))" }
    $summary = "Re-encode on $where at about $mbps Mbps."
    if ($keepAudio -and $speed -ne 1) {
      $ffArgs.AddRange([string[]]@('-af', (Get-AtempoFilter $speed), '-c:a', 'aac', '-b:a', '160k'))
      $summary += ' Audio is sped up too, keeping its pitch.'
    } elseif ($keepAudio) {
      $ffArgs.AddRange([string[]]@('-c:a', 'copy'))
    }
  } else {
    $ffArgs.AddRange([string[]]@('-c', 'copy'))
    if ($isTrimmed) { $ffArgs.AddRange([string[]]@('-avoid_negative_ts', 'make_zero')) }
    $summary = 'Fast copy with no re-encode, so quality is unchanged.'
    if ($isTrimmed) { $summary += ' Cuts snap to the nearest keyframe.' }
  }
  if (-not $keepAudio -and $hasAudio) { $ffArgs.Add('-an') }
  $output = Get-OutputPath ([IO.Path]::GetFileNameWithoutExtension($source)) ($tags -join '_')
  $ffArgs.AddRange([string[]]@('-movflags', '+faststart', $output))

  @{
    kind     = 'edit'
    label    = 'Edit ' + [IO.Path]::GetFileName($source)
    args     = $ffArgs.ToArray()
    output   = $output
    duration = ($end - $start) / $speed
    mode     = if ($reencode) { 'encode' } else { 'copy' }
    summary  = $summary
    listFile = $null
    listText = $null
  }
}

function New-StitchPlan($Request) {
  Assert-Ffmpeg
  $items = @(Get-Opt $Request 'items' @())
  if ($items.Count -lt 2) { throw (New-BadRequest 'Tick at least two clips to stitch.') }
  if ($items.Count -gt 1000) { throw (New-BadRequest 'Too many clips.') }

  $paths = @(foreach ($item in $items) { Resolve-MediaPath (Get-Opt $item 'folder' '') (Get-Opt $item 'name' '') })
  $infos = @(foreach ($path in $paths) { Get-MediaInfo $path })

  # Joining without re-encoding needs every clip to have the same format.
  $first = $infos[0]
  $describe = { param($i) '{0}x{1} {2} {3}fps audio:{4}' -f $i.width, $i.height, $i.videoCodec, $i.fps, $(if ($i.audioCodec) { $i.audioCodec } else { 'none' }) }
  for ($i = 1; $i -lt $infos.Count; $i++) {
    $other = $infos[$i]
    $same = $other.width -eq $first.width -and $other.height -eq $first.height -and
      $other.videoCodec -eq $first.videoCodec -and $other.fpsText -eq $first.fpsText -and
      $other.audioCodec -eq $first.audioCodec
    if (-not $same) {
      $msg = '{0} ({1}) does not match {2} ({3}). Stitching needs clips with the same camera settings.' -f `
        [IO.Path]::GetFileName($paths[$i]), (& $describe $other), [IO.Path]::GetFileName($paths[0]), (& $describe $first)
      throw (New-BadRequest $msg)
    }
  }

  $mute = (Get-Opt $Request 'mute' $false) -eq $true -and [bool]$first.audioCodec
  $duration = ($infos | Measure-Object -Property duration -Sum).Sum
  $listFile = Join-Path $env:TEMP ('dashcam-concat-{0}.txt' -f (New-Token).Substring(0, 8))
  $listText = ($paths | ForEach-Object { "file '" + $_.Replace("'", "'\''") + "'" }) -join "`n"

  $ffArgs = New-Object Collections.Generic.List[string]
  $ffArgs.AddRange([string[]]@('-hide_banner', '-nostdin', '-y', '-f', 'concat', '-safe', '0', '-i', $listFile, '-c', 'copy'))
  $suffix = "stitch$($items.Count)"
  if ($mute) {
    $ffArgs.Add('-an')
    $suffix += '_mute'
  }
  $output = Get-OutputPath ([IO.Path]::GetFileNameWithoutExtension($paths[0])) $suffix
  $ffArgs.AddRange([string[]]@('-movflags', '+faststart', $output))

  @{
    kind     = 'stitch'
    label    = "Stitch $($items.Count) clips"
    args     = $ffArgs.ToArray()
    output   = $output
    duration = $duration
    mode     = 'copy'
    summary  = 'Fast copy with no re-encode. Total length {0}.' -f ([TimeSpan]::FromSeconds([Math]::Round($duration)).ToString())
    listFile = $listFile
    listText = $listText
  }
}

function New-Plan($Request) {
  switch (Get-Opt $Request 'kind' '') {
    'edit' { return New-EditPlan $Request }
    'stitch' { return New-StitchPlan $Request }
  }
  throw (New-BadRequest 'Unknown request kind.')
}

# The command as shown in the UI, with full paths so it can be pasted into a console.
# Only the temporary stitch list gets a short name.
function Format-CommandLine($Plan) {
  $text = 'ffmpeg ' + (ConvertTo-ArgString $Plan.args)
  if ($Plan.listFile) { $text = $text.Replace($Plan.listFile, 'list.txt') }
  $text
}

function ConvertTo-PlanView($Plan) {
  $view = @{
    kind     = $Plan.kind
    mode     = $Plan.mode
    summary  = $Plan.summary
    output   = [IO.Path]::GetFileName($Plan.output)
    duration = [Math]::Round($Plan.duration, 2)
    command  = Format-CommandLine $Plan
  }
  if ($Plan.listText) { $view.list = $Plan.listText }
  $view
}

# ---------------------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------------------

function Start-FfmpegJob($Plan) {
  $id = (New-Token).Substring(0, 8)
  $temp = Join-Path $env:TEMP "dashcam-$id"
  if ($Plan.listFile) {
    [IO.File]::WriteAllText($Plan.listFile, $Plan.listText + "`n", (New-Object Text.UTF8Encoding $false))
  }
  $runArgs = @('-progress', "$temp-progress.txt", '-nostats', '-loglevel', 'error') + $Plan.args
  $startArgs = @{
    FilePath               = $App.Ffmpeg
    ArgumentList           = ConvertTo-ArgString $runArgs
    NoNewWindow            = $true
    PassThru               = $true
    RedirectStandardError  = "$temp-log.txt"
    RedirectStandardOutput = "$temp-stdout.txt"
  }
  $process = Start-Process @startArgs
  $null = $process.Handle   # keeps ExitCode readable after the process ends

  $job = @{
    id           = $id
    label        = $Plan.label
    output       = $Plan.output
    duration     = $Plan.duration
    process      = $process
    tempFiles    = @("$temp-progress.txt", "$temp-log.txt", "$temp-stdout.txt", $Plan.listFile) | Where-Object { $_ }
    logFile      = "$temp-log.txt"
    progressFile = "$temp-progress.txt"
    status       = 'running'
    percent      = 0.0
    error        = ''
    started      = Get-Date
    finished     = $null
  }
  $App.Jobs[$id] = $job
  Write-Host ('Started   {0} -> {1}' -f $job.label, [IO.Path]::GetFileName($job.output))
  $job
}

function Remove-JobFiles($Job) {
  foreach ($file in $Job.tempFiles) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  }
}

function Update-Job($Job) {
  if ($Job.status -ne 'running') { return }
  $found = [regex]::Matches((Read-Tail $Job.progressFile), 'out_time_us=(\d+)')
  if ($found.Count -gt 0 -and $Job.duration -gt 0) {
    $seconds = [double]$found[$found.Count - 1].Groups[1].Value / 1e6
    $Job.percent = [Math]::Min(99.0, 100 * $seconds / $Job.duration)
  }
  if (-not $Job.process.HasExited) { return }

  $name = [IO.Path]::GetFileName($Job.output)
  if ($Job.process.ExitCode -eq 0 -and (Test-Path -LiteralPath $Job.output)) {
    $Job.status = 'done'
    $Job.percent = 100.0
    Write-Host "Finished  $name" -ForegroundColor Green
  } else {
    $lines = @((Read-Tail $Job.logFile) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 5
    $Job.error = if ($lines) { $lines -join "`n" } else { "ffmpeg exited with code $($Job.process.ExitCode)." }
    $Job.status = 'failed'
    Remove-Item -LiteralPath $Job.output -Force -ErrorAction SilentlyContinue
    Write-Host "Failed    $name`n$($Job.error)" -ForegroundColor Red
  }
  $Job.finished = Get-Date
  Remove-JobFiles $Job
}

function Stop-FfmpegJob($Job) {
  Update-Job $Job
  if ($Job.status -ne 'running') { return }
  if (-not $Job.process.HasExited) {
    $Job.process.Kill()
    [void]$Job.process.WaitForExit(5000)
  }
  $Job.status = 'cancelled'
  $Job.finished = Get-Date
  Remove-Item -LiteralPath $Job.output -Force -ErrorAction SilentlyContinue
  Remove-JobFiles $Job
  Write-Host "Cancelled $([IO.Path]::GetFileName($Job.output))" -ForegroundColor Yellow
}

function ConvertTo-JobView($Job) {
  $until = if ($Job.finished) { $Job.finished } else { Get-Date }
  @{
    id      = $Job.id
    label   = $Job.label
    output  = [IO.Path]::GetFileName($Job.output)
    status  = $Job.status
    percent = [Math]::Round($Job.percent, 1)
    error   = $Job.error
    seconds = [Math]::Round(($until - $Job.started).TotalSeconds)
  }
}

function Get-JobViews {
  foreach ($job in $App.Jobs.Values) { Update-Job $job }
  $views = @($App.Jobs.Values | ForEach-Object { ConvertTo-JobView $_ })
  [array]::Reverse($views)
  , $views
}

# ---------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------

function Send-Bytes($Response, [byte[]]$Bytes, [string]$ContentType, [int]$Status) {
  $Response.StatusCode = $Status
  $Response.ContentType = $ContentType
  $Response.AddHeader('Cache-Control', 'no-store')
  $Response.ContentLength64 = $Bytes.Length
  $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Send-Text($Response, [string]$Text, [string]$ContentType, [int]$Status = 200) {
  Send-Bytes $Response ([Text.Encoding]::UTF8.GetBytes($Text)) $ContentType $Status
}

function Send-Json($Response, $Object, [int]$Status = 200) {
  $json = ConvertTo-Json -InputObject $Object -Depth 6 -Compress
  Send-Text $Response $json 'application/json; charset=utf-8' $Status
}

function Send-Error($Response, [string]$Message, [int]$Status) {
  try {
    Send-Json $Response @{ error = $Message } $Status
  } catch {
    # The response may already be partly sent or the browser has gone; nothing more to do.
  }
}

function Read-JsonBody($Request) {
  if ($Request.ContentLength64 -gt $MaxBodyBytes) { throw (New-BadRequest 'Request too large.') }
  $reader = New-Object IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
  try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
  if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
  $text | ConvertFrom-Json
}

# Serve a video with HTTP range support so the player can seek. Range responses are capped
# at $ChunkBytes (the player just asks for the next range) and written asynchronously, so a
# browser that pauses reading cannot block the server. Complete-PendingWrites finishes them.
function Send-Video($Context, [string]$Path) {
  $request = $Context.Request
  $response = $Context.Response
  $types = @{ '.mp4' = 'video/mp4'; '.m4v' = 'video/mp4'; '.mov' = 'video/quicktime'; '.mkv' = 'video/x-matroska'; '.avi' = 'video/x-msvideo' }
  $response.AddHeader('Accept-Ranges', 'bytes')
  $response.ContentType = $types[[IO.Path]::GetExtension($Path).ToLowerInvariant()]
  # Share delete too, so the clip being watched can still be deleted or moved in Explorer.
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try {
    $total = $stream.Length
    $range = $request.Headers['Range']

    if ($range -notmatch '^bytes=(\d*)-(\d*)$') {
      # Whole file without a range (not what video players do): stream it synchronously.
      $response.ContentLength64 = $total
      try { $stream.CopyTo($response.OutputStream, 65536) } catch { }  # browser went away
      return
    }

    $first = [int64]0
    $last = $total - 1
    if ($Matches[1] -eq '') {
      $first = [Math]::Max([int64]0, $total - [int64]$Matches[2])
    } else {
      $first = [int64]$Matches[1]
      if ($Matches[2] -ne '') { $last = [Math]::Min([int64]$Matches[2], $total - 1) }
    }
    if ($first -ge $total) {
      $response.AddHeader('Content-Range', "bytes */$total")
      Send-Text $response '' 'text/plain' 416
      return
    }
    $last = [Math]::Min($last, $first + $ChunkBytes - 1)
    $length = [int]($last - $first + 1)
    $buffer = New-Object byte[] $length
    $stream.Position = $first
    $read = 0
    while ($read -lt $length) {
      $n = $stream.Read($buffer, $read, $length - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    $response.StatusCode = 206
    $response.AddHeader('Content-Range', "bytes $first-$($first + $read - 1)/$total")
    $response.ContentLength64 = $read
    $task = $response.OutputStream.WriteAsync($buffer, 0, $read)
    [void]$App.PendingWrites.Add(@{ Task = $task; Response = $response; Started = Get-Date })
  } finally {
    $stream.Dispose()
  }
}

# Close video responses whose async write has finished; abort ones the browser stopped reading.
function Complete-PendingWrites {
  for ($i = $App.PendingWrites.Count - 1; $i -ge 0; $i--) {
    $pending = $App.PendingWrites[$i]
    $stuck = ((Get-Date) - $pending.Started).TotalSeconds -gt $StuckWriteSeconds
    if (-not $pending.Task.IsCompleted -and -not $stuck) { continue }
    try {
      if ($pending.Task.Status -eq 'RanToCompletion') { $pending.Response.Close() } else { $pending.Response.Abort() }
    } catch {
      # The connection is already gone.
    }
    $App.PendingWrites.RemoveAt($i)
  }
}

function Get-AppState {
  # Take the stamp before listing: a change in between then causes one extra reload
  # instead of being missed.
  $stamp = Get-Stamp
  $media = New-Object IO.DirectoryInfo $App.MediaDir
  @{
    ffmpeg        = [bool]$App.Ffmpeg
    ffmpegVersion = $App.FfmpegVersion
    gpuEncoder    = $App.GpuEncoder
    gpuLabel      = if ($App.GpuEncoder) { $GpuLabels[$App.GpuEncoder] } else { $null }
    mediaDir      = $App.MediaDir
    mediaOk       = $media.Exists
    parent        = if ($media.Parent) { $media.Parent.FullName } else { $null }
    subfolders    = @(Get-Subfolders $App.MediaDir)
    recent        = @($App.Recent)
    cards         = @(Get-CameraFolders)
    outputDir     = $App.OutputDir
    files         = @(Get-ClipList)
    stamp         = $stamp
  }
}

function Invoke-Route($Context) {
  $request = $Context.Request
  $response = $Context.Response
  $path = $request.Url.AbsolutePath
  $method = $request.HttpMethod

  if ($method -eq 'GET' -and $path -eq '/') {
    if ($request.QueryString['t'] -cne $App.Token) {
      Send-Text $response 'Forbidden. Start the app with "Start Dashcam Editor.bat".' 'text/plain; charset=utf-8' 403
      return
    }
    $html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'index.html'))
    Send-Text $response $html 'text/html; charset=utf-8'
    return
  }

  $token = $request.Headers['X-Token']
  if (-not $token) { $token = $request.QueryString['t'] }
  if ($token -cne $App.Token) {
    Send-Error $response 'Forbidden' 403
    return
  }
  $App.LastSeen = Get-Date

  if ($method -eq 'GET' -and $path.StartsWith('/video/')) {
    $parts = $path.Substring(7).Split([char[]]@('/'), 2)
    if ($parts.Count -ne 2) { throw (New-BadRequest 'Bad video path.') }
    $file = Resolve-MediaPath ([Uri]::UnescapeDataString($parts[0])) ([Uri]::UnescapeDataString($parts[1]))
    Send-Video $Context $file
    return
  }

  switch ("$method $path") {
    'GET /api/state' {
      Send-Json $response (Get-AppState)
    }
    'GET /api/info' {
      $file = Resolve-MediaPath $request.QueryString['folder'] $request.QueryString['name']
      Send-Json $response (Get-MediaInfo $file)
    }
    'POST /api/plan' {
      Send-Json $response (ConvertTo-PlanView (New-Plan (Read-JsonBody $request)))
    }
    'POST /api/run' {
      $job = Start-FfmpegJob (New-Plan (Read-JsonBody $request))
      Send-Json $response (ConvertTo-JobView $job)
    }
    'GET /api/jobs' {
      Send-Json $response @{ jobs = (Get-JobViews); stamp = (Get-Stamp); browsing = [bool]$App.Browse }
    }
    'POST /api/folder' {
      Set-MediaFolder ([string](Get-Opt (Read-JsonBody $request) 'path' ''))
      Send-Json $response (Get-AppState)
    }
    'POST /api/browse' {
      Start-FolderBrowse
      Send-Json $response @{ ok = $true }
    }
    'POST /api/open-output' {
      Start-Process explorer.exe -ArgumentList "`"$($App.OutputDir)`""
      Send-Json $response @{ ok = $true }
    }
    'POST /api/cancel' {
      $id = [string](Get-Opt (Read-JsonBody $request) 'id' '')
      if (-not $App.Jobs.Contains($id)) { throw (New-Object IO.FileNotFoundException 'No such job.') }
      Stop-FfmpegJob $App.Jobs[$id]
      Send-Json $response (ConvertTo-JobView $App.Jobs[$id])
    }
    'POST /api/reveal' {
      $body = Read-JsonBody $request
      $file = Resolve-MediaPath (Get-Opt $body 'folder' '') (Get-Opt $body 'name' '')
      Start-Process explorer.exe -ArgumentList "/select,`"$file`""
      Send-Json $response @{ ok = $true }
    }
    'POST /api/quit' {
      $App.QuitRequested = $true
      Send-Json $response @{ ok = $true }
    }
    default {
      Send-Error $response 'Not found' 404
    }
  }
}

function Invoke-Request($Context) {
  $response = $Context.Response
  try {
    Invoke-Route $Context
  } catch [ArgumentException] {
    Send-Error $response $_.Exception.Message 400
  } catch [IO.FileNotFoundException] {
    Send-Error $response $_.Exception.Message 404
  } catch {
    Write-Host ('Error on {0}: {1}' -f $Context.Request.Url.AbsolutePath, $_) -ForegroundColor Red
    Send-Error $response 'Internal error, see the server console.' 500
  } finally {
    $isPending = @($App.PendingWrites | Where-Object { $_.Response -eq $response }).Count -gt 0
    if (-not $isPending) {
      try { $response.Close() } catch { }
    }
  }
}

function Start-Listener([int]$PreferredPort) {
  for ($candidate = $PreferredPort; $candidate -lt $PreferredPort + 20; $candidate++) {
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$candidate/")
    try {
      $listener.Start()
      return @{ Listener = $listener; Port = $candidate }
    } catch {
      $listener.Close()
    }
  }
  throw "No free port between $PreferredPort and $($PreferredPort + 19)."
}

function Find-Program([string]$RelativePath) {
  $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }
  $roots | ForEach-Object { Join-Path $_ $RelativePath } | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Open-AppWindow([string]$Url, [string]$Which) {
  if ($Which -eq 'Edge') {
    $edge = Find-Program 'Microsoft\Edge\Application\msedge.exe'
    if ($edge) {
      Start-Process $edge -ArgumentList "--app=$Url", '--window-size=1500,950'
      return
    }
  }
  if ($Which -eq 'Firefox') {
    $firefox = Find-Program 'Mozilla Firefox\firefox.exe'
    if ($firefox) {
      Start-Process $firefox -ArgumentList '-new-window', $Url
      return
    }
  }
  if ($Which -ne 'Default') { Write-Host "  $Which not found, using the default browser." -ForegroundColor Yellow }
  Start-Process $Url
}

function Test-ShouldStop {
  if ($App.QuitRequested) { return $true }
  foreach ($job in $App.Jobs.Values) { Update-Job $job }
  $busy = @($App.Jobs.Values | Where-Object { $_.status -eq 'running' }).Count -gt 0 -or $App.Browse
  $idle = $App.LastSeen -and ((Get-Date) - $App.LastSeen).TotalMinutes -ge $IdleMinutes
  $idle -and -not $busy
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

$App = @{
  MediaDir      = ''
  OutputDir     = ''
  Recent        = @(Read-RecentFolders)
  Copying       = @()     # files that were still being copied at the last listing
  Browse        = $null   # folder picker task while the dialog is open
  Ffmpeg        = $null
  Ffprobe       = $null
  FfmpegVersion = ''
  GpuEncoder    = $null
  Token         = New-Token
  Jobs          = [ordered]@{}
  PendingWrites = New-Object Collections.ArrayList
  ProbeCache    = @{}
  LastSeen      = $null
  QuitRequested = $false
}

# Start in -MediaDir, else the folder used last time, else the script's folder.
if ($MediaDir) {
  $App.MediaDir = Get-CleanDir (Resolve-Path -LiteralPath $MediaDir).Path
  Add-RecentFolder $App.MediaDir
} elseif ($App.Recent.Count -gt 0 -and [IO.Directory]::Exists($App.Recent[0])) {
  $App.MediaDir = $App.Recent[0]
} else {
  $App.MediaDir = Get-CleanDir $PSScriptRoot
}

if (-not $OutputDir) {
  $videos = [Environment]::GetFolderPath('MyVideos')
  $OutputDir = if ($videos) { Join-Path $videos 'Dashcam Editor' } else { Join-Path $PSScriptRoot 'output' }
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$App.OutputDir = Get-CleanDir (Resolve-Path -LiteralPath $OutputDir).Path

$Host.UI.RawUI.WindowTitle = 'Dashcam Editor (server)'
Write-Host 'Dashcam Editor' -ForegroundColor Cyan

$ffDir = Find-FfmpegDir $FfmpegDir
if ($ffDir) {
  $App.Ffmpeg = Join-Path $ffDir 'ffmpeg.exe'
  $App.Ffprobe = Join-Path $ffDir 'ffprobe.exe'
  $App.FfmpegVersion = ((Invoke-Native $App.Ffmpeg @('-hide_banner', '-version')).Output -split "`n")[0] -replace '^ffmpeg version (\S+).*', '$1'
  Write-Host '  Checking for GPU encoders...'
  $App.GpuEncoder = Find-GpuEncoder
} else {
  Write-Host '  ffmpeg not found. Previewing works, but exporting needs ffmpeg.' -ForegroundColor Yellow
}

$started = Start-Listener $Port
$listener = $started.Listener
$url = "http://localhost:$($started.Port)/?t=$($App.Token)"
$gpuText = if ($App.GpuEncoder) { $GpuLabels[$App.GpuEncoder] } else { 'none (CPU only)' }

Write-Host "  Clips:   $($App.MediaDir)"
Write-Host "  Output:  $($App.OutputDir)"
Write-Host "  ffmpeg:  $(if ($ffDir) { "$ffDir ($($App.FfmpegVersion))" } else { 'not found' })"
Write-Host "  GPU:     $gpuText"
Write-Host "  App:     $url"
Write-Host "Close the app window (the server stops after $IdleMinutes idle minutes) or press Ctrl+C." -ForegroundColor DarkGray

try {
  if (-not $NoBrowser) { Open-AppWindow $url $Browser }
  $lastCheck = Get-Date
  :serve while (-not $App.QuitRequested) {
    $pending = $listener.GetContextAsync()
    while (-not $pending.Wait(50)) {
      Complete-PendingWrites
      Complete-FolderBrowse
      if (((Get-Date) - $lastCheck).TotalMilliseconds -ge 500) {
        $lastCheck = Get-Date
        if (Test-ShouldStop) { break serve }
      }
    }
    Invoke-Request $pending.Result
    Complete-PendingWrites
    Complete-FolderBrowse
  }
} finally {
  foreach ($job in @($App.Jobs.Values)) { Stop-FfmpegJob $job }
  foreach ($write in @($App.PendingWrites)) { try { $write.Response.Abort() } catch { } }
  $listener.Close()
  Write-Host 'Server stopped.'
}
