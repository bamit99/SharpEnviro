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

## Next steps

1. **Snapshot as `phase-0-baseline`** — still the outstanding prerequisite; the
   black-screen risk of phase 4 has no rollback without it.
2. Phase 4: `<install>\SetShell.exe`, reboot.
3. Phases 5–7 (architectural checks, rebuilt managed components, .NET 3.5 gate).
