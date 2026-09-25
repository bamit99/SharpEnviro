# Runs in the INTERACTIVE session (session 1). The ExplorerNET guard calls
# GetShellWindow(), which is per-session, so this must not be driven from WinRM.
$ErrorActionPreference = 'Continue'
$tag = $args[0]; if (-not $tag) { $tag = 'session1' }
$out = "\\vmware-host\Shared Folders\Evidence\guard-$tag.txt"

Add-Type -Namespace G -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
public delegate bool EnumProc(IntPtr h, IntPtr l);
'@

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add($s); Write-Host $s }

function Get-ShellInfo {
    $h = [G.Api]::GetShellWindow()
    if ($h -eq [IntPtr]::Zero) { return 'NULL' }
    $sb = New-Object System.Text.StringBuilder 256
    [void][G.Api]::GetClassNameW($h, $sb, $sb.Capacity)
    return "0x$($h.ToString('X')) class=$($sb.ToString())"
}

function Count-Cabinet {
    $script:c = 0
    $cb = [G.Api+EnumProc] {
        param($hw, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][G.Api]::GetClassNameW($hw, $sb, $sb.Capacity)
        if ($sb.ToString() -eq 'CabinetWClass' -and [G.Api]::IsWindowVisible($hw)) { $script:c++ }
        return $true
    }
    [void][G.Api]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:c
}

$exe = 'C:\Program Files (x86)\SharpEnviro\Addons\x64\Explorer.exe'

A "=== ExplorerNET guard test [$tag] @ $(Get-Date -Format 'HH:mm:ss') ==="
A "user      = $(whoami)"
A "sessionId = $((Get-Process -Id $PID).SessionId)"
A "GetShellWindow() = $(Get-ShellInfo)"
A ""

$beforeExp = @(Get-Process explorer -EA SilentlyContinue | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId }).Id
$beforeCab = Count-Cabinet
A "before: explorer pids = [$($beforeExp -join ',')]  visible CabinetWClass = $beforeCab"
A ""

A "running: \"$exe\" C:\\Windows"
try { Start-Process -FilePath $exe -ArgumentList 'C:\Windows' -EA Stop } catch { A "  launch error: $($_.Exception.Message)" }
Start-Sleep -Seconds 8

$afterExp = @(Get-Process explorer -EA SilentlyContinue | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId }).Id
$afterCab = Count-Cabinet
A "after : explorer pids = [$($afterExp -join ',')]  visible CabinetWClass = $afterCab"
A ""
$new = $afterCab -gt $beforeCab
A "verdict: a File Explorer window $(if ($new) { 'APPEARED -> guard forwarded to the real shell (PASS)' } else { 'did NOT appear -> arguments were ignored' })"

$L | Out-File $out -Encoding utf8
