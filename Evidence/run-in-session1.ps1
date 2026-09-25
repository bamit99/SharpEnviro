# Generic "run a script in session 1 as amitb" helper.
# GetShellWindow / work area / window enumeration are per-session, so anything that
# observes the desktop must run here, not over WinRM (session 0).
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$Phase = '',
    [string]$OutFile = '',
    [int]$WaitSeconds = 20
)
$ErrorActionPreference = 'Continue'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$share = '\\vmware-host\Shared Folders\Evidence'

$task = 'SharpE-Session1Run'
Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue

$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
if ($Phase) { $argLine = "-Command `"`$env:SHARPE_PHASE='$Phase'; & '$Script'`"" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$principal = New-ScheduledTaskPrincipal -UserId 'SHARPENVIRO\amitb' -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds $WaitSeconds
$info = Get-ScheduledTaskInfo -TaskName $task
Write-Output ("task '$task' last result = {0}" -f $info.LastTaskResult)
Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue

if ($OutFile) {
    if (Test-Path $OutFile) { Get-Content $OutFile | ForEach-Object { Write-Output "  $_" } }
    else { Write-Output "NO OUTPUT at $OutFile" }
}
