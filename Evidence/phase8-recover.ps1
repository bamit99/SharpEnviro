# Wrapper: run recover-shell.cmd (a batch file) from a PowerShell session-1 task.
# recover-shell.cmd does: import restore-explorer.reg, stop SharpE processes,
# start explorer.exe.
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'
$log = Join-Path $share 'phase8-recovery.txt'

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Host $s }

A "=== phase 8 recovery @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
A "user=$(whoami) session=$((Get-Process -Id $PID).SessionId) admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
A ''
A '--- before ---'
A "  amitb HKCU Shell = $((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -EA SilentlyContinue).Shell)"
A "  SharpE: $((Get-Process SharpCore,SharpBar,SharpDesk -EA SilentlyContinue | ForEach-Object { $_.ProcessName }) -join ',')"
A "  explorer: $((Get-Process explorer -EA SilentlyContinue | ForEach-Object { $_.Id }) -join ',')"
A ''

A '--- running recover-shell.cmd ---'
$cmd = Join-Path $share 'recover-shell.cmd'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$cmd`"" -Wait -PassThru -WindowStyle Hidden
A "  exit code = $($p.ExitCode)"
A ''

Start-Sleep -Seconds 8
A '--- after ---'
A "  SharpE: $((Get-Process SharpCore,SharpBar,SharpDesk -EA SilentlyContinue | ForEach-Object { $_.ProcessName }) -join ',')"
A "  explorer: $((Get-Process explorer -EA SilentlyContinue | ForEach-Object { \"pid=$($_.Id) sess=$($_.SessionId)\" }) -join ', ')"
foreach ($k in 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\IniFileMapping\system.ini\boot', 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon') {
    $o = reg query $k /v Shell 2>&1 | Where-Object { $_ -match 'REG_SZ' }
    A ("  {0} -> {1}" -f $k, (($o -join '') -replace '\s+', ' ').Trim())
}
A ("  HKCU Shell (amitb) = '{0}'" -f (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -EA SilentlyContinue).Shell)

$L | Out-File $log -Encoding utf8
Write-Host "written: $log"
