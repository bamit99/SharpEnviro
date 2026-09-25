# Runs INSIDE the interactive session (as amitb). GetShellWindow() is per-session,
# so this cannot be done from WinRM - session 0 always reports NULL.
$ErrorActionPreference = 'SilentlyContinue'
$out = '\\vmware-host\Shared Folders\Evidence\session1-shell.txt'

Add-Type -Namespace W1 -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
public delegate bool EnumProc(IntPtr h, IntPtr l);
'@
Add-Type -Namespace W1 -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add($s) }

A "session1 shell check @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
A "user            = $(whoami)"
A "sessionId       = $((Get-Process -Id $PID).SessionId)"
A "interactive     = $([Environment]::UserInteractive)"
A "COMPUTERNAME    = $env:COMPUTERNAME"
A ''

# ---- the shell window, asked from the session that owns it ----
$h = [W1.Api]::GetShellWindow()
A "GetShellWindow() = $(if ($h -eq [IntPtr]::Zero) { 'NULL' } else { "0x$($h.ToString('X'))" })"
if ($h -ne [IntPtr]::Zero) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][W1.Api]::GetClassNameW($h, $sb, $sb.Capacity)
    $t = New-Object System.Text.StringBuilder 256
    [void][W1.Api]::GetWindowTextW($h, $t, $t.Capacity)
    [uint32]$pid = 0
    [void][W1.Api]::GetWindowThreadProcessId($h, [ref]$pid)
    $pn = (Get-Process -Id $pid -ErrorAction SilentlyContinue).ProcessName
    A "  class = $($sb.ToString())"
    A "  title = $($t.ToString())"
    A "  pid   = $pid ($pn)"
}
A ''

# ---- enumerate the classes that matter, in THIS session ----
A 'top-level windows of interest (this session):'
$interesting = 'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'TSharpBarMainForm',
               'TSharpDeskMainForm', 'SharpEBarBackGround', 'TBarHideForm'
$script:hits = New-Object System.Collections.Generic.List[string]
$cb = [W1.Api+EnumProc] {
    param($hw, $l)
    $sb = New-Object System.Text.StringBuilder 256
    [void][W1.Api]::GetClassNameW($hw, $sb, $sb.Capacity)
    $cls = $sb.ToString()
    if ($interesting -contains $cls) {
        [uint32]$pid = 0
        [void][W1.Api]::GetWindowThreadProcessId($hw, [ref]$pid)
        $pn = (Get-Process -Id $pid -ErrorAction SilentlyContinue).ProcessName
        $vis = [W1.Api]::IsWindowVisible($hw)
        $cl = 0
        [void][W1.Dwm]::DwmGetWindowAttribute($hw, 14, [ref]$cl, 4)   # DWMWA_CLOAKED
        $script:hits.Add(("  {0,-24} pid={1,-6} {2,-14} visible={3,-6} cloaked={4}" -f $cls, $pid, $pn, $vis, $cl))
    }
    return $true
}
[void][W1.Api]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:hits.Count) { $script:hits | Sort-Object -Unique | ForEach-Object { A $_ } }
else { A '  (none of the expected shell classes present)' }

A ''
A 'verdict:'
$hasProgman = ($script:hits | Where-Object { $_ -match 'Progman' }).Count -gt 0
$hasSharp   = ($script:hits | Where-Object { $_ -match 'Sharp' }).Count -gt 0
if ($hasProgman -and -not $hasSharp) { A '  EXPLORER is the shell - clean Windows 11 desktop (phase 0 baseline)' }
elseif ($hasSharp -and -not $hasProgman) { A '  SharpE is the shell - Windows desktop is replaced' }
elseif ($hasProgman -and $hasSharp) { A '  BOTH present - two shells competing' }
else { A '  neither - investigate' }

$L | Out-File $out -Encoding utf8
