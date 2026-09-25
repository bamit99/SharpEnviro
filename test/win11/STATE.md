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

### Open risk — re-validate the patch *in the VM*

An **earlier revision** of the patcher failed **10/10 in the VM** with
`manifest language count = 0x0000,0x0000,…` garbage (session log
`117`, `138`, `221` under `~/.omp/agent/sessions/--E--Git--/`), while the
**current** revision patched **10/10 on the host** (9 via the resource API,
`SharpSplash.exe` via the `mt.exe` fallback) and passed an independent `mt.exe`
readback. Host success is **not** VM success. Phase 3 in the VM is the real test.

## Next steps

1. In the VM, elevated: `powershell -ExecutionPolicy Bypass -File Z:\run-phase3.ps1`
   (reverts shell → patches → verifies).
2. Snapshot the clean desktop as `phase-0-baseline`.
3. Phase 4: `SetShell.exe`, reboot — only once the snapshot exists.
