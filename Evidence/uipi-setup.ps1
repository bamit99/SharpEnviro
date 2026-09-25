# UIPI target setup. MUST run at RunLevel=Highest so the window it creates is
# HIGH integrity. A scheduled task can do that; Start-Process -Verb RunAs cannot
# (it would raise a UAC prompt, and from WinRM it lands in session 0 anyway).
$ErrorActionPreference = 'Continue'
$share = '\\vmware-host\Shared Folders\Evidence'

# reuse an existing elevated notepad if one is already up
$existing = Get-Process notepad -EA SilentlyContinue
if ($existing) {
    Write-Host "notepad already running: pid=$($existing.Id -join ',')"
} else {
    $p = Start-Process notepad.exe -PassThru -EA SilentlyContinue
    Start-Sleep -Seconds 4
    Write-Host "started notepad pid=$($p.Id)"
}

$me = [System.Diagnostics.Process]::GetCurrentProcess().Id
"setup at $(Get-Date -Format 'HH:mm:ss')  setupPid=$me  notepadPid=$((Get-Process notepad -EA SilentlyContinue).Id -join ',')" |
    Out-File (Join-Path $share 'uipi-target.txt') -Encoding utf8
Write-Host "setup process elevated check: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
