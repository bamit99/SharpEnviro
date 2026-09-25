$ErrorActionPreference = 'Stop'
$out = '\\vmware-host\Shared Folders\Evidence\pinvoke-probe.txt'
$L = New-Object System.Collections.Generic.List[string]
function A($s) { $L.Add([string]$s) }

# Variant A: explicit ...W name + CharSet.Unicode  (what the capture script used)
try {
    Add-Type -Namespace VA -Name Api -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
'@
    $h = [VA.Api]::GetShellWindow()
    $sb = New-Object System.Text.StringBuilder 256
    $n = [VA.Api]::GetClassNameW($h, $sb, $sb.Capacity)
    A "A (name=GetClassNameW, CharSet=Unicode): ret=$n class='$($sb.ToString())'"
} catch { A "A THREW: $($_.Exception.GetType().Name): $($_.Exception.Message)" }

# Variant B: unsuffixed name + CharSet.Unicode -> CLR resolves GetClassNameW
try {
    Add-Type -Namespace VB -Name Api -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
'@
    $h = [VB.Api]::GetShellWindow()
    $sb = New-Object System.Text.StringBuilder 256
    $n = [VB.Api]::GetClassName($h, $sb, $sb.Capacity)
    A "B (name=GetClassName, CharSet=Unicode): ret=$n class='$($sb.ToString())'"
} catch { A "B THREW: $($_.Exception.GetType().Name): $($_.Exception.Message)" }

# Variant C: explicit name + ExactSpelling
try {
    Add-Type -Namespace VC -Name Api -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
'@
    $h = [VC.Api]::GetShellWindow()
    $sb = New-Object System.Text.StringBuilder 256
    $n = [VC.Api]::GetClassNameW($h, $sb, $sb.Capacity)
    A "C (name=GetClassNameW, ExactSpelling): ret=$n class='$($sb.ToString())'"
} catch { A "C THREW: $($_.Exception.GetType().Name): $($_.Exception.Message)" }

# sanity: what does the shell window look like at all
A "shellWindow=0x$([VA.Api]::GetShellWindow().ToString('X'))"
A "session=$((Get-Process -Id $PID).SessionId)"
$L | Out-File $out -Encoding utf8
