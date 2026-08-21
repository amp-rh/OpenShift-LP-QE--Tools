# vm/ — test VM environment (Linux/KVM host)

The BSOD test guest and its management tooling. One golden VM plus a clean
snapshot; revert after each crash rather than maintaining multiple VMs.

## Model

- **`bsod-test`** — the single golden Windows Server 2025 guest (Q35 + UEFI,
  virtio disk/net, TPM 2.0, isa-serial pty for kernel debugging, qemu guest
  agent). Defined by [`bsod-test.domain.xml`](bsod-test.domain.xml).
- **`clean-baseline`** — snapshot to revert to before/after each test.

Test loop: `revert -> trigger BSOD (guest) -> collect (guest + host) -> revert`.

## Files

- `bsod-test.domain.xml` — exported libvirt domain definition (reproducible).
- `vmctl.sh` — wrapper around `virsh` for define/snapshot/revert/start/stop/etc.
- `guest-ssh.sh` — run PowerShell in the guest over SSH (auto-resolves the guest
  IP from libvirt, prefers SSH key auth, base64/UTF-16 for short commands,
  auto-scp for long scripts, drops fast if the guest crashes mid-command).
- `prep-guest.ps1` — one-time guest prep: kernel-dump CrashControl, system-managed
  page file, and CrashMe driver installation.
- `install-ssh-key.ps1` — install an SSH public key into the guest's
  `administrators_authorized_keys` (with the correct restrictive ACL).
- `run-dry-run.sh` — one-command end-to-end test loop:
  revert -> start -> trigger BSOD -> wait for reboot -> collect -> pull artifacts.
- `sweep-crashme.sh` — automated verification sweep of all KeBugCheckEx-triggered
  bug-check codes (19 codes). Reverts to the `crashme-installed` snapshot for each
  code, triggers via the CrashMe driver with exact parameters from
  `src/data/trigger-methods.json`, waits for reboot, and runs `collect-guest.ps1`.
  Output goes to `output/sweep-<CODE>/collect-guest.json`.

## Guest access

The guest has OpenSSH (key auth) and WinRM enabled. Connect as `Administrator`
with the project-dedicated key `./.ssh/bsod-test` (git-ignored). `guest-ssh.sh`
uses it automatically:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
./vm/guest-ssh.sh -c 'Get-Date; $env:COMPUTERNAME'
./vm/guest-ssh.sh -f vm/prep-guest.ps1            # (re)run guest prep
```

A password fallback (`GUEST_PASS`, read from git-ignored `.env`) still works if
the key is absent. To re-provision key auth on a fresh guest:
`./vm/guest-ssh.sh -f vm/install-ssh-key.ps1 -- "-PublicKey '$(cat .ssh/bsod-test.pub)'"`.

## Running a test

To run the full KeBugCheckEx sweep (all 19 codes):
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
./vm/sweep-crashme.sh
```

**Driver Verifier is enabled** in this guest (it changes several outcomes;
notably 0x0A is observed as 0xD1).

## Usage

All commands target `qemu:///system` (runs as root via libvirtd). You must be in
the `libvirt` group; no sudo needed.

```bash
./vm/vmctl.sh list        # show domains
./vm/vmctl.sh start       # boot the VM
./vm/vmctl.sh console     # serial console
./vm/vmctl.sh snapshot    # create/refresh clean-baseline
./vm/vmctl.sh revert      # roll back to clean-baseline
./vm/vmctl.sh kill        # hard power-off (simulate a freeze for host-side recovery)
./vm/vmctl.sh ip          # guest IP (needs guest agent)
```

## State of the baseline

The `clean-baseline` snapshot is **test-ready**: kernel crash dump configured
(`CrashDumpEnabled=2`, `AlwaysKeepMemoryDump`, `AutoReboot`), page file
system-managed (~8 GB), the CrashMe test driver (`crashme.sys` + `crashme-ctl.exe`)
staged in `C:\Tools`, the project `src/scripts/` and `src/data/` staged under
`C:\bsod-detector\`, SSH key auth installed, and **Driver Verifier enabled for
all drivers**. Revert to it before each run.

NOTE: Driver Verifier being on affects which bug-check code some crash types
produce. If you disable it (`verifier /reset` + reboot), re-run the verification
sweep to re-baseline `src/data/trigger-methods.json`.

To rebuild the baseline from scratch (e.g. after guest changes):

1. `./vm/vmctl.sh start`
2. `./vm/guest-ssh.sh -f vm/prep-guest.ps1`  (idempotent)
3. `./vm/guest-ssh.sh -c 'Restart-Computer -Force'`  (activates page file)
4. `./vm/vmctl.sh stop`
5. `virsh snapshot-delete bsod-test clean-baseline; ./vm/vmctl.sh snapshot`

## Recreating from scratch

```bash
./vm/vmctl.sh define      # (re)define domain from bsod-test.domain.xml
./vm/vmctl.sh start
```

The domain XML references a disk at
`/var/lib/libvirt/images/bsod-test.qcow2` and install ISOs (now ejected). To
reinstall, re-attach the Server 2025 + virtio-win ISOs with
`virsh change-media`.
