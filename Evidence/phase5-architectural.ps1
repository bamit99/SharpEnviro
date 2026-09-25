# Phase 5 - architectural checks. Runs in session 1 (per-session APIs).
#
# Checks:
#   1. two shells      - start explorer.exe while SharpE is the shell
#   2. tray ownership  - who owns Shell_TrayWnd before/after
#   3. cloak filter    - are cloaked windows reported as task buttons?
#   4. show desktop    - does the bar's "show desktop" reach anything?
#   5. work area       - does maximising cover the bar?
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'
$out = Join-Path $share 'phase5-architectural.txt'

Add-Type -Namespace AR -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr FindWindowW(string c, string n);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint f);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }
function WC($h) { $sb = New-Object System.Text.StringBuilder 256; [void][AR.Api]::GetClassNameW($h, $sb, $sb.Capacity); $sb.ToString() }
function WT($h) { $sb = New-Object System.Text.StringBuilder 256; [void][AR.Api]::GetWindowTextW($h, $sb, $sb.Capacity); $sb.ToString() }
function PO($h) { [uint32]$p = 0; [void][AR.Api]::GetWindowThreadProcessId($h, [ref]$p); $pr = Get-Process -Id $p -EA SilentlyContinue; "$($pr.ProcessName)($p)" }

function Snap {
    $script:w = New-Object System.Collections.Generic.List[string]
    $cb = [AR.Api+EnumProc] {
        param($hw, $l)
        if ([AR.Api]::IsWindowVisible($hw)) {
            $cl = WC $hw; $ck = 0
            [void][AR.Api]::DwmGetWindowAttribute($hw, 14, [ref]$ck, 4)
            $script:w.Add(("    {0,-30} {1,-20} cloaked={2} '{3}'" -f $cl, (PO $hw), $ck, (WT $hw)))
        }
        return $true
    }
    [void][AR.Api]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:w
}
function Work {
    $r = New-Object AR.Api+RECT
    [void][AR.Api]::SystemParametersInfo(0x0030, 0, [ref]$r, 0)
    "L$($r.Left) T$($r.Top) R$($r.Right) B$($r.Bottom) ($($r.Right-$r.Left)x$($r.Bottom-$r.Top))"
}

A "=== phase 5 architectural checks @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
A "user=$(whoami) session=$((Get-Process -Id $PID).SessionId)"
$sh = [AR.Api]::GetShellWindow()
A "GetShellWindow() = $(if ($sh -eq [IntPtr]::Zero) {'NULL'} else {"$(WC $sh) ($(PO $sh))"})"
$tw = [AR.Api]::FindWindowW('Shell_TrayWnd', $null)
A "Shell_TrayWnd    = $(if ($tw -eq [IntPtr]::Zero) {'absent'} else {"$(PO $tw)"})"
A "screen           = $([AR.Api]::GetSystemMetrics(0))x$([AR.Api]::GetSystemMetrics(1))"
A "work area (pre)  = $(Work)"
A "explorer running = $([bool](Get-Process explorer -EA SilentlyContinue))"

# ---------------------------------------------------------------- 1 + 2: two shells
A ''
A '========== CHECK 1+2: start explorer.exe while SharpE is the shell =========='
A '--- BEFORE ---'
Snap | ForEach-Object { A $_ }
A ''
A 'launching explorer.exe ...'
try { Start-Process "$env:WINDIR\explorer.exe" -EA Stop } catch { A "  launch error: $($_.Exception.Message)" }
Start-Sleep -Seconds 10
A ''
A '--- AFTER ---'
Snap | ForEach-Object { A $_ }
A ''
$tw2 = [AR.Api]::FindWindowW('Shell_TrayWnd', $null)
$sh2 = [AR.Api]::GetShellWindow()
A "Shell_TrayWnd owner now = $(if ($tw2 -eq [IntPtr]::Zero) {'absent'} else {PO $tw2})   (was $(if ($tw -eq [IntPtr]::Zero) {'absent'} else {PO $tw}))"
A "GetShellWindow() now    = $(if ($sh2 -eq [IntPtr]::Zero) {'NULL'} else {"$(WC $sh2) ($(PO $sh2))"})"
A "work area now           = $(Work)"
$expl = @(Get-Process explorer -EA SilentlyContinue)
A "explorer processes      = $(if ($expl) { ($expl | ForEach-Object { "pid=$($_.Id) sess=$($_.SessionId)" }) -join ', ' } else { 'none' })"

# count the competing shells
$trayCount = 0
$cb2 = [AR.Api+EnumProc] {
    param($hw, $l)
    if ((WC $hw) -eq 'Shell_TrayWnd') { $script:trayCount++ }
    return $true
}
$script:trayCount = 0
[void][AR.Api]::EnumWindows($cb2, [IntPtr]::Zero)
A ''
A ">>> number of Shell_TrayWnd windows = $trayCount  (2+ means two shells are competing)"

# ---------------------------------------------------------------- 3: cloak filter
A ''
A '========== CHECK 3: cloaked windows (must never become task buttons) =========='
A 'opening a UWP-ish window to produce cloaked entries ...'
try { Start-Process 'calc.exe' -EA Stop } catch { A "  calc launch error" }
Start-Sleep -Seconds 6
$cloakedShown = 0
$cb3 = [AR.Api+EnumProc] {
    param($hw, $l)
    if ([AR.Api]::IsWindowVisible($hw)) {
        $ck = 0
        [void][AR.Api]::DwmGetWindowAttribute($hw, 14, [ref]$ck, 4)
        if ($ck -ne 0) {
            $script:cloakedShown++
            $L.Add(("    CLOAKED({0}) {1,-30} {2,-20} '{3}'" -f $ck, (WC $hw), (PO $hw), (WT $hw)))
        }
    }
    return $true
}
[void][AR.Api]::EnumWindows($cb3, [IntPtr]::Zero)
A "  visible-but-cloaked windows found = $cloakedShown"
A '  (these are exactly the windows a cloak-blind taskbar would show as phantom buttons)'
$L | Where-Object { $_ -like '*CLOAKED(*' } | ForEach-Object { Write-Host $_ }

# ---------------------------------------------------------------- 5: work area
A ''
A '========== CHECK 5: work area vs bar =========='
A "  screen    = $([AR.Api]::GetSystemMetrics(0))x$([AR.Api]::GetSystemMetrics(1))"
A "  work area = $(Work)"
A '  SharpBar windows:'
Get-Process SharpBar -EA SilentlyContinue | ForEach-Object { A "    SharpBar pid=$($_.Id)" }

$L | Out-File $out -Encoding utf8
Write-Host "written: $out"
