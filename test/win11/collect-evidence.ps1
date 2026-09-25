<#
    SharpEnviro on Windows 11 - evidence collector.

    Run inside the VM, elevated:
        powershell -ExecutionPolicy Bypass -File .\collect-evidence.ps1 -Tag baseline

    Writes evidence-<host>-<tag>-<timestamp>.txt next to this script (so run it
    from the shared folder to get the file out of the VM directly.)
#>
[CmdletBinding()]
param(
    [string]$Tag = 'run',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'
if (-not $OutDir) {
    $OutDir = $PSScriptRoot
    if (-not $OutDir) { $OutDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $OutDir) { $OutDir = (Get-Location).Path }
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$out = Join-Path $OutDir ("evidence-{0}-{1}-{2}.txt" -f $env:COMPUTERNAME, $Tag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$lines = New-Object System.Collections.Generic.List[string]

function AddLine([string]$s) { $lines.Add($s) | Out-Null }
function AddHead([string]$s) { AddLine ''; AddLine ('=' * 78); AddLine $s; AddLine ('=' * 78) }
function AddKV([string]$k, [string]$v) { AddLine ("{0,-46} {1}" -f $k, $v) }

Add-Type -Namespace Win32 -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);
public delegate bool EnumProc(IntPtr h, IntPtr l);
'@

function Get-Class([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][Win32.Api]::GetClassNameW($h, $sb, $sb.Capacity)
    $sb.ToString()
}
function Get-Title([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][Win32.Api]::GetWindowTextW($h, $sb, $sb.Capacity)
    $sb.ToString()
}

# ---------------------------------------------------------------- os / build
AddHead 'OPERATING SYSTEM'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
AddKV 'ProductName'        $cv.ProductName
AddKV 'DisplayVersion'     $cv.DisplayVersion
AddKV 'CurrentBuildNumber' $cv.CurrentBuildNumber
AddKV 'UBR (revision)'     $cv.UBR
AddKV 'EditionID'          $cv.EditionID
AddKV 'OSArchitecture'     ([Environment]::Is64BitOperatingSystem)
AddKV 'ProcessIs64Bit'     ([Environment]::Is64BitProcess)
$dpi = Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
AddKV 'Desktop LogPixels'  $dpi.LogPixels
AddKV 'Win32_ComputerSystem Model' ((Get-CimInstance Win32_ComputerSystem).Model)
AddKV 'VM detection'       ((Get-CimInstance Win32_ComputerSystem).Manufacturer)
try { AddKV 'SecureBoot' ((Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop).SecurityServicesConfigured -join ',') } catch { AddKV 'SecureBoot' 'n/a' }

# ---------------------------------------------------------------- shell state
AddHead 'SHELL REGISTRATION (what will start after next logon)'
function RegVal([string]$path, [string]$name) {
    try { (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { '<not set>' }
}
AddKV 'HKCU ...\Winlogon\Shell'                     (RegVal 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Shell')
AddKV 'HKLM ...\Winlogon\Shell'                     (RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Shell')
AddKV 'HKLM ...\Winlogon\Userinit'                  (RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Userinit')
AddKV 'HKLM IniFileMapping system.ini\boot\Shell'   (RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\IniFileMapping\system.ini\boot' 'Shell')
AddKV 'HKCU ...\Explorer\DesktopProcess'            (RegVal 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'DesktopProcess')
AddKV 'HKLM SharpEnviro\Path'                       (RegVal 'HKLM:\SOFTWARE\Wow6432Node\SharpEnviro' 'Path')

AddHead 'SHELL WINDOW (GetShellWindow)'
$sh = [Win32.Api]::GetShellWindow()
if ($sh -eq [IntPtr]::Zero) {
    AddLine 'GetShellWindow() = NULL   (no process claimed the shell window: no Explorer desktop, and SharpE never calls SetShellWindow)'
} else {
    $pid0 = 0
    [void][Win32.Api]::GetWindowThreadProcessId($sh, [ref]$pid0)
    $pname = try { (Get-Process -Id $pid0 -ErrorAction Stop).ProcessName } catch { '?' }
    AddKV 'handle' $sh
    AddKV 'class'  (Get-Class $sh)
    AddKV 'pid'    "$pid0 ($pname)"
}

# ---------------------------------------------------------------- .NET state
AddHead '.NET FRAMEWORK STATE (the Delphi gate reads NDP\v3.5; the managed binaries need 4.8)'
foreach ($view in @('', 'WOW6432Node\')) {
    $base = "HKLM:\SOFTWARE\${view}Microsoft\NET Framework Setup\NDP"
    $v35 = try { (Get-ItemProperty "$base\v3.5" -ErrorAction Stop).Install } catch { '<absent>' }
    $v4  = try { (Get-ItemProperty "$base\v4\Full" -ErrorAction Stop).Release } catch { '<absent>' }
    $label = if ($view) { '32-bit view' } else { '64-bit view' }
    $v4text = $v4
    if ($v4 -ne '<absent>' -and $v4 -ge 528040) { $v4text = "$v4  (>= 4.8)" }
    AddKV "$label  v3.5\Install"    $v35
    AddKV "$label  v4\Full\Release" $v4text
}

# ---------------------------------------------------------------- processes
AddHead 'PROCESSES OF INTEREST'
$names = 'explorer', 'SharpCore', 'SharpBar', 'SharpDesk', 'SharpMenu', 'SharpCenter', 'SharpConsole',
         'Explorer', 'SharpShellServicesNET', 'SharpShellServices', 'SharpSearchNET', 'SharpLinkLauncherNET',
         'TaskSwitch', 'VWM', 'Shell', 'SystemTray', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost'
foreach ($n in $names) {
    $ps = Get-Process -Name $n -ErrorAction SilentlyContinue
    if (-not $ps) { AddKV $n '<not running>'; continue }
    foreach ($p in $ps) {
        $path = try { $p.Path } catch { '' }
        AddKV $n ("pid={0} started={1} ws={2:N0}KB {3}" -f $p.Id, $p.StartTime.ToString('HH:mm:ss'), ($p.WorkingSet64 / 1KB), $path)
    }
}

# ---------------------------------------------------------------- windows
AddHead 'TOP-LEVEL WINDOWS (class competition evidence for Shell_TrayWnd et al.)'
$rows = New-Object System.Collections.Generic.List[string]
$cb = [Win32.Api+EnumProc]{
    param($h, $l)
    $pid0 = 0
    [void][Win32.Api]::GetWindowThreadProcessId($h, [ref]$pid0)
    $pname = try { (Get-Process -Id $pid0 -ErrorAction Stop).ProcessName } catch { '?' }
    $cloaked = 0
    [void][Win32.Api]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4)
    $vis = [Win32.Api]::IsWindowVisible($h)
    if ($vis -or $cloaked -ne 0) {
        $rows.Add(("{0,-26} pid={1,-6} {2,-22} visible={3,-6} cloaked={4} title={5}" -f `
            (Get-Class $h), $pid0, $pname, $vis, $cloaked, (Get-Title $h)))
    }
    return $true
}
[void][Win32.Api]::EnumWindows($cb, [IntPtr]::Zero)
AddLine ("visible top-level windows: {0}" -f $rows.Count)
AddLine ''
AddLine '--- tray / taskbar / desktop related ---'
foreach ($r in ($rows | Sort-Object)) {
    if ($r -match 'Shell_TrayWnd|TrayNotifyWnd|ReBarWindow32|MSTaskSwWClass|Progman|WorkerW|SHELLDLL_DefView|TSharp|AltTab|Taskband|Shell_SecondaryTrayWnd') { AddLine $r }
}
AddLine ''
AddLine '--- cloaked windows (must never become task buttons) ---'
foreach ($r in ($rows | Sort-Object)) { if ($r -match 'cloaked=(?!0)') { AddLine $r } }
AddLine ''
AddLine '--- all ---'
$rows | Sort-Object | ForEach-Object { AddLine $_ }

# ---------------------------------------------------------------- manifests in binaries
AddHead 'EMBEDDED MANIFEST CHECK (supportedOS present?)'
$dirs = @("${env:ProgramFiles(x86)}\SharpEnviro", "${env:ProgramFiles(x86)}\SharpEnviro\Addons\x64",
          "${env:ProgramFiles(x86)}\SharpEnviro\Addons\x86", 'C:\SharpEnviro')
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { continue }
    AddLine ''; AddLine "--- $d"
    foreach ($f in (Get-ChildItem $d -Filter *.exe -File -ErrorAction SilentlyContinue)) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $txt = [Text.Encoding]::ASCII.GetString($bytes)
        $sup = $txt.Contains('8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a')
        $dpi = if ($txt -match 'dpiAware') { 'dpiAware present' } else { 'dpiAware absent' }
        AddKV $f.Name ("supportedOS={0}  {1}  {2:N0} bytes" -f $sup, $dpi, $f.Length)
    }
}

# ---------------------------------------------------------------- event log
AddHead 'EVENT LOG (last 45 minutes, errors/critical + WER for SharpE)'
$since = (Get-Date).AddMinutes(-45)
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since; Level = 1, 2 } -ErrorAction Stop |
        Select-Object -First 40 | ForEach-Object { AddLine ("{0:HH:mm:ss} [{1}] {2} :: {3}" -f $_.TimeCreated, $_.LevelDisplayName, $_.ProviderName, ($_.Message -split "`n")[0]) }
} catch { AddLine "Application log: $($_.Exception.Message)" }
try {
    Get-WinEvent -LogName 'Application' -MaxEvents 400 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match 'Windows Error Reporting|Application Error' -and $_.TimeCreated -gt $since } |
        Select-Object -First 25 | ForEach-Object { AddLine ("{0:HH:mm:ss} {1} :: {2}" -f $_.TimeCreated, $_.ProviderName, (($_.Message -split "`n")[0..2] -join ' | ')) }
} catch { AddLine "WER scan: $($_.Exception.Message)" }

AddHead 'END'

$lines | Set-Content -Path $out -Encoding UTF8
Write-Host "evidence written: $out"
