# Windows 11 compatibility test harness

Scripts and the procedure used to validate the `win11-compat` branch against a
real Windows 11 guest. Everything here is text; the large binary inputs are
**not** committed and are listed under [Required inputs](#required-inputs).

The plan itself is [`TESTPLAN.md`](./TESTPLAN.md) — phases 0–8, each with the
evidence to collect and the expected result. Read that first.

## Why a VM

`SharpEnviro` replaces the Windows shell. A failure leaves the machine with no
desktop, so every phase runs in a snapshotted VM and every phase has a recovery
path ([`recover-shell.cmd`](./recover-shell.cmd) +
[`restore-explorer.reg`](./restore-explorer.reg)).

## Layout

| File | Purpose |
|---|---|
| `TESTPLAN.md` | The full round-1 procedure and what each phase proves |
| `collect-evidence.ps1` | Read-only collector: OS, shell registry, .NET, processes, window classes + cloaked flags, embedded manifests, event log |
| `patch-manifests.ps1` | Injects Windows 11 manifests into installed EXEs (self-verifying, auto-rollback, `-WhatIf`/`-Restore`) |
| `manifests/` | The per-EXE manifest sources used by `patch-manifests.ps1` |
| `recover-shell.cmd` | Emergency recovery: restores Explorer as the shell, kills SharpE processes |
| `restore-explorer.reg` | Stock Windows 11 shell registration, verified against build 26200 |
| `evidence-EXAMPLE-host-win11-25H2.txt` | Reference collector output (host, Win11 25H2, 150 % scaling) — compare VM reports against it |

## Required inputs

Not committed — place them beside the scripts before running:

| Input | Size | Where it comes from |
|---|---|---|
| `SharpE-0.8-RC3-Setup.exe` | 33.8 MB | 2011 release, SourceForge — `sha256 e0f99ed370210f184d1a591976a6e35bd4802026049053eb5d9f14838c0a144f` |
| `SharpE-0.8-RC3-win11-Setup.exe` | 32.3 MB | Rebuild of this branch's script, NSIS 3.11 — `sha256 c62b82df7a5d268b81a5d99644556917567ff4082d1f5316e796be5b411fe251` |
| `payload/` | 151 MB | The 2011 installer's files extracted with 7z (lets phases 1b/2/6/7 run without the installer's .NET page) |
| `managed-x64/` | 1.7 MB | This branch's net481 rebuild, drop-in for `<install>\Addons\x64\` |
| `mt/` | 2.3 MB | `mt.exe` + `MidlrtMd.dll`, the fallback manifest patcher |

Rebuilding the installer from this branch is documented in
`TESTPLAN.md` § *Rebuilding the installer on the host*.

## Running

Inside the VM, with this folder shared in (`SharpE-vmtest`):

```powershell
# phase 0 / each phase boundary
powershell -ExecutionPolicy Bypass -File \\vmware-host\Shared Folders\SharpE-vmtest\collect-evidence.ps1 -Tag baseline
```

Snapshot before every phase (`TESTPLAN.md` § 0).

## Automating from the host

`vmrun` can drive a Windows guest without RDP:

```powershell
$vm  = 'D:\VMWare\Windows 11 x64.vmx'
$vmrun = "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe"

& $vmrun -T ws -gu <user> -gp <pass> snapshot $vm "phase-0-baseline"
& $vmrun -T ws -gu <user> -gp <pass> runProgramInGuest $vm `
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    '-ExecutionPolicy Bypass -File \\vmware-host\Shared Folders\SharpE-vmtest\collect-evidence.ps1 -Tag baseline'
```

Notes learned wiring this up on the test host:

- The VM is **encrypted**; `vmrun` will not open it without the guest credentials
  *and* the VM passphrase.
- `vmrun --T ws` with a path containing spaces needs PowerShell quoting, not
  bash — `cmd //c` silently swallows the argument and opens an interactive shell.
- A snapshot must exist before phase 4 (making SharpEnviro the shell) or a
  black-screen boot has no rollback.
