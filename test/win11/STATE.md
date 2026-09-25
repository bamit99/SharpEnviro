# Win11 test rig — state and access facts

Operational notes for the `win11-compat` validation run. Keeps the environment
details that cost time to rediscover out of the chat transcript.

## The VM

| | |
|---|---|
| Definition | `D:\VMWare\Windows 11 x64.vmx` |
| Guest OS | Windows 10 Enterprise, 25H2, build 26200.9457 (Win11 kernel) |
| NetBIOS / workgroup | `SHARPENVIRO` / `WORKGROUP` |
| Guest account | `sharpenviro\amitb` |
| Guest IP | `192.168.34.129` (VMnet1, MAC `00-0c-29-f2-3d-c2`) |
| CPU / RAM | 4 vCPU / 16 GB |
| **Encrypted** | yes — `vmx.encryptionType = partial` |

### Getting in

- **WinRM** (`5985`) is open and `Test-WSMan` answers unauthenticated, but
  `Invoke-Command` returns **`Access is denied`** for every local admin form
  (`amitb`, `.\amitb`, `SHARPENVIRO\amitb`). Standard workgroup cause: remote UAC
  strips the admin token. Fix inside the VM, elevated:
  ```powershell
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
  Restart-Service WinRM
  ```
  Also: the host client is `AllowUnencrypted=true` + `TrustedHosts=*`, but the VM
  rejected **Basic** ("mechanism not supported"), so use **Negotiate** (default).
- **`vmrun`** cannot open the VM without `-vp <passphrase>` — it does *not* read
  the cached credential the GUI uses. Confirmed: no flag → *"A password is
  required"*, dummy flag → *"Incorrect password"*. The passphrase is **not**
  recoverable from the `.vmx` (`encryption.keySafe` is the wrapped derived key;
  `encryptedVM.guid` is just an identifier). It **is** cached by the GUI in
  Windows Credential Manager as `LegacyGeneric:target=VMware Encrypted VM: D:\VMWare\Windows 11 x64.vmx`.
- **Shared folder** (works, no credentials needed): guest **`Z:`** (share name
  `Evidence`) → host `E:\Git\SharpEnviro-vmtestwt\Evidence`. Both read and write.

## Repo layout

| Path | Role |
|---|---|
| `E:\Git\SharpEnviro` | working repo — `origin` = `bamit99/SharpEnviro` (fork, ADMIN), `upstream` = `SrcForger/SharpEnviro` |
| branch `win11-compat` | the 4 Win11 fixes |
| branch `win11-vmtest` | this harness, based on `win11-compat` |
| `E:\Git\SharpEnviro-vmtestwt` | worktree for `win11-vmtest` (shared folder target lives at its `Evidence\`) |

`SrcForger/SharpEnviro` is read-only to this account — pushes go to the fork.

## Current VM state (2026-09-25)

**SharpE is already installed** at `C:\Program Files (x86)\SharpEnviro` **and is
already the per-user shell** — `HKCU\...\Winlogon\Shell` =
`...\SharpCore.exe -startup`, with `SharpCore`, `SharpBar` ×2 and `SharpDesk`
running and Win11's own shell stack (`ShellExperienceHost`,
`StartMenuExperienceHost`, `SearchHost`) not running.

So the machine is **mid-takeover, not a clean baseline**:

- `HKLM\...\IniFileMapping\system.ini\boot\Shell` is still stock
  (`SYS:Microsoft\Windows NT\CurrentVersion\Winlogon`) — the real shell gate — so
  the `HKCU` value the installer writes is inert.
- `GetShellWindow()` returns **NULL**: neither Explorer (no `Progman`) nor SharpE
  (no `SetShellWindow`) owns the shell window.

This confirms TESTPLAN §3b's claim about the per-user write, but it means
`recover-shell.cmd` must run **before** any snapshot intended as the phase-0
baseline.

## Why the patcher "failed" in the VM

`patch-manifests.ps1` has an `Assert-NotRunning` guard and **throws** when any of
`SharpCore/SharpBar/SharpDesk/SharpMenu/SharpCenter/SharpConsole/SetShell/SharpSplash/SharpSkin`
is live — patching a mapped EXE is impossible. The three `evidence-*.txt` collected
while SharpE was running are therefore identical apart from window-title and
working-set noise: the collector ran, the patcher never did.

Use **`run-phase3.ps1`** (in this folder), which reverts the shell first, verifies
quiescence, then patches with `-Force`.

### Access: working (2026-09-25)

WinRM works with the **`ompadmin`** account — not `amitb`:

```powershell
$c = New-Object System.Management.Automation.PSCredential(
       'SHARPENVIRO\ompadmin', (ConvertTo-SecureString 'Password1!' -AsPlainText -Force))
Invoke-Command -ComputerName 192.168.34.129 -Credential $c -ScriptBlock { whoami }
# -> sharpenviro\ompadmin, full admin token, 64-bit PowerShell
```

`sharpenviro\amitb` (the account SharpE runs as) is denied over WinRM. Use
`ompadmin`, which is also how you can stop a SharpE process owned by `amitb`.

**Execution policy is `Restricted` on the VM.** `-ExecutionPolicy Bypass` on the
*host* shell does not carry over. Set it inside the remote session first:

```powershell
Invoke-Command ... -ScriptBlock {
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  & '\\vmware-host\Shared Folders\Evidence\patch-manifests.ps1' ...
}
```

## Phase 3 — DONE and verified in the VM (2026-09-25 16:15)

The earlier VM failure (`manifest language count = 0x0000,…`) is **gone** with the
current patcher. Results in `Evidence/phase3-results.txt`:

- **`patched 10, skipped 2, failed 0`** — `SharpSkin.exe`/`SharpScript.exe` not
  installed; `SharpSplash.exe` via the `mt.exe` fallback after the resource API
  broke its PE (`bad e_lfanew`).
- `supportedOS=True` on every patched EXE; independent `mt.exe` readback shows the
  Win10 GUID on all, with `SharpAdmin.exe` still `requireAdministrator` and the
  rest `asInvoker`.
- **Behavioural proof of the manifest fix** (the phase-3 point), via a
  `GetVersionExW` probe built with the in-box `csc`:

  | Build | `GetVersionExW` | Delphi `Win32MajorVersion` |
  |---|---|---|
  | unmanifested (the 2011 EXEs) | `6.2.9200` | **6** — "Windows 8" |
  | manifested (this fix) | `10.0.26200` | **10** — real build |

  `OSVERSIONINFOEXW` must be the full 284-byte shape or `GetVersionExW` fails
  outright rather than reporting a shimmed version.

Also done: install dir backed up to `C:\SharpEnviro-backup-20260925-161425`
(2552 files, 144.2 MB, verified), and pre-change registry captured to
`Evidence/reg-before-20260925-161425.txt`.

## Shell reverted (2026-09-25 16:14)

The machine was mid-takeover; it is now back to a stock shell:

- `IniFileMapping\system.ini\boot\Shell` = `SYS:Microsoft\...\Winlogon` (was `USR:`)
- `HKLM\...\Winlogon\Shell` = `explorer.exe`
- `amitb`'s `HKCU\...\Winlogon\Shell` removed (was `...\SharpCore.exe -startup`)

Note the **64-bit vs 32-bit registry view**: the 64-bit view held the `USR:` redirect
while the 32-bit view (and `WOW6432Node`) still read `SYS:`. That is why a 32-bit
collector on the same machine reported the stock value. Check `/reg:64` explicitly.

SharpE processes were stopped for the patch and have **not** been restarted, so the
next logon should come up as a plain Windows 11 desktop.

## Phase 6 part 1 — done, on the Explorer desktop (2026-09-25 16:34)

Ran *before* phase 4 on purpose: one half of the guard test needs Explorer to be
the shell, which is gone once SharpE takes over.

Managed components dropped into `Addons\x64\` (backed up to `Addons\x64.orig`,
8 files). All TESTPLAN §3b.3 disk assertions hold:

| Check | Value |
| --- | --- |
| `System.Data.SQLite.dll` | **431,792** (not 1,102,336) |
| `Addons\x64\x64\SQLite.Interop.dll` | present |
| `Addons\x64\Explorer.exe` | **19,456** |
| native 2011 `Explorer.dll` | untouched (517,120) |
| `SharpLinkLauncherNET.exe` no args | exit **-1** (`InvalidNumberArguments`) |
| `SharpLinkLauncherNET.exe -l:fake.lnk -t:100 -e` | exit **-4** (`Timeout`) |

### Guard test (`Explorer.exe C:\Windows`) — PASS

`Components/ExplorerNET/Program.cs` forwards args to the real explorer only when
`ExplorerIsTheShell()`. Measured in the interactive session:

```
GetShellWindow() = 0x100FA class=Progman
before: explorer pids = [5940]           visible CabinetWClass = 0
after : explorer pids = [5940, 8840]     visible CabinetWClass = 1
verdict: a File Explorer window APPEARED -> guard forwarded to the real shell
```

### Confirmed defect: the guard is session-dependent

`ExplorerIsTheShell()` calls `GetShellWindow()`, which is **per-session**:

```
session 0 (WinRM):  GetShellWindow() = NULL    -> ExplorerIsTheShell() = False
session 1 (interactive): class=Progman         -> ExplorerIsTheShell() = True
```

So when `Explorer.exe` with args is launched from a non-interactive context, the
guard concludes *"SharpEnviro is the shell"* even when Explorer is, logs
`Ignoring shell arguments while SharpEnviro is the shell`, and **swallows the
arguments**. Impact is low (the addon is normally started from the interactive
desktop), but it is wrong, and it is the same per-session trap that produced the
false "no shell" reading earlier. A `Progman` lookup in the *logged-on* session
(or an explicit session check) would be correct.

## Phase 4 — SharpE becomes the shell: WORKS (2026-09-25 16:51)

Reboot confirmed by boot-time change (16:30:54 → **16:51:22**). Registry writes
applied exactly as `uShellSwitcher.pas` does them:

```
amitb HKCU\...\Winlogon\Shell                = C:\Program Files (x86)\SharpEnviro\SharpCore.exe -startup
HKLM\...\IniFileMapping\system.ini\boot\Shell = USR:Software\...\Winlogon     (64-bit view only)
```

At logon: `SharpCore` (5468), `SharpBar` ×2, `SharpDesk` all start **in session 1**;
`explorer.exe` and the whole Win11 shell stack (`ShellExperienceHost`,
`StartMenuExperienceHost`, `SearchHost`) do **not**. SharpE owns a `Shell_TrayWnd`.
The takeover works.

Note `SetShell.exe` was not driven directly — it is a GUI app ending in a
"Reboot now?" MessageBox. The writes above are the same ones its `rbSharpE` radio
performs; the optional `DesktopProcess=1` tweak was deliberately not applied.

## Phase 5 — architectural checks: the documented defects are REAL

Baseline (`phase5-explorer-shell.txt`) vs SharpE shell (`phase5-no-shell.txt`):

| | Explorer shell | SharpE shell |
| --- | --- | --- |
| `GetShellWindow()` | `Progman` (explorer) | **NULL** |
| `Shell_TrayWnd` owner | `explorer(5940)` | **`SharpCore(5468)`** |
| `Progman` | present | **absent** |
| `explorer.exe` | running | **not running** |
| Win11 shell stack | running | **all dead** |
| work area | `0,0,2138,711` (48px taskbar) | **`0,29,2138,730` (29px)** |

### CONFIRMED 1: SharpE never claims the shell window

`GetShellWindow()` returns **NULL** while SharpE is the shell. SharpE owns a
`Shell_TrayWnd` but never calls `SetShellWindow`, so shell32 cannot find it —
`FindWindow("Shell_TrayWnd")` still resolves, which is exactly why the "Show
Desktop" and tray hand-offs land in the wrong process.

### CONFIRMED 2: two shells, and Explorer wins

Launching `explorer.exe` while SharpE is the shell (`phase5-architectural.txt`)
brings up the **full genuine Windows 11 shell** — `Progman`, the real taskbar,
Start, Search all come back — and **Explorer takes over the shell window**:

```
before: GetShellWindow() = NULL            Shell_TrayWnd owner = SharpCore(5468)
after : GetShellWindow() = Progman(explorer 5924)   Shell_TrayWnd owner = explorer(5924)
        work area = 0,0,2138,711   Shell_TrayWnd windows = 2   ("two shells competing")
```

The desktop, taskbar, Start and Search return, so the takeover is not exclusive.
Killing explorer afterwards leaves `SearchHost` and `StartMenuExperienceHost`
orphaned in session 1.

### CONFIRMED 3: bar does not reserve its work area

While SharpE is the shell the work area is `T29 / 701px` — a *stale* margin, not
`SharpBar`'s height. SharpE registers no AppBar, so maximised windows cover the
bar. When Explorer returns the work area becomes the genuine 48px taskbar.

### REPRODUCED 4: cloak-blind task buttons

`phase5-no-shell.txt` shows four **visible-but-cloaked** (`DWMWA_CLOAKED`=2)
windows live on this machine:

```
CalculatorApp(8036) 'Calculator'        ApplicationFrameWindow(7852) 'Calculator'
SearchHost(3060)    'Search'            StartMenuExperienceHost(792) 'Start'
```

A cloak-blind taskbar renders all four as phantom buttons. This is the set commit
`7726c00` filters.

## Phase 6 second half — PASS (2026-09-25 16:57)

While SharpE **is** the shell, `Addons\x64\Explorer.exe C:\Windows` starts **no**
second shell: no `explorer.exe` process, no `CabinetWClass` window, `Shell_TrayWnd`
unchanged. Arguments are ignored as designed.

So both halves of the guard work in the session it actually runs in:
forwarding while Explorer is the shell, and refusing while SharpE is.

## Phase 7 — the .NET 3.5 gate is FALSE and the host never starts (16:58)

```
NDP\v3.5\Install [64-bit] = ABSENT          NetFx3 feature = DisabledWithPayloadRemoved
NDP\v3.5\Install [32-bit] = ABSENT
NDP\v4\Full\Release       = 0x82405 (533509, >= 4.8)
-> Delphi NETFramework35 gate returns FALSE (host disabled)

Addons\x64\Explorer.exe   exists, 19,456 bytes (this fork's rebuild)  ... but <not running>
SharpLinkLauncherNET / SharpShellServicesNET / SharpSearchNET          <not running>
```

This is the defect the probe change fixes, demonstrated directly: the .NET 4.8
desktop host is present and correctly built, and **never starts**, because the
Delphi gate reads `NDP\v3.5\Install`, which stock Windows 11 does not have.

The plan's enable/disable cycle (enable NetFx3 → host starts → disable → stops) was
not run: `NetFx3` is `DisabledWithPayloadRemoved`, so enabling it needs an install
source. The gate's *decision* on this machine is proven regardless.

## Next steps

1. Phase 5 remainder: UIPI (admin Notepad vs bar) and DPI at 150 %.
2. Optional: enable `NetFx3` (needs a payload source) to watch the host start.
3. Restore: `recover-shell.cmd`, then a `-reverted` evidence pass.

## Phase 0 baseline — CONFIRMED clean (2026-09-25 16:25, after reboot)

Verified from **inside session 1** (`Evidence/session1-shell.txt`):

```
GetShellWindow() = 0x10110   class = Progman   "Program Manager"
Shell_TrayWnd    visible=True        WorkerW  visible=False
verdict: EXPLORER is the shell - clean Windows 11 desktop (phase 0 baseline)
```

- no SharpE processes or windows; no autostart entry that would relaunch it
- shell registration stock in **both** registry views (`SYS:` / `explorer.exe`),
  `amitb`'s `HKCU Shell` absent
- the manifest patch **survived the reboot** (10 EXEs carry `supportedOS`)
- back-ups intact: `C:\SharpEnviro-backup-20260925-161425`, `_manifest-backup\`

### Methodology gotcha: `GetShellWindow()` is per-session

**Do not trust `GetShellWindow()` collected over WinRM.** WinRM runs in
**session 0** (services); the interactive desktop is **session 1**. The call is
per-session and returns **NULL from session 0 every time** — it says nothing about
whether a shell exists. This produced a false "no shell" reading until the check
was run in-session.

```powershell
qwinsta            # console = session 1 (amitb, Active); WinRM caller = session 0
```

To check the shell remotely, run a check **in the interactive session** via an
`Interactive`-logon scheduled task — `Evidence/session1-shell-check.ps1` +
the runner used here:

```powershell
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-File <share>\session1-shell-check.ps1"
$principal = New-ScheduledTaskPrincipal -UserId 'SHARPENVIRO\amitb' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'SharpE-Session1Check' -Action $action -Principal $principal -Force
Start-ScheduledTask -TaskName 'SharpE-Session1Check'
```

`collect-evidence.ps1` is fine when run **interactively in the VM** (as the plan
says); its `GetShellWindow()` line is only misleading when the script is driven
over WinRM.
