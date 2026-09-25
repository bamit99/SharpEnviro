# Phase 5 - UIPI, unambiguous. Run at RunLevel=Limited (medium integrity).
#
# ShowWindow's return value does not signal failure (it means "was previously
# visible"), so it cannot detect a UIPI block. Instead: post WM_CLOSE and observe
# whether the window survives. UIPI refuses messages from a lower integrity level,
# so a high-integrity Notepad must survive; a medium-integrity control must close.
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'
$out = Join-Path $share 'phase5-uipi.txt'

Add-Type -Namespace U2 -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
public delegate bool EnumProc(IntPtr h, IntPtr l);
'@
Add-Type -Namespace U2 -Name Tok -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
[DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr t, int c, IntPtr info, int len, out int ret);
[DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint a, bool i, int pid);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }
function WT($h) { $sb = New-Object System.Text.StringBuilder 256; [void][U2.Api]::GetWindowTextW($h, $sb, $sb.Capacity); $sb.ToString() }

function Integrity($pid_) {
    $h = [U2.Tok]::OpenProcess(0x1000, $false, $pid_)
    if ($h -eq [IntPtr]::Zero) { return -1 }
    $t = [IntPtr]::Zero
    if (-not [U2.Tok]::OpenProcessToken($h, 0x0008, [ref]$t)) { [void][U2.Tok]::CloseHandle($h); return -1 }
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(64); $rl = 0
    $ok = [U2.Tok]::GetTokenInformation($t, 25, $buf, 64, [ref]$rl)
    $lvl = -1
    if ($ok) {
        $sid = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
        $cnt = [Runtime.InteropServices.Marshal]::ReadByte($sid, 1)
        $lvl = [Runtime.InteropServices.Marshal]::ReadInt32($sid, 8 + (($cnt - 1) * 4))
    }
    [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    [void][U2.Tok]::CloseHandle($t); [void][U2.Tok]::CloseHandle($h)
    return $lvl
}
function IName($v) {
    switch ($v) { 0x1000 {'Low'} 0x2000 {'Medium'} 0x3000 {'High'} 0x4000 {'System'} default {"0x$('{0:X}' -f $v)"} }
}
function HwndOfPid($pid_) {
    $script:found = [IntPtr]::Zero
    $cb = [U2.Api+EnumProc] {
        param($hw, $l)
        [uint32]$p = 0; [void][U2.Api]::GetWindowThreadProcessId($hw, [ref]$p)
        if ($p -eq $pid_ -and [U2.Api]::IsWindowVisible($hw) -and (WT $hw)) { $script:found = $hw; return $false }
        return $true
    }
    [void][U2.Api]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:found
}

A "=== phase 5 UIPI (WM_CLOSE probe) @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
A "user=$(whoami)  session=$((Get-Process -Id $PID).SessionId)"
$me = [System.Diagnostics.Process]::GetCurrentProcess().Id
$miv = Integrity $me
A "driver integrity = $(IName $miv)"
A "claims Administrator = $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
A ''

# ---- control: a medium-integrity window created by this (medium) process ----
# wscript + VBS MsgBox: classic Win32, disposable, NOT single-instance, so it
# coexists with the high-integrity target (classic Notepad does not).
A '--- CONTROL: medium-integrity window (wscript MsgBox) ---'
$vbs = Join-Path $env:TEMP 'uipi-ctrl.vbs'
'MsgBox "UIPI control", 0, "UIPI control"' | Out-File $vbs -Encoding ascii
$ctrl = Start-Process wscript.exe -ArgumentList $vbs -PassThru
Start-Sleep -Seconds 5
$civ = Integrity $ctrl.Id
$chw = HwndOfPid $ctrl.Id
A "  pid=$($ctrl.Id) integrity=$(IName $civ) hwnd=0x$($chw.ToString('X'))  title='$(WT $chw)'"
if ($chw -ne [IntPtr]::Zero) {
    [void][U2.Api]::PostMessageW($chw, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Start-Sleep -Seconds 3
    $alive = $null -ne (Get-Process -Id $ctrl.Id -EA SilentlyContinue)
    A "  posted WM_CLOSE -> process $(if ($alive) { 'SURVIVED' } else { 'CLOSED' })"
    A "  => $($(if ($alive) { 'probe INCONCLUSIVE (control did not close)' } else { 'probe WORKS: a medium-integrity window CAN be driven by a medium process' }))"
} else { A '  no control window found' }
A ''

# ---- target: a high-integrity window ----
A '--- TARGET: high-integrity window (created by an elevated task) ---'
$targets = New-Object System.Collections.Generic.List[string]
$cb = [U2.Api+EnumProc] {
    param($hw, $l)
    if ([U2.Api]::IsWindowVisible($hw)) {
        $t = WT $hw
        if ($t -match 'Notepad') {
            [uint32]$p = 0; [void][U2.Api]::GetWindowThreadProcessId($hw, [ref]$p)
            if ((Integrity $p) -gt 0x2000) { $script:targets.Add("$hw`t$p"); }
        }
    }
    return $true
}
[void][U2.Api]::EnumWindows($cb, [IntPtr]::Zero)

if ($targets.Count -eq 0) { A '  none found' }
else {
    foreach ($row in $targets) {
        $f = $row -split "`t"
        $hw = [IntPtr][int64]$f[0]; $tp = $f[1]
        $tiv = Integrity $tp
        A "  pid=$tp integrity=$(IName $tiv) hwnd=0x$($hw.ToString('X'))  title='$(WT $hw)'"

        # SetWindowPos with a no-op change: a UIPI block surfaces as ACCESS_DENIED

        [void][U2.Api]::PostMessageW($hw, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        Start-Sleep -Seconds 3
        $alive = $null -ne (Get-Process -Id $tp -EA SilentlyContinue)
        A "    posted WM_CLOSE  -> process $(if ($alive) { 'SURVIVED' } else { 'CLOSED' })"
        A "    => $(if ($alive) { 'REFUSED - UIPI blocked the medium-integrity caller (EXPECTED)' } else { 'allowed - no UIPI block' })"
        A ''
    }
}

A 'SharpE''s bar runs at medium integrity (it is started by the user shell, unelevated),'
A 'so the same rule applies to its taskbar buttons on elevated windows: the window'
A 'cannot be minimised/activated, and the button becomes inert.'
$L | Out-File $out -Encoding utf8
Write-Host "written: $out"
