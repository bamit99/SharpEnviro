# Phase 7 - isolate the .NET 3.5 gate.
# The Delphi runtime gate reads NDP\v3.5\Install and returns False on stock Win11,
# which silently disables the desktop host (Addons\x64\Explorer.exe) and link launcher.
$ErrorActionPreference = 'Continue'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$share = '\\vmware-host\Shared Folders\Evidence'
$out = Join-Path $share 'phase7-net35-gate.txt'

$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s); Write-Output $s }

A "=== phase 7: .NET 3.5 gate @ $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# what the gate reads, in both views
foreach ($v in '64', '32') {
    $r = (reg query 'HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' /v Install "/reg:$v" 2>&1) -join ' '
    $has = if ($r -match 'Install') { ($r -replace '\s+', ' ').Trim() } else { 'ABSENT (key not present)' }
    A ("  NDP\v3.5\Install  [{0}-bit view] = {1}" -f $v, $has)
}
$r4 = (reg query 'HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>&1) -join ' '
A ("  NDP\v4\Full\Release             = {0}" -f (($r4 -replace '\s+', ' ').Trim()))
A ""

# is the feature actually installed?
A '--- optional feature state ---'
try {
    $f = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -EA Stop
    A ("  NetFx3 feature state = {0}" -f $f.State)
} catch {
    try {
        $d = (dism /online /get-featureinfo /featurename:NetFx3 2>&1) -join "`n"
        $m = [regex]::Match($d, 'State\s*:\s*(\w+)')
        A ("  dism NetFx3 state = {0}" -f $(if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }))
    } catch { A "  could not query NetFx3: $($_.Exception.Message)" }
}
A ""

# what the gate decides
$install35 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' -Name Install -EA SilentlyContinue).Install
A '--- gate decision ---'
A ("  NDP\v3.5\Install = {0}" -f $(if ($null -ne $install35) { $install35 } else { '<absent>' }))
A ("  -> Delphi NETFramework35 gate returns {0}" -f $(if ($install35 -eq 1) { 'TRUE (host would start)' } else { 'FALSE (host disabled)' }))
A ""

# is the desktop host actually running?
A '--- desktop host / link launcher ---'
foreach ($n in 'Explorer', 'SharpLinkLauncherNET', 'SharpShellServicesNET', 'SharpSearchNET') {
    $p = Get-Process -Name $n -EA SilentlyContinue
    A ("  {0,-24} {1}" -f $n, $(if ($p) { 'RUNNING pid=' + (($p.Id) -join ',') } else { '<not running>' }))
}
A "  (the desktop host only starts when the 3.5 gate returns True)"
A ''
A '--- the built Addons\x64\Explorer.exe ---'
$h = 'C:\Program Files (x86)\SharpEnviro\Addons\x64\Explorer.exe'
if (Test-Path $h) {
    A ("  exists = True  size = {0}" -f (Get-Item $h).Length)
    $m = (reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer' /v DesktopProcess -EA SilentlyContinue) -join ' '
    A ("  DesktopProcess = {0}" -f $(if ($m -match 'DesktopProcess') { ($m -replace '\s+',' ').Trim() } else { '<not set>' }))
} else { A '  MISSING' }

$L | Out-File $out -Encoding utf8
Write-Output "written: $out"
