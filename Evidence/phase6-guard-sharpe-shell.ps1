# Phase 6 second half - ExplorerNET guard while SharpE IS the shell.
# Must NOT start a second shell: the guard should log "Ignoring shell arguments
# while SharpEnviro is the shell" and return.
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'
$out = Join-Path $share 'phase6-guard-sharpe-shell.txt'

Add-Type -Namespace G2 -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
public delegate bool EnumProc(IntPtr h, IntPtr l);
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }
function WC($h) { $sb = New-Object System.Text.StringBuilder 256; [void][G2.Api]::GetClassNameW($h, $sb, $sb.Capacity); $sb.ToString() }

function ShellState {
    $sh = [G2.Api]::GetShellWindow()
    $shellCls = if ($sh -eq [IntPtr]::Zero) { 'NULL' } else { WC $sh }
    $script:cab = 0; $script:sharpTray = 0
    $cb = [G2.Api+EnumProc] {
        param($hw, $l)
        $c = WC $hw
        if ($c -eq 'CabinetWClass' -and [G2.Api]::IsWindowVisible($hw)) { $script:cab++ }
        if ($c -eq 'Shell_TrayWnd') {
            [uint32]$p = 0; [void][G2.Api]::GetWindowThreadProcessId($hw, [ref]$p)
            $script:sharpTray += " $((Get-Process -Id $p -EA SilentlyContinue).ProcessName)($p)"
        }
        return $true
    }
    [void][G2.Api]::EnumWindows($cb, [IntPtr]::Zero)
    return "shellWindow=$shellCls  visibleCabinet=$($script:cab)  Shell_TrayWnd owners=[$($script:sharpTray.Trim())]  explorer=$([bool](Get-Process explorer -EA SilentlyContinue))"
}

$exe = 'C:\Program Files (x86)\SharpEnviro\Addons\x64\Explorer.exe'

A "=== phase 6 guard: SharpE IS the shell [$((Get-Date -Format 'HH:mm:ss'))] ==="
A "user=$(whoami) session=$((Get-Process -Id $PID).SessionId)"
A "SharpE running: SharpCore=$([bool](Get-Process SharpCore -EA SilentlyContinue)) SharpBar=$([bool](Get-Process SharpBar -EA SilentlyContinue))"
A ''
A "guard under test: $exe"
A ''
A "BEFORE: $(ShellState)"
A ''

A 'running: "Explorer.exe" C:\Windows   (expect: ignored, no second shell)'
try { Start-Process -FilePath $exe -ArgumentList 'C:\Windows' -EA Stop } catch { A "  launch error: $($_.Exception.Message)" }
Start-Sleep -Seconds 10

A "AFTER : $(ShellState)"
A ''
$expl = @(Get-Process explorer -EA SilentlyContinue)
$cab = (ShellState -split 'visibleCabinet=')[1].Split(' ')[0]
A "verdict:"
if (-not $expl -and $cab -eq '0') {
    A "  PASS - no explorer process and no Explorer window: arguments ignored, no second shell"
} elseif ($expl -or $cab -ne '0') {
    A "  FAIL - a second shell came up (explorer processes: $($expl.Count), visible CabinetWClass: $cab)"
}
A ''
A 'note: SharpDebug.Info writes over WM_COPYDATA to a TSharpEDebugWnd window (SharpConsole).'
A '      SharpConsole is not running here, so the message is not observable - behaviour is.'
$L | Out-File $out -Encoding utf8
Write-Host "written: $out"
