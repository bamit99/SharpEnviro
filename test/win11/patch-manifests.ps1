<#
    Injects the Windows 11 manifests (supportedOS + comctl32 v6) into the shipped
    SharpEnviro 0.8 RC3 executables, so the manifest fix can be tested without a
    Delphi rebuild.

    Two mechanisms, both offline:
      1. the documented Win32 resource API (BeginUpdateResource/UpdateResource);
      2. mt.exe (shipped in .\mt\, with its MidlrtMd.dll) as a fallback for the
         binaries BeginUpdateResource mangles - observed on SharpSplash.exe.

    Every candidate is verified after patching (PE image still mappable, resource
    tree intact, exactly one RT_MANIFEST with supportedOS and an execution level,
    icons and version info preserved) and restored from its backup if it fails.

    Run inside the VM, elevated, with SharpE stopped:

        powershell -ExecutionPolicy Bypass -File .\patch-manifests.ps1 -WhatIf
        powershell -ExecutionPolicy Bypass -File .\patch-manifests.ps1
        powershell -ExecutionPolicy Bypass -File .\patch-manifests.ps1 -Restore
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TargetDir   = "${env:ProgramFiles(x86)}\SharpEnviro",
    [string]$ManifestDir = '',
    [string]$MtExe       = '',
    [switch]$Restore,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated while parameter defaults are evaluated under
# 'powershell -File' (observed on Windows PowerShell 5.1), so resolve here.
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ManifestDir)  { $ManifestDir = Join-Path $PSScriptRoot 'manifests' }
if (-not $MtExe)        { $MtExe       = Join-Path $PSScriptRoot 'mt\mt.exe' }

$targets = @(
    'SharpCore.exe', 'SharpBar.exe', 'SharpDesk.exe', 'SharpMenu.exe', 'SharpCenter.exe',
    'SharpConsole.exe', 'SharpSplash.exe', 'SharpSkin.exe', 'SetShell.exe', 'SharpScript.exe',
    'SharpAdmin.exe', 'Addons\SkinConvert.exe'
)
$blocking  = 'SharpCore', 'SharpBar', 'SharpDesk', 'SharpMenu', 'SharpCenter', 'SharpConsole', 'SetShell', 'SharpSplash', 'SharpSkin'
$backupDir = Join-Path $TargetDir '_manifest-backup'

Add-Type -Namespace SharpE -Name Res -MemberDefinition @'
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr BeginUpdateResourceW(string p, bool del);
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool UpdateResourceW(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool EndUpdateResourceW(IntPtr h, bool discard);
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr LoadLibraryExW(string f, IntPtr h, uint flags);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeLibrary(IntPtr h);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr FindResourceExW(IntPtr h, IntPtr type, IntPtr name, ushort lang);
[DllImport("kernel32.dll", SetLastError=true)] public static extern uint SizeofResource(IntPtr h, IntPtr r);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr LoadResource(IntPtr h, IntPtr r);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr LockResource(IntPtr r);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool EnumResourceLanguagesW(IntPtr h, IntPtr type, IntPtr name, EnumResLangProc cb, IntPtr l);
public delegate bool EnumResLangProc(IntPtr h, IntPtr type, IntPtr name, ushort lang, IntPtr l);
'@

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

namespace SharpE
{
    // PE structure + resource tree inspection.
    // [0]=error ("" = ok), [1]=RT_ICON/RT_GROUP_ICON type count, [2]=RT_VERSION present,
    // [3]=RT_MANIFEST present, [4]=languages of RT_MANIFEST/1, [5]="image maps" (0/1)
    public static class Pe
    {
        public static string[] Check(string path)
        {
            var res = new string[] { "", "0", "0", "0", "", "0" };
            try
            {
                byte[] d = File.ReadAllBytes(path);
                if (d.Length < 0x100) { res[0] = "file too small"; return res; }
                int pe = BitConverter.ToInt32(d, 0x3C);
                if (pe <= 0 || pe + 24 > d.Length) { res[0] = "bad e_lfanew"; return res; }
                if (BitConverter.ToUInt32(d, pe) != 0x00004550) { res[0] = "no PE signature"; return res; }
                int nsec = BitConverter.ToUInt16(d, pe + 6);
                int optsz = BitConverter.ToUInt16(d, pe + 20);
                if (nsec <= 0 || nsec > 96) { res[0] = "implausible section count " + nsec; return res; }
                int opt = pe + 24;
                if (opt + optsz > d.Length) { res[0] = "optional header out of range"; return res; }
                ushort magic = BitConverter.ToUInt16(d, opt);
                if (magic != 0x10b && magic != 0x20b) { res[0] = "bad optional header magic"; return res; }
                uint imageSize = BitConverter.ToUInt32(d, opt + 56);
                int ddOff = opt + (magic == 0x20b ? 112 : 96);
                uint rsrcRva = BitConverter.ToUInt32(d, ddOff + 16);
                int secOff = opt + optsz;
                int rsrcOff = -1;
                for (int i = 0; i < nsec; i++)
                {
                    int s = secOff + i * 40;
                    if (s + 40 > d.Length) { res[0] = "section table out of range"; return res; }
                    uint vsz = BitConverter.ToUInt32(d, s + 8), va = BitConverter.ToUInt32(d, s + 12);
                    uint rsz = BitConverter.ToUInt32(d, s + 16), ra = BitConverter.ToUInt32(d, s + 20);
                    if (rsz > 0 && (long)ra + rsz > d.Length) { res[0] = "section " + i + " raw range past EOF"; return res; }
                    if (vsz > 0 && (long)va + vsz > (long)imageSize + 0x1000) { res[0] = "section " + i + " rva range past SizeOfImage"; return res; }
                    uint span = Math.Max(vsz, rsz);
                    if (rsrcRva != 0 && rsrcRva >= va && rsrcRva < va + span) rsrcOff = (int)(ra + (rsrcRva - va));
                }
                if (rsrcRva == 0) { res[0] = "no resource directory"; return res; }
                if (rsrcOff < 0 || rsrcOff + 16 > d.Length) { res[0] = "resource directory not mapped"; return res; }

                var langs = new List<string>();
                int iconTypes = 0, version = 0, manifest = 0;
                Walk(d, rsrcOff, rsrcOff, 0, ref iconTypes, ref version, ref manifest, langs, -1, 0);
                res[1] = iconTypes.ToString();
                res[2] = version > 0 ? "1" : "0";
                res[3] = manifest > 0 ? "1" : "0";
                langs.Sort();
                res[4] = string.Join(",", langs.ToArray());
                res[5] = MapsAsImage(path) ? "1" : "0";
            }
            catch (Exception e) { res[0] = e.GetType().Name + ": " + e.Message; }
            return res;
        }

        static bool MapsAsImage(string path)
        {
            IntPtr h = LoadLibraryExW(path, IntPtr.Zero, 0x20);   // LOAD_LIBRARY_AS_IMAGE_RESOURCE
            if (h == IntPtr.Zero) return false;
            FreeLibrary(h);
            return true;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryExW(string f, IntPtr h, uint flags);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FreeLibrary(IntPtr h);

        static void Walk(byte[] d, int rootOff, int dirOff, int level, ref int iconTypes, ref int version,
                         ref int manifest, List<string> langs, int curType, int depth)
        {
            if (depth > 3 || dirOff + 16 > d.Length) return;
            int named = BitConverter.ToUInt16(d, dirOff + 12);
            int ids = BitConverter.ToUInt16(d, dirOff + 14);
            int n = named + ids;
            if (n < 0 || n > 4096 || dirOff + 16 + n * 8 > d.Length) return;
            for (int i = 0; i < n; i++)
            {
                int e = dirOff + 16 + i * 8;
                uint name = BitConverter.ToUInt32(d, e);
                uint off = BitConverter.ToUInt32(d, e + 4);
                bool isId = (name & 0x80000000) == 0;
                int id = isId ? (int)(name & 0xFFFF) : -1;
                if ((off & 0x80000000) != 0)
                {
                    int child = rootOff + (int)(off & 0x7FFFFFFF);
                    if (level == 0)
                    {
                        if (id == 3 || id == 14) iconTypes++;
                        if (id == 16) version++;
                        if (id == 24) manifest++;
                        Walk(d, rootOff, child, level + 1, ref iconTypes, ref version, ref manifest, langs, id, depth + 1);
                    }
                    else
                    {
                        Walk(d, rootOff, child, level + 1, ref iconTypes, ref version, ref manifest, langs, curType, depth + 1);
                    }
                }
                else if (level == 2 && id >= 0 && curType == 24)
                {
                    langs.Add("0x" + id.ToString("X4"));
                }
            }
        }
    }
}
'@

function New-Handle([int]$id) { [IntPtr]::new($id) }
$MANIFEST_TYPE = New-Handle 24
$MANIFEST_NAME = New-Handle 1

function Get-ManifestText([string]$exe) {
    $h = [SharpE.Res]::LoadLibraryExW($exe, [IntPtr]::Zero, 0x2)   # LOAD_LIBRARY_AS_DATAFILE
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
        $r = [SharpE.Res]::FindResourceExW($h, $MANIFEST_TYPE, $MANIFEST_NAME, 0)   # 0 = any language
        if ($r -eq [IntPtr]::Zero) { return $null }
        $sz = [SharpE.Res]::SizeofResource($h, $r)
        if ($sz -eq 0) { return $null }
        $p = [SharpE.Res]::LockResource([SharpE.Res]::LoadResource($h, $r))
        if ($p -eq [IntPtr]::Zero) { return $null }
        $buf = New-Object byte[] ([int]$sz)
        [Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, [int]$sz)
        [Text.Encoding]::UTF8.GetString($buf)
    } finally { [void][SharpE.Res]::FreeLibrary($h) }
}

function Get-ManifestLangs([string]$exe) {
    $h = [SharpE.Res]::LoadLibraryExW($exe, [IntPtr]::Zero, 0x2)
    if ($h -eq [IntPtr]::Zero) { return @() }
    $langs = New-Object System.Collections.Generic.List[int]
    try {
        $cb = [SharpE.Res+EnumResLangProc]{
            param($m, $t, $n, $lang, $l)
            $langs.Add([int]$lang) | Out-Null
            return $true
        }
        [void][SharpE.Res]::EnumResourceLanguagesW($h, $MANIFEST_TYPE, $MANIFEST_NAME, $cb, [IntPtr]::Zero)
    } finally { [void][SharpE.Res]::FreeLibrary($h) }
    return $langs
}

function Set-ManifestText([string]$exe, [string]$text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $langs = @(Get-ManifestLangs $exe)
    $lang = 1033
    if ($langs.Count -gt 0) { $lang = $langs[0] }

    $h = [SharpE.Res]::BeginUpdateResourceW($exe, $false)
    if ($h -eq [IntPtr]::Zero) { throw ("BeginUpdateResource failed ({0})" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    $ok = $true
    try {
        foreach ($l in $langs) {
            if (-not [SharpE.Res]::UpdateResourceW($h, $MANIFEST_TYPE, $MANIFEST_NAME, [uint16]$l, $null, 0)) { $ok = $false }
        }
        if (-not [SharpE.Res]::UpdateResourceW($h, $MANIFEST_TYPE, $MANIFEST_NAME, [uint16]$lang, $bytes, [uint32]$bytes.Length)) { $ok = $false }
    } finally {
        if (-not [SharpE.Res]::EndUpdateResourceW($h, (-not $ok))) { $ok = $false }
    }
    if (-not $ok) { throw ("UpdateResource failed ({0})" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    return $lang
}

function Test-Patched([string]$exe, [string]$manifestText, [string[]]$peBefore) {
    $pe  = [SharpE.Pe]::Check($exe)
    $man = Get-ManifestText $exe
    $problems = @()
    if ($pe[0]) { $problems += "PE broken: $($pe[0])" }
    if ($pe[5] -ne '1') { $problems += 'image no longer maps' }
    if ($pe[3] -ne '1') { $problems += 'no manifest resource' }
    if ((@($pe[4] -split ',') | Where-Object { $_ }).Count -ne 1) { $problems += "manifest language entries = '$($pe[4])'" }
    if (-not $man -or -not $man.Contains('8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a')) { $problems += 'supportedOS missing' }
    if ($man -and -not ($man.Contains('asInvoker') -or $man.Contains('requireAdministrator'))) { $problems += 'execution level missing' }
    if ([int]$peBefore[1] -gt 0 -and [int]$pe[1] -eq 0) { $problems += 'icon resources lost' }
    if ($peBefore[2] -eq '1' -and $pe[2] -ne '1') { $problems += 'version resource lost' }
    return ,@($problems, $pe, $man)
}

function Assert-Inputs {
    if (-not (Test-Path $ManifestDir)) { throw "manifest dir not found at $ManifestDir" }
    if (-not (Test-Path $TargetDir))   { throw "target dir not found: $TargetDir" }
}

function Assert-NotRunning {
    if ($Force) { return }
    $running = @()
    foreach ($n in $blocking) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) { $running += "$n(pid $($p.Id -join ','))" }
    }
    if ($running) { throw ("SharpE is running ($($running -join ', ')) - stop it first (SharpConsole: !Shutdown, or Task Manager).") }
}

Assert-Inputs

if ($Restore) {
    if (-not (Test-Path $backupDir)) { throw "no backup dir at $backupDir - nothing to restore" }
    foreach ($b in (Get-ChildItem $backupDir -Recurse -Filter *.exe -File)) {
        $rel  = $b.FullName.Substring($backupDir.Length).TrimStart('\')
        $dest = Join-Path $TargetDir $rel
        if ($PSCmdlet.ShouldProcess($dest, "restore original $rel")) {
            $dir = Split-Path -Parent $dest
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Copy-Item $b.FullName $dest -Force
            Write-Host ("restored {0}  ({1:N0} bytes)" -f $rel, (Get-Item $dest).Length)
        }
    }
    return
}

Assert-NotRunning
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$haveMt = Test-Path $MtExe

$patched = 0; $skipped = 0; $failed = @()
foreach ($rel in $targets) {
    $exe  = Join-Path $TargetDir $rel
    $name = Split-Path $rel -Leaf
    if (-not (Test-Path $exe)) { Write-Host ("skip   {0} (not installed)" -f $rel); $skipped++; continue }

    $manifest = Join-Path $ManifestDir ($name -replace '\.exe$', '.manifest')
    if (-not (Test-Path $manifest)) { Write-Host ("skip   {0} (no manifest)" -f $rel); $skipped++; continue }

    $peBefore  = [SharpE.Pe]::Check($exe)
    $manBefore = Get-ManifestText $exe
    if ($peBefore[0]) { Write-Host ("skip   {0} (cannot parse PE: {1})" -f $rel, $peBefore[0]); $skipped++; continue }
    if ($manBefore -and $manBefore.Contains('8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a')) {
        Write-Host ("skip   {0} (already declares supportedOS)" -f $rel); $skipped++; continue
    }
    $beforeLen = 0
    if ($manBefore) { $beforeLen = $manBefore.Length }

    if (-not $PSCmdlet.ShouldProcess($exe, "inject $([IO.Path]::GetFileName($manifest))")) {
        Write-Host ("DRY    {0}  manifest {1} -> {2} bytes, icons {3}, version {4}" -f `
            $rel, $beforeLen, (Get-Item $manifest).Length, $peBefore[1], $peBefore[2])
        continue
    }

    $backup = Join-Path $backupDir $rel
    if (-not (Test-Path $backup)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Copy-Item $exe $backup -Force
    }
    $manifestText = [IO.File]::ReadAllText($manifest)

    $method = 'resource API'
    $lang = -1
    $verify = $null
    try {
        $lang = Set-ManifestText $exe $manifestText
        $verify = Test-Patched $exe $manifestText $peBefore
    } catch {
        $verify = ,@(@($_.Exception.Message), [SharpE.Pe]::Check($exe), $null)
    }

    if ($verify[0].Count -gt 0 -and $haveMt) {
        # BeginUpdateResource mangles some of these 2011 images (seen on SharpSplash.exe);
        # mt.exe handles them, so retry with it before giving up.
        Write-Host ("       {0}: resource API failed ({1}) - retrying with mt.exe" -f $rel, ($verify[0] -join '; '))
        Copy-Item $backup $exe -Force
        $r = & $MtExe -nologo '-manifest' $manifest "-outputresource:$exe;#1" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $verify = Test-Patched $exe $manifestText $peBefore
            if ($verify[0].Count -eq 0) { $method = 'mt.exe' }
        } else {
            $verify = ,@(@("mt.exe exit $LASTEXITCODE", [SharpE.Pe]::Check($exe), $null))
        }
    }

    $pe = $verify[1]; $man = $verify[2]
    if ($verify[0].Count -gt 0) {
        Copy-Item $backup $exe -Force
        $chk = [SharpE.Pe]::Check($exe)
        Write-Host ("FAIL   {0}  {1}  (original restored; restored file sane: {2})" -f $rel, ($verify[0] -join '; '), (-not $chk[0]))
        $failed += $rel
        continue
    }

    $afterLen = 0
    if ($man) { $afterLen = $man.Length }
    Write-Host ("OK     {0}  manifest {1} -> {2} bytes, icons {3}, version {4}, image maps {5}, via {6}" -f `
        $rel, $beforeLen, $afterLen, $pe[1], $pe[2], $pe[5], $method)
    $patched++
}

Write-Host ''
Write-Host ("patched {0}, skipped {1}, failed {2}" -f $patched, $skipped, $failed.Count)
if ($failed.Count) { Write-Host ("not patched (originals restored): {0}" -f ($failed -join ', ')); exit 2 }
Write-Host "originals in $backupDir (use -Restore to put them back)"
Write-Host "see TESTPLAN.md phase 3 for how to observe the effect (SharpConsole prints the OS version)."
