# Desktop real-run self-test: launch EXE -> screenshot -> simulate clicks -> close -> verify exit & restart
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI
#       (no BOM), so non-ASCII literals corrupt the script.
param(
    [string]$Exe = "C:\Users\ghy\WorkBuddy\2026-10-24-21-50-36\darkcard\build\DarkCardDuel.exe",
    [string]$OutDir = "C:\Users\ghy\WorkBuddy\2026-10-25-10-37-36\shots"
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public const uint PW_RENDERFULLCONTENT = 2;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x02, MOUSEEVENTF_LEFTUP = 0x04;
}
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Get-AppWindow([System.Diagnostics.Process]$p) {
    for ($i = 0; $i -lt 60; $i++) {
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Save-Shot([IntPtr]$h, [string]$name) {
    $r = New-Object Win+RECT
    [void][Win]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
    if ($w -le 0 -or $ht -le 0) { Write-Host "  bad window rect"; return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][Win]::PrintWindow($h, $hdc, [Win]::PW_RENDERFULLCONTENT)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $path = Join-Path $OutDir "$name.png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "  shot -> $path  (${w}x${ht})"
    return $path
}

function Get-Rect([IntPtr]$h) {
    $r = New-Object Win+RECT
    [void][Win]::GetWindowRect($h, [ref]$r)
    return $r
}

# Force the window to the design resolution (540x960); on small/virtual
# displays the OS shrinks it and the UI gets cropped.
function Force-Size([IntPtr]$h) {
    [void][Win]::MoveWindow($h, 0, 0, 540, 960, $true)
    Start-Sleep -Milliseconds 700
    $r = Get-Rect $h
    Write-Host "  window rect = $($r.Right - $r.Left)x$($r.Bottom - $r.Top) @ $($r.Left),$($r.Top)"
}

function Click-At([IntPtr]$h, [int]$dx, [int]$dy) {
    $r = New-Object Win+RECT
    [void][Win]::GetWindowRect($h, [ref]$r)
    $x = $r.Left + $dx; $y = $r.Top + $dy
    [void][Win]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 300
    [void][Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [Win]::mouse_event([Win]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Win]::mouse_event([Win]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    Write-Host "  click at window coords ($dx,$dy)"
    Start-Sleep -Milliseconds 1000
}

function Get-ColorCount([string]$path) {
    if (-not $path) { return -1 }
    $bmp = [System.Drawing.Bitmap]::FromFile($path)
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($y = 0; $y -lt $bmp.Height; $y += 3) {
        for ($x = 0; $x -lt $bmp.Width; $x += 3) {
            $c = $bmp.GetPixel($x, $y)
            [void]$set.Add(($c.R -shl 16) -bor ($c.G -shl 8) -bor $c.B)
        }
    }
    $n = $set.Count; $bmp.Dispose(); return $n
}

Write-Host "launch: $Exe"
$proc = Start-Process -FilePath $Exe -PassThru
$h = Get-AppWindow $proc
if ($h -eq [IntPtr]::Zero) { Write-Host "FAIL: no window"; Stop-Process -Id $proc.Id -Force; exit 1 }

Start-Sleep -Milliseconds 1500
Force-Size $h
$shot1 = Save-Shot $h "desktop_main"
Write-Host "  colors = $(Get-ColorCount $shot1)"

# main menu "single player" button (centered vertically)
Click-At $h 270 520
$shot2 = Save-Shot $h "desktop_battle"
Write-Host "  colors = $(Get-ColorCount $shot2)"

# top bar "menu" pill (far right, logical x 474..526, y 13..41)
Click-At $h 500 27
$shot3 = Save-Shot $h "desktop_menu"
Write-Host "  colors = $(Get-ColorCount $shot3)"

# close window = WM_CLOSE (same as clicking X)
Write-Host "sending close request (same as clicking X)"
$closed = $proc.CloseMainWindow()
Write-Host "  CloseMainWindow returned $closed"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $proc.HasExited -and $sw.ElapsedMilliseconds -lt 8000) {
    Start-Sleep -Milliseconds 100
}
if ($proc.HasExited) {
    Write-Host "OK: process exited after $($sw.ElapsedMilliseconds) ms"
} else {
    Write-Host "FAIL: still alive after 8s (PID $($proc.Id)) - window closed but process lingers"
    Stop-Process -Id $proc.Id -Force
}

Write-Host "restart check"
$proc2 = Start-Process -FilePath $Exe -PassThru
$h2 = Get-AppWindow $proc2
Start-Sleep -Milliseconds 1800
Force-Size $h2
$shot4 = Save-Shot $h2 "desktop_restart"
Write-Host "  colors = $(Get-ColorCount $shot4)"
[void]$proc2.CloseMainWindow()
Start-Sleep -Milliseconds 2000
if (-not $proc2.HasExited) { Stop-Process -Id $proc2.Id -Force }
Write-Host "DONE"
