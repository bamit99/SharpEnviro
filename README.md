# SharpEnviro — Windows 11 compatibility fork

SharpEnviro (SharpE) is a shell replacement system for Microsoft Windows: it
replaces `explorer.exe` as the desktop shell with its own desktop, taskbar, bar,
menu and plugins. The upstream project was written around 2011 (Delphi 2007 +
.NET 3.5) and has not been maintained since.

**This is a fork of [SrcForger/SharpEnviro](https://github.com/SrcForger/SharpEnviro)**
whose purpose is to make that shell usable on Windows 11 (build 22000+).
All original code is by the SharpEnviro Development Team — see
[Credits](#credits). This fork adds only the compatibility work described below.

> **Status: preview.** Tested end-to-end in a Windows 11 VM (25H2, build 26200) —
> the shell takeover works and the known defects are now measured rather than
> predicted. Read [Windows 11 status](#windows-11-status) before installing.

---

## Windows 11 status

The 2011 binaries fail on Windows 11 for two independent reasons, both addressed
here.

### 1. Missing `supportedOS` manifest (fixed, verified)

The shipped executables embed a manifest with comctl32 v6 but **no `supportedOS`
GUID**. On Windows 8.1+ an unmanifested process is shimmed by the OS and reports
itself as "Windows 8" — `GetVersionExW` returns `6.2.9200`. SharpE's Delphi code
reads `Win32MajorVersion` for OS checks, so on Windows 11 it saw major version
**6** and took its Windows 8 code paths.

`patch-manifests.ps1` injects a manifest declaring the Windows 10/11 GUID
(`{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}`) into the installed executables.
Measured on Windows 11 25H2 (build 26200):

| Build | `GetVersionExW` | Delphi `Win32MajorVersion` |
| --- | --- | --- |
| unmanifested (2011 EXEs) | `6.2.9200` | **6** |
| manifested (this fix) | `10.0.26200` | **10** |

All 10 installable executables patch cleanly (9 via the Win32 resource API;
`SharpSplash.exe` via `mt.exe`, because the resource API corrupts its PE header).
`SharpAdmin.exe` retains its `requireAdministrator` execution level.

### 2. .NET 3.5 gate (identified, fix unverified on a rebuilt binary)

The installer and runtime probe `NDP\v3.5\Install`. Windows 11 does not ship
.NET 3.5, so that gate returns false and silently disables the desktop host and
link launcher. The managed components are retargeted to **.NET Framework 4.8**
(`net481`) and the installer now probes 4.8 instead of 3.5. Exercising this on a
rebuilt Delphi binary still requires a Delphi 2007+ toolchain.

### What is verified

Verified in a Windows 11 VM (25H2 / build 26200), phases 0-8 of `test/win11/TESTPLAN.md`:

- **shell takeover works** — at logon `SharpCore`/`SharpBar`/`SharpDesk` start and the
  whole Windows 11 shell stack does not; SharpE owns a `Shell_TrayWnd`
- **recovery works** — `recover-shell.cmd` restores Explorer as the shell
- manifest injection: 10/10 executables, `supportedOS` present, execution levels preserved
- the `GetVersionExW` before/after shown above
- the .NET 4.8 managed components load and run: `System.Data.SQLite.dll` 1.0.118
  (431,792 bytes) with its `x64\SQLite.Interop.dll`; desktop host `Explorer.exe` 19,456 bytes
- `SharpLinkLauncherNET.exe` argument handling (exit `-1` with no arguments, `-4` on timeout)
- the `ExplorerNET` argument guard works both ways: forwards to the real shell while
  Explorer is the shell, and refuses to start a second shell while SharpE is
- the `.NET 3.5` gate is demonstrably false on stock Windows 11: the .NET 4.8 desktop
  host is present and correct on disk and still never starts

### Known issues

- **`ExplorerNET`'s shell guard is session-dependent.** `ExplorerIsTheShell()`
  calls `GetShellWindow()`, which is per-session; from a non-interactive context
  (e.g. a service or session 0) it returns `NULL` and the guard wrongly concludes
  SharpEnviro is the shell, swallowing shell arguments. The addon is normally
  launched from the interactive desktop, so real-world impact is low.
- **SharpE never claims the shell window.** `GetShellWindow()` returns `NULL`
  while SharpE owns a `Shell_TrayWnd`, because `SetShellWindow` is never called.
  shell32 therefore cannot find it, which is why tray and "show desktop"
  hand-offs land in the wrong process.
- **Starting `explorer.exe` brings back the whole Windows 11 shell**, and Explorer
  then takes the shell window from SharpE (two `Shell_TrayWnd` windows compete).
  SharpE's takeover is not exclusive.
- **The bar reserves no work area.** SharpE registers no AppBar, so the work area
  keeps a stale margin and maximised windows cover the bar.
- **Elevated windows cannot be driven** (UIPI): a medium-integrity bar cannot
  minimise or activate a high-integrity window, so those task buttons are inert.
- DPI awareness is still the 2011 behaviour; SharpE is not per-monitor DPI aware.

---

## Requirements

| | |
| --- | --- |
| OS | Windows 10 / 11, x64 (x86 supported by the build, not tested here) |
| Runtime | .NET Framework 4.8 (ships with Windows 10 1903+ and Windows 11) |
| Install | Administrator rights (writes `HKLM`) |
| Build (managed) | .NET SDK — `dotnet build` |
| Build (native) | Delphi 2007 or compatible (Delphi 10.x/11 + the `dproj` files) — **not required** to use the release |

---

## Install

> **Before you start:** changing the shell is invasive. If something goes wrong
> you can be left with no desktop. Take a VM snapshot or a system restore point
> first, and know how to recover: `Ctrl+Alt+Del` → Task Manager →
> *File → Run new task* → `cmd` → run `recover-shell.cmd`.

### Option A — full installer

1. Download `SharpE-0.8-RC3-win11-Setup.exe` from
   [Releases](https://github.com/bamit99/SharpEnviro/releases).
2. Run it **as administrator**.
3. On the *"Change Windows Default Shell"* page, pick **change the shell manually
   later** (the lower option). The upper option rewrites the shell registration
   immediately and offers a reboot.
4. Collect baseline evidence — the installer lands in
   `C:\Program Files (x86)\SharpEnviro` because it is a 32-bit NSIS program.
5. Inject the Windows 11 manifests (required — see above):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\patch-manifests.ps1
   ```
6. Make SharpE the shell with `<install>\SetShell.exe`, then reboot.

### Option B — managed components only

If you already have SharpEnviro 0.8 RC3 installed, drop the rebuilt .NET
components over the existing ones:

```powershell
# back up first
Copy-Item "<install>\Addons\x64" "<install>\Addons\x64.orig" -Recurse
Copy-Item <unzipped>\* "<install>\Addons\x64\" -Force
```

This replaces the .NET 3.5 assemblies with the .NET 4.8 rebuild. The 2011 native
`Explorer.dll` next to them is untouched and still used.

### Recovering the shell

If you end up with no desktop: `Ctrl+Alt+Del` → Task Manager → *File → Run new
task* (tick *administrative privileges*) → `cmd`, then

```
recover-shell.cmd
```

It restores the shell registration, stops SharpE processes and starts Explorer.
Log off and back on if the desktop does not return immediately.

---

## Build

### Managed components (.NET 4.8) — builds anywhere

Seven SDK-style projects targeting `net481`, no Visual Studio required:

```
Common/Libraries/SharpEnviro          Common/Libraries/SharpSearch
Common/Libraries/SharpSearch.WPF      Components/ExplorerNET
Components/SharpLinkLauncherNET       Components/SharpSearchNET
Components/SharpShellServicesNET
```

```sh
dotnet build <project>.csproj -c Release -p:Platform=x64   # -> Addons\x64
dotnet build <project>.csproj -c Release -p:Platform=x86   # -> Addons\x86
```

`Microsoft.NETFramework.ReferenceAssemblies` is referenced so the build does not
need a Visual Studio targeting pack. Output goes to the sibling `<repo-parent>\SharpE\`
tree (`OutputPath` in each `.csproj`), matching the installer's expected layout.

CI builds both architectures on every push — see
`.github/workflows/build-managed.yml`, and grab the artifacts from the run or the
[Releases](https://github.com/bamit99/SharpEnviro/releases) page.

### Native / Delphi — needs the 2011 toolchain

The shell, plugins and bar are Delphi. `Project Groups/*.groupproj` holds the
project groups and `build2.bat` drives a full build; both expect a Delphi 2007-era
compiler and the `rtl100`/`vcl100` runtime packages. Without that toolchain these
binaries cannot be rebuilt, and the `.pas`/`.dpr` fixes in this fork are therefore
present in source but not compiled into a release binary.

---

## Repository layout

| Path | Contents |
| --- | --- |
| `Common/` | shared libraries, units, third-party components |
| `Components/` | shell components — C# (`ExplorerNET`, `SharpLinkLauncherNET`, …) and Delphi |
| `Plugins/` | modules, services, objects, configurations, themes |
| `Installer/` | NSIS installer script (`SharpE-0.8-Setup.nsi`) |
| `Documentation/` | SDK and skin documentation |
| `Tools/` | build and conversion utilities |

Branches in this fork:

| Branch | Purpose |
| --- | --- |
| `master` | unmodified mirror of upstream — kept clean so `git pull upstream master` stays conflict-free |
| `win11-compat` | the Windows 11 compatibility work; releases are cut from here |
| `win11-vmtest` | VM test harness and the round-1 test plan (`test/win11/`), based on `win11-compat` |

---

## Credits

SharpEnviro was written by the **SharpEnviro Development Team** and published on
SourceForge; upstream on GitHub is
[SrcForger/SharpEnviro](https://github.com/SrcForger/SharpEnviro), whose history
begins from the last SourceForge commit of around August 2011. Copyright in the
original work remains with its authors.

This fork adds Windows 11 compatibility work only. Changes are limited to build
targets, manifests, the .NET probe, and specific shell-behaviour fixes — see the
commit history on `win11-compat`.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE). As with the original,
any redistributed build must remain under the GPL and make its source available.
