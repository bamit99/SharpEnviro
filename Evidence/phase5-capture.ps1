# Phase 5 measurements. MUST run in the interactive session: GetShellWindow,
# work area and window enumeration are per-session. Driven over WinRM they return
# answers for session 0 (no desktop), which is meaningless.
$ErrorActionPreference = 'Continue'
# Output is named from the detected shell, so a run is self-identifying and no
# argument passing (which is fragile through the scheduled-task command line) is needed.
$script:tag = 'unknown'
$out = ''
$share = '\\vmware-host\Shared Folders\Evidence'

Add-Type -Namespace P5b -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint f);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern IntPtr FindWindowW(string c, string n);
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern IntPtr FindWindowExW(IntPtr p, IntPtr c, string cls, string n);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
[DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr r, MonProc cb, IntPtr l);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
public delegate bool EnumProc(IntPtr h, IntPtr l);
public delegate bool MonProc(IntPtr h, IntPtr dc, ref RECT r, IntPtr l);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }
function Save {
    $script:out = Join-Path $share ("phase5-{0}.txt" -f $script:tag)
    $L | Out-File $script:out -Encoding utf8
    Write-Host "written: $script:out"
}

function WinClass($h) { $sb = New-Object System.Text.StringBuilder 256; [void][P5b.Api]::GetClassNameW($h, $sb, $sb.Capacity); $sb.ToString() }
function WinTitle($h) { $sb = New-Object System.Text.StringBuilder 256; [void][P5b.Api]::GetWindowTextW($h, $sb, $sb.Capacity); $sb.ToString() }
function ProcOf($h) { [uint32]$p = 0; [void][P5b.Api]::GetWindowThreadProcessId($h, [ref]$p); $pr = Get-Process -Id $p -EA SilentlyContinue; "$($pr.ProcessName)($p)" }

A "=== phase 5 @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
A "user=$(whoami)  session=$((Get-Process -Id $PID).SessionId)  interactive=$([Environment]::UserInteractive)"
A ""

# ---- the shell window ----
A '--- shell window ---'
$sh = [P5b.Api]::GetShellWindow()
if ($sh -eq [IntPtr]::Zero) {
    A '  GetShellWindow() = NULL'
    $script:tag = 'no-shell'
} else {
    $shellCls = WinClass $sh
    A "  GetShellWindow() = 0x$($sh.ToString('X'))  class=$shellCls  title='$(WinTitle $sh)'  owner=$(ProcOf $sh)"
    $script:tag = if ($shellCls -eq 'Progman') { 'explorer-shell' }
                  elseif ($shellCls -match 'Sharp') { 'sharpe-shell' }
                  else { "shell-$shellCls" }
}
A "  => writes phase5-$($script:tag).txt"

# ---- tray / taskbar windows: who owns the tray ----
A ''
A '--- Shell_TrayWnd family (tray ownership) ---'
foreach ($cn in 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'NotifyIconOverflowWindow', 'TrayNotifyWnd', 'Progman', 'WorkerW') {
    $h = [P5b.Api]::FindWindowW($cn, $null)
    if ($h -ne [IntPtr]::Zero) { A ("  {0,-26} present  0x{1}  owner={2}" -f $cn, $h.ToString('X'), (ProcOf $h)) }
    else { A ("  {0,-26} absent" -f $cn) }
}

# ---- every visible top-level window, with class + owner + cloaked ----
A ''
A '--- all visible top-level windows ---'
$script:rows = New-Object System.Collections.Generic.List[string]
$cb = [P5b.Api+EnumProc] {
    param($hw, $l)
    if ([P5b.Api]::IsWindowVisible($hw)) {
        $cl = WinClass $hw
        $cl_v = 0
        [void][P5b.Api]::DwmGetWindowAttribute($hw, 14, [ref]$cl_v, 4)   # DWMWA_CLOAKED
        $script:rows.Add(("  {0,-30} {1,-16} cloaked={2} '{3}'" -f $cl, (ProcOf $hw), $cl_v, (WinTitle $hw)))
    }
    return $true
}
[void][P5b.Api]::EnumWindows($cb, [IntPtr]::Zero)
$script:rows | Sort-Object -Unique | ForEach-Object { A $_ }

# ---- work area vs screen: does the bar reserve space? ----
A ''
A '--- work area (bar space reservation) ---'
$r = New-Object P5b.Api+RECT
if ([P5b.Api]::SystemParametersInfo(0x0030, 0, [ref]$r, 0)) {   # SPI_GETWORKAREA
    A ("  SPI_GETWORKAREA  = L{0} T{1} R{2} B{3}  ({4}x{5})" -f $r.Left, $r.Top, $r.Right, $r.Bottom, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
}
A ("  SM_CXSCREEN      = {0}" -f [P5b.Api]::GetSystemMetrics(0))
A ("  SM_CYSCREEN      = {0}" -f [P5b.Api]::GetSystemMetrics(1))
A "  (work area < screen => something reserved edge space for a bar)"

# ---- DPI ----
A ''
A '--- DPI ---'
$logpix = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name LogPixels -EA SilentlyContinue).LogPixels
A ("  HKCU LogPixels   = {0}  (96 = 100%)" -f $(if ($logpix) { $logpix } else { '<not set>' }))
if ($sh -ne [IntPtr]::Zero) {
    $mon = [P5b.Api]::MonitorFromWindow($sh, 2)
    $dx = 0; $dy = 0
    if ([P5b.Api]::GetDpiForMonitor($mon, 0, [ref]$dx, [ref]$dy) -eq 0) {
        A ("  monitor DPI      = {0} ({1}%)" -f $dx, [int]($dx * 100 / 96))
    }
}

# ---- monitors ----
A ''
A '--- monitors ---'
$script:m = New-Object System.Collections.Generic.List[string]
$mcb = [P5b.Api+MonProc] {
    param($h, $dc, [ref]$r, $l)
    $script:m.Add(("  monitor 0x{0}  L{1} T{2} R{3} B{4}  ({5}x{6})" -f $h.ToString('X'), $r.Left, $r.Top, $r.Right, $r.Bottom, ($r.Right - $r.Left), ($r.Bottom - $r.Top)))
    return $true
}
[void][P5b.Api]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $mcb, [IntPtr]::Zero)
A ("  monitor count = {0}" -f $script:m.Count)
$script:m | ForEach-Object { A $_ }

Save
