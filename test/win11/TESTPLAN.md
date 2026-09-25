# SharpEnviro on Windows 11 — VM test plan (round 1)

Everything here runs **inside the VM**. The folder that contains this file is meant to be shared
into it (VMware: *VM → Settings → Options → Shared Folders → add `E:\Git\SharpE-vmtest`*, name it
`SharpE-vmtest`); the collector writes its report next to the script, so evidence comes straight out
of the VM.

---

## 0. Safety (do this first)

1. **Snapshot the VM** before every phase. A shell replacement that fails leaves you with no desktop.
2. Recovery, if the VM boots to a black screen:
   - `Ctrl+Alt+Del` → **Task Manager** (`Ctrl+Shift+Esc` is served by the shell and may do nothing).
   - *File → Run new task* → tick *administrative privileges* → `cmd`.
   - Run `\\vmware-host\Shared Folders\SharpE-vmtest\recover-shell.cmd`
     (imports `restore-explorer.reg`, kills SharpE processes, starts `explorer.exe`).
   - Log off / on again. Explorer is the shell again.
3. `restore-explorer.reg` restores exactly what Windows ships: `HKLM\...\Winlogon\Shell` = `explorer.exe`,
   `IniFileMapping\system.ini\boot\Shell` = `SYS:Microsoft\Windows NT\CurrentVersion\Winlogon`
   (verified against a stock Windows 11 build 26200), and removes the `HKCU` overrides SharpE writes.

---

## Folder contents (already staged for you)

| Item | What it is |
|---|---|
| `SharpE-0.8-RC3-Setup.exe` | the official 2011 installer (33.8 MB), downloaded from SourceForge (`sha256 e0f99ed3…`) |
| `SharpE-0.8-RC3-win11-Setup.exe` | **the rebuild** (32.3 MB, `sha256 c62b82df…`): identical file layout, compiled on the host from the patched `Installer/SharpE-0.8-Setup.nsi` with NSIS 3.11 — rebuilt net481 `Addons\x64\`, the SQLite interop it needs, no `dotNetFx35setup.exe`, checked shell-redirect write. Compile + payload audited host-side; **never executed** → phase 1b |
| `payload\` | the same installer's files extracted with 7z (pristine, 151 MB) — lets you deploy without running the installer if its .NET page gets in the way |
| `patch-manifests.ps1` + `manifests\` + `mt\` | injects the Windows 11 manifests into the installed EXEs (self-verifying, auto-rollback) |
| `collect-evidence.ps1` | read-only evidence collector (OS, shell registry, .NET, processes, window classes + cloaked flags, embedded manifests, event log) |
| `recover-shell.cmd` + `restore-explorer.reg` | puts Explorer back as the shell |
| `managed-x64\` | the patched repo's freshly built **net481** components with `supportedOS` manifests (drop-in for `<install>\Addons\x64\`) |
| `evidence-EXAMPLE-host-win11-25H2.txt` | what the collector's output looks like — run on the host (Win11 25H2, build 26200, 150 % scaling); compare your VM report against it |

---

## 1. What this round can and cannot prove

| Provable today (no Delphi compiler needed) | Not provable in this round |
|---|---|
| Whether a 2011 shell replacement runs at all on Win11 25H2/26H1 | The `.pas`/`.dpr` fixes — no Delphi 2007 build on the host, so these binaries are stock 0.8 RC3 |
| The `supportedOS` manifest fix, injected into the real 2011 EXEs with `mt.exe` (phase 2–3) | The installer's interactive pages, elevation behaviour and shortcut creation — the script is now compiled and its payload audited host-side; phase 1b runs it |
| The `.NET 3.5` gate diagnosis, by enabling/disabling 3.5 (phase 7) | The new cloak filter / AppBar EX / `SetShellWindow` code |
| The rebuilt **net481** managed components under .NET 4.8, plus their manifests and the ExplorerNET arg guard (phase 6) | |
| Every architectural blocker from the code review: tray/AppBar ownership, work-area override, Explorer coexistence, DPI, UIPI (phase 5) | |

---

## 2. Phase 0 — baseline

```powershell
powershell -ExecutionPolicy Bypass -File \\vmware-host\Shared Folders\SharpE-vmtest\collect-evidence.ps1 -Tag baseline
```
Expect: no `Sharp*` processes; `GetShellWindow()` = a window of class **Progman** owned by `explorer`;
.NET 3.5 `Install` absent, `v4\Full\Release` ≥ 528040; no `SharpEnviro` install dir.

## 3. Phase 1 — install 0.8 RC3, but do *not* become the shell yet

The installer is a 32-bit NSIS program, so `$PROGRAMFILES` resolves to
**`C:\Program Files (x86)\SharpEnviro`** — that is where everything lands (and why
`patch-manifests.ps1` defaults `-TargetDir` to `${env:ProgramFiles(x86)}\SharpEnviro`). The 32-bit
registry view carries the installer's keys: `HKLM\SOFTWARE\WOW6432Node\SharpEnviro`.

1. Copy `SharpE-0.8-RC3-Setup.exe` into the VM, run it **as administrator**.
2. On the *“Change Windows Default Shell”* page pick **change the shell manually later** (the lower
   radio). The page's default is the *upper* one, “Change the Windows Shell to SharpE now”: leaving it
   selected makes the installer rewrite the shell registration (HKCU `Winlogon\Shell` + the
   machine-wide `IniFileMapping` → `USR:...`) and offer a reboot at the end.
3. Collect evidence with `-Tag installed`.

Expect / what it shows:
- The installer's .NET page passes even though .NET 3.5 is absent — its parser picks the *highest*
  NDP key (`v4\Full` = 4.8.1). This is exactly the mismatch the code review found: the installer is
  happy, while the runtime gate `NETFramework35` (which reads `NDP\v3.5\Install`) returns **False**,
  silently disabling the desktop host and the link launcher. Phase 7 demonstrates the consequence.

## 3b. Phase 1b — install the rebuilt Windows 11 installer

`SharpE-0.8-RC3-win11-Setup.exe` is the patched script's output: same file layout as the 2011 RC3,
but the packaging fixes and the managed rebuild are inside it. Host-side facts (no VM needed):

- 2551 payload entries; the archive contains **every** file the script names, at the right paths,
  and nothing else (`$PLUGINSDIR` + `uninstall.exe` aside). The only source-tree files left out are
  the 4 `.pdb`s and `Explorer.exe.config`, which upstream's `File` list never installed either.
- `Addons\x64\` ships our net481 rebuild: `Explorer.exe` (with the Win10 `supportedOS` GUID),
  `SharpEnviro.dll`, `SharpSearch.dll`, `SharpSearch.WPF.dll`, `System.Data.SQLite.dll` (2023 build,
  P/Invokes `SQLite.Interop.dll`). The 2011 native `Explorer.dll` is untouched.
- **New:** `Addons\x64\x64\SQLite.Interop.dll` + `Addons\x64\x86\SQLite.Interop.dll` — the
  sub-directories the 1.0.118 `System.Data.SQLite.dll` probes. The 2011 installer shipped none
  (its SQLite was fully managed), so a rebuild without these two files would fail to load SQLite.
- No `dotNetFx35setup.exe` in `$PLUGINSDIR` (the stock installer carried it) — the page is now the
  4.8 registry probe (`NDP\v4\Full\Release >= 528040`, 32-bit view first, 64-bit fallback).
  Replayed against the host registry: Release 533509 → the page passes.
- Compiled clean with NSIS 3.11 **and** NSIS 2.46 (the 2011 toolchain). Use the 3.11 build: its stub
  itself declares `supportedOS` + `highestAvailable` and is DPI-aware; the 2.46 stub does neither.
- The Delphi EXEs inside are still the stock 2011 binaries → **phase 2 patching is still required.**

Do this instead of phase 1 (or both, for an A/B):

1. Install **as administrator**, pick *do it manually later* on the shell page, no reboot.
2. `collect-evidence.ps1 -Tag installed-win11`.
3. Confirm on disk: `Addons\x64\System.Data.SQLite.dll` = 431 792 bytes (not 1 102 336),
   `Addons\x64\x64\SQLite.Interop.dll` exists, `Addons\x64\Explorer.exe` = 19 456 bytes.
4. Optional second pass to exercise the fixed shell-write error path: run the installer **without**
   elevation. The `HKLM ...\IniFileMapping\system.ini\boot\Shell` write must fail → the message
   *"Setup was unable to write the shell redirect to the registry…"* appears, no reboot is offered,
   and Explorer stays the shell. That is safe to expect because the per-user
   `HKCU\...\Winlogon\Shell` value the installer writes first has no effect while the machine mapping
   is still the stock `SYS:Microsoft\Windows NT\CurrentVersion\Winlogon` (verified on this host).

---

## 4. Phase 2 — inject the Windows 11 manifests into the installed EXEs

Stop SharpE if it is running, then:

```powershell
powershell -ExecutionPolicy Bypass -File ...\patch-manifests.ps1 -WhatIf   # dry run
powershell -ExecutionPolicy Bypass -File ...\patch-manifests.ps1
```

Mechanism — offline, and exercised on the host against these exact 0.8 RC3 binaries:

- **primary:** the documented Win32 resource API (`BeginUpdateResource`/`UpdateResource`) — no SDK
  needed in the VM;
- **fallback:** `mt\mt.exe` (shipped with its `MidlrtMd.dll`) for binaries `BeginUpdateResource`
  mangles — observed on `SharpSplash.exe`, where it corrupts the PE header (`bad e_lfanew`); mt.exe
  patches that one cleanly and the result still maps as an image. Host result: 9 of 10 files via the
  resource API, `SharpSplash.exe` via mt.exe, **10/10 verified**.
- every file is backed up to `<install>\_manifest-backup\` before it is touched (`-Restore` reverts);
  after patching the script re-checks that the PE still maps as an image, the resource tree is intact,
  there is **exactly one** `RT_MANIFEST` carrying `supportedOS` + an execution level, and the icon and
  version resources survived. A file that fails verification is restored immediately and reported.
- note: the 2011 binaries already embed an 850-byte manifest (comctl32 v6, **no** `supportedOS`) — that
  is what gets replaced; `SharpAdmin.exe` keeps its `requireAdministrator` level (680 → 1842 bytes), and
  `SharpConsole.exe`'s 752-byte one becomes ours.

## 5. Phase 3 — prove the manifest fix

The shipped release binaries cannot report their own version: the `Win32MajorVersion` line lives in
`DebugDialog.pas` and only the DEBUG build links it (`{$IFDEF DEBUG}` in `SharpConsole.dpr`; the string
`System   : %s %s, Version: %d.%d` is absent from `payload\SharpConsole.exe`). So verify two ways:

1. **Static, on the installed files** — read the embedded manifest back with `mt.exe`, which is
   independent of the patcher's own verification:

   ```powershell
   & C:\SharpE-vmtest\mt\mt.exe -inputresource:"$env:ProgramFiles\SharpEnviro\SharpConsole.exe";#1 -out:$env:TEMP\sc.manifest
   Select-String -Path $env:TEMP\sc.manifest -Pattern 'supportedOS|requestedExecutionLevel'
   ```
   Expect the Win10 GUID `{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}` and a requested execution level on
   every patched EXE (`SharpAdmin.exe` keeps `requireAdministrator`).

2. **Behavioural, inside the VM** — `GetVersionExW` is the API Windows shims and the one Delphi's
   `Win32MajorVersion` reads. Build two throwaway probes with the compiler that ships with Windows
   (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`): same source, one with no manifest, one
   with ours, then run both. Expect **unmanifested `6.2.9200`, manifested `10.0.26100`** — that is the
   whole point of the manifest change: on Windows 8.1+ an unmanifested process is told it runs on
   “Windows 8”, which is what the 2011 binaries saw before patching.
   (`Environment.OSVersion` prints the true build either way — .NET 4.6+ calls `RtlGetVersion`, which
   is not shimmed; the difference is visible only through `GetVersionExW`.)

## 6. Phase 4 — let SharpEnviro become the shell

Run `<install>\SetShell.exe` (or re-run the installer and choose to switch the shell), then reboot.

- If the VM comes up with **no desktop at all**, that is a result, not a disaster: recover with
  `recover-shell.cmd` and note the symptom.
- Collect evidence with `-Tag shell`. Look at: is `explorer.exe` running? how many top-level
  `Shell_TrayWnd` windows are there and which pid owns them? what does `GetShellWindow()` return?
  Any WER/Application-error entries for `SharpCore.exe`/`SharpBar.exe`?

## 7. Phase 5 — the architectural checks (this is why the VM exists)

| Check | How | If the earlier code review is right |
|---|---|---|
| Two shells | `start explorer.exe` while SharpE is the shell | The genuine Windows 11 shell (taskbar, Start, desktop) comes up next to SharpE |
| Tray ownership | Start an app with a notification icon (OneDrive/Teams, or any tray util) | The icon lands in the *real* Explorer tray (or the native tray goes silent) — never in SharpE's bar: both create a `Shell_TrayWnd`, and shell32 delivers to whichever the class lookup finds |
| Cloak-blind task list | Open Settings / Calculator / Store (UWP), then check SharpE's taskbar | Phantom task buttons for cloaked/UWP windows — the `DWMWA_CLOAKED` gap now fixed in source |
| Show Desktop | Click it | Nothing (the message goes to whichever `Shell_TrayWnd` `FindWindow` returned) |
| Work area | Maximise a window | It covers the SharpE bar — Explorer recalculates the work area on `WM_SETTINGCHANGE` (KB4014104) |
| UIPI | Run Notepad as administrator, then try to minimise/activate it from SharpE's taskbar | Refused (lower-integrity shell cannot drive a higher-integrity window) |
| DPI | Set display scaling to 150 % (and a second 100 % monitor) | SharpE UI is bitmap-stretched and its bar geometry drifts (DPI-unaware by design for now) |

## 8. Phase 6 — drop in the rebuilt managed components

```powershell
# back up first
Copy-Item "<install>\Addons\x64" "<install>\Addons\x64.orig" -Recurse
Copy-Item \\vmware-host\Shared Folders\SharpE-vmtest\managed-x64\* "<install>\Addons\x64\" -Force
```

- These are the **net481** rebuilds (manifest-injected, `supportedOS` + `asInvoker`) from the patched
  repo; the 2011 native `Explorer.dll` next to them is untouched and still used.
- Check `SharpLinkLauncherNET.exe` runs: with 0 args it exits `-1` (`InvalidNumberArguments`) and with
  `-l:<fake>.lnk -t:100 -e` it exits `-4` (`Timeout`) — no crash dialog (verified on the host).
- **ExplorerNET guard** (new code): while **Explorer** is the shell, run
  `"<install>\Addons\x64\Explorer.exe" C:\Windows` → it forwards to the real explorer and a window
  opens. While **SharpE** is the shell, the same command must *not* start a second shell — it logs
  “Ignoring shell arguments while SharpEnviro is the shell” and returns.

## 9. Phase 7 — isolate the .NET 3.5 gate

1. Enable 3.5: `DISM /Online /Enable-Feature /FeatureName:NetFx3 /All` (or *Settings → Optional features*).
2. Reboot with SharpE as the shell and watch Task Manager.
   - Expected: `NDP\v3.5\Install` = 1 → the Delphi gate returns True → `Addons\x64\Explorer.exe`
     (the desktop host) starts, whereas on a stock Win11 it never does.
3. Disable 3.5 again (`/Disable-Feature`) and confirm the host stops starting.

That is a direct demonstration of the defect the probe change fixes: on stock Windows 11 the gate was
False, which no amount of .NET 4.8 can paper over.

## 10. Phase 8 — wrap up

```powershell
...\recover-shell.cmd
powershell ...\collect-evidence.ps1 -Tag reverted
```
Compare `evidence-*-reverted-*.txt` with `-baseline-`: shell keys back to the Windows defaults, no
SharpE processes, no leftover `SetShell` autostart.

Bring the `evidence-*.txt` files (and anything interesting from `C:\SharpE-evidence` if you redirected
`-OutDir`) back to the host; defects get mapped to code from there.

---

## 11. Later, with a Delphi 2007+ build

Rebuild the Delphi projects (they now carry their own manifests, so no `mt.exe` step is needed),
rebuild the managed side with `dotnet build ... -p:Platform=x86|x64`, and re-run phases 3–7. The
`.pas` fixes that only a rebuild can exercise: the .NET 4.8 probe, `Win32MajorVersion >= 6` in
`uDeskArea`, `DWMWA_CLOAKED` filtering, `ABM_*EX`, `SetShellWindow`, and the hotkey retry/reporting.

### Rebuilding the installer on the host (how `SharpE-0.8-RC3-win11-Setup.exe` was produced)

The `.nsi` does not need Delphi — it consumes an output tree, not sources. Reproduce with:

1. Portable NSIS, no install needed: `nsis-3.11.zip` from
   `downloads.sourceforge.net/project/nsis/NSIS%203/3.11/` (2.46 also compiles it, from
   `.../NSIS%202/2.46/`; use 3.11 — `supportedOS` in the stub, DPI-aware). Already unpacked on this
   host at `E:\Git\.nsis-dl\{3.11\nsis-3.11,2.46\nsis-2.46}\`.
2. Build a tree that mirrors upstream's expected layout, `<stage>\{SharpEnviro,SharpE,SharpE_BuildTools}`:
   - `stage\SharpEnviro\{Installer,License,FDS,Graphics\Application Icons}` — repo copies; the two
     `.ico`s and the `FDS` binaries come from the repo, `License\gpl-3.0.txt` from `payload\`
     (the clone has no `License` directory);
   - `stage\SharpE\` = `payload\` minus `$PLUGINSDIR` and `uninstall.exe` (that IS the 2011 output
     tree), then overlay the rebuilt `Addons\x64\` **including its `x64\` and `x86\` subdirectories**;
   - `stage\SharpE_BuildTools\{SharpCompile.exe,7z.dll}` from `payload\` (upstream's `..\..\SharpE_BuildTools`).
3. `cd stage\SharpEnviro\Installer && <nsis>\makensis.exe /V3 SharpE-0.8-Setup.nsi`

Sanity check the result the same way: `7z l -slt` the `.exe` and compare the entry list against the
`File` directives in the script (should be exactly those entries, `$PLUGINSDIR` + `uninstall.exe` aside).
