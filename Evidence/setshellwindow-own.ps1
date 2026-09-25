# Does SetShellWindow work when the caller passes a window IT OWNS?
#
# The earlier probe passed explorer's Progman from another process and got
# ERROR_ACCESS_DENIED. SharpE passes its own Shell_TrayWnd, so that is the case
# that matters. This creates a top-level window owned by THIS process (no custom
# window class needed - the built-in STATIC class serves), claims the shell
# window with it, reads the result back, then restores the original.
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'
$out = Join-Path $share 'setshellwindow-own.txt'

try {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ShellWin {
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetShellWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowExW(uint exStyle, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern void SetLastError(uint e);

    static string ClassOf(IntPtr h) {
        if (h == IntPtr.Zero) return "NULL";
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // returns a report; always restores the original shell window
    public static string Run() {
        var log = new StringBuilder();
        IntPtr orig = GetShellWindow();
        uint op = 0; GetWindowThreadProcessId(orig, out op);
        log.AppendLine("original shell window = " + ClassOf(orig) + "  0x" + orig.ToInt64().ToString("X") + "  ownerPid=" + op);
        log.AppendLine("this process pid      = " + System.Diagnostics.Process.GetCurrentProcess().Id);

        // WS_POPUP = 0x80000000 -> top-level window owned by this process
        IntPtr mine = CreateWindowExW(0, "STATIC", "SharpEnviro shell-window probe", 0x80000000u,
            0, 0, 100, 100, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (mine == IntPtr.Zero) {
            log.AppendLine("CreateWindowExW FAILED, GetLastError=" + Marshal.GetLastWin32Error());
            return log.ToString();
        }
        uint mp = 0; GetWindowThreadProcessId(mine, out mp);
        log.AppendLine("created my window     = " + ClassOf(mine) + "  0x" + mine.ToInt64().ToString("X") + "  ownerPid=" + mp);
        log.AppendLine("  (ownerPid == this process pid => it is mine)");
        log.AppendLine();

        try {
            SetLastError(0);
            bool r1 = SetShellWindow(mine);
            int e1 = Marshal.GetLastWin32Error();
            IntPtr now1 = GetShellWindow();
            log.AppendLine("SetShellWindow(MY window)  -> returned " + r1 + "  GetLastError=" + e1);
            log.AppendLine("GetShellWindow() now       = " + ClassOf(now1) + "  0x" + now1.ToInt64().ToString("X"));
            log.AppendLine("  => " + ((r1 && now1 == mine)
                ? "WORKS: a process CAN claim the shell window with its own window"
                : "DID NOT take: the fix premise is wrong on this build"));
            log.AppendLine();

            // restore
            SetLastError(0);
            bool r2 = SetShellWindow(orig);
            int e2 = Marshal.GetLastWin32Error();
            IntPtr now2 = GetShellWindow();
            log.AppendLine("restore SetShellWindow(original) -> returned " + r2 + "  GetLastError=" + e2);
            log.AppendLine("GetShellWindow() after restore   = " + ClassOf(now2) + "  0x" + now2.ToInt64().ToString("X"));
            log.AppendLine("  restored correctly = " + (now2 == orig));
        }
        finally {
            DestroyWindow(mine);
        }
        return log.ToString();
    }
}
'@
} catch { Write-Host ('ADD-TYPE FAILED: ' + $_.Exception.Message); }

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }

A "=== SetShellWindow with a self-owned window @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
A "session=$((Get-Process -Id $PID).SessionId)  admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
A ''
try {
    $r = [ShellWin]::Run()
    $r -split "`r?`n" | ForEach-Object { A $_ }
} catch {
    A ('RUN FAILED: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
}

$L | Out-File $out -Encoding utf8
Write-Host "written: $out"
