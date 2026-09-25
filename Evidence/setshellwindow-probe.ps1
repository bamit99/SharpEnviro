# Verify the premise of the SetShellWindow fix: does user32 export it on Windows 11,
# and does a no-op call succeed? (Read-only-ish: passes the CURRENT shell window back,
# so it cannot change the shell; then we re-read it.)
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'
$out = Join-Path $share 'setshellwindow-probe.txt'

Add-Type -Namespace SW -Name Api -MemberDefinition @'
[DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr GetModuleHandleA(string n);
[DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetShellWindow(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }
function WClass($h) { if ($h -eq [IntPtr]::Zero) { return 'NULL' }; $sb = New-Object System.Text.StringBuilder 256; [void][SW.Api]::GetClassNameW($h, $sb, $sb.Capacity); return $sb.ToString() }

A "=== SetShellWindow viability probe @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
A "session=$((Get-Process -Id $PID).SessionId)"

$u = [SW.Api]::GetModuleHandleA('user32.dll')
A "user32.dll base = 0x$($u.ToString('X'))"

foreach ($fn in 'GetShellWindow', 'SetShellWindow') {
    $p = [SW.Api]::GetProcAddress($u, $fn)
    A ("  {0,-16} export {1}" -f $fn, $(if ($p -eq [IntPtr]::Zero) { 'NOT PRESENT' } else { "present @ 0x$($p.ToString('X'))" }))
}

$before = [SW.Api]::GetShellWindow()
A ''
A "GetShellWindow() before = $(WClass $before)"
A "  hwnd 0x$($before.ToString('X'))"

if ($before -ne [IntPtr]::Zero) {
    # no-op: hand the current shell window straight back
    $ok = [SW.Api]::SetShellWindow($before)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $after = [SW.Api]::GetShellWindow()
    A ''
    A "SetShellWindow(current) returned $ok  GetLastError=$err"
    A "GetShellWindow() after  = $(WClass $after)  hwnd 0x$($after.ToString('X'))"
    A ''
    if ($ok -and $after -eq $before) {
        A '  => SetShellWindow WORKS on this Windows 11 build (call succeeded, value unchanged)'
        A '     the uWindows.pas fix premise holds'
    } else {
        A '  => SetShellWindow did NOT behave as expected - the fix premise needs revisiting'
    }
} else {
    A ''
    A '  shell window is NULL, so the no-op form cannot be tested here.'
}

# also record what the "shell consumer" APIs do with a NULL shell window
A ''
A '--- shell consumers that depend on GetShellWindow ---'
A '  (these are what break when the shell window is NULL)'
foreach ($fn in 'GetShellWindow', 'SetShellWindow', 'GetTaskmanWindow', 'SetTaskmanWindow', 'RegisterShellHookWindow') {
    $p = [SW.Api]::GetProcAddress($u, $fn)
    A ("  {0,-26} {1}" -f $fn, $(if ($p -eq [IntPtr]::Zero) { 'not exported' } else { 'exported' }))
}

$L | Out-File $out -Encoding utf8
Write-Host "written: $out"
