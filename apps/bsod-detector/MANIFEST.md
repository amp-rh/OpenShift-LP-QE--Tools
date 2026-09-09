# bsod-detector — File Manifest

A catalog of what ships in this tool and why each file is kept. The guiding
split:

- **The Catcher** — detect, capture, and analyze a *real, naturally-occurring*
  BSOD/freeze on an OpenShift **KubeVirt** Windows VM. Everything in
  `src/scripts/` (except the `host/crash-injector/` subfolder) serves this.
- **Guest vs host** — scripts are separated by *where they run*: `src/scripts/guest/`
  executes inside the Windows VM, `src/scripts/host/` on the Linux host/hypervisor,
  and `src/scripts/lib/` is shared by both. `src/data/` is split the same way
  (`guest/`, `host/`, with the shared `bugcheck-codes.json` at the root).
- **The Pitcher** — *intentionally* crash a disposable test guest to validate the
  Catcher. Quarantined under [`src/scripts/host/crash-injector/`](src/scripts/host/crash-injector/README.md).

Primary production path (OCP KubeVirt): `host/watch-crash.sh` → `host/guest-agent.py` →
`guest/collect-guest.ps1`/`guest/compress-dump.ps1` → `guest/analyze-dump.ps1`, using data files in
`src/data/`.

For a narrative version of this catalog — what each file *does*, plus
step-by-step run guides — see [`docs/file-guide.md`](docs/file-guide.md).

---

## src/scripts/ — detection & analysis toolkit (The Catcher)

### Detect / watch
| File | Description |
|---|---|
| `host/stakeout.sh` | **Primary entry point for a natural-BSOD campaign.** Preflight (gate on the preconditions that decide whether the crash can happen *and* be captured) → stage → watch → escalate on hard freeze → verdict. Provider-agnostic (`kubevirt`/`kvm`). |
| `host/watch-crash.sh` | The detection engine behind `stakeout.sh`, also usable standalone. Watch a KubeVirt Windows VM for a natural BSOD/freeze (via the guest agent through the virt-launcher pod) and kick off evidence collection when one is seen. |
| `host/collect-from-host.sh` | libvirt/KVM host-side BSOD/freeze detector + dump recovery — the local-VM counterpart to `watch-crash.sh` (used for development/validation on a libvirt host). |
| `host/collect-host-signals.sh` | Capture Linux/KVM **host-side** crash-correlation signals (qemu/libvirt logs, dmesg, VM state) to pair with in-guest evidence. |
| `host/collect-from-host.ps1` | Hyper-V host-side detector counterpart to `collect-guest.ps1`. **Not part of the OCP KubeVirt path** — kept for Windows/Hyper-V hosts only. |

### Access layer (guest ↔ host)
| File | Description |
|---|---|
| `host/guest-agent.py` | Drive a KubeVirt Windows guest via the qemu-guest-agent (maps `<ns>_<vm>` domain names, runs commands, moves files). Core of the no-SSH OCP access model. |
| `host/guest-ssh.sh` | Run PowerShell in a guest over SSH robustly (EncodedCommand, CLIXML filtering). Used for the local libvirt test VM; shared with `crash-injector/`. |

### Collect / capture evidence
| File | Description |
|---|---|
| `host/collect-all.sh` | Host-side evidence-collection orchestrator that ties the guest + host collectors together. |
| `guest/collect-guest.ps1` | Collect BSOD post-mortem evidence from **inside** the guest after reboot (dump, event log, config). |
| `host/capture-vm-screen.sh` | Rapid-fire VM framebuffer capture — grabs the BSOD screen as image evidence. Needs a QXL/VGA video device; virtio-video goes dark during a kernel crash. |
| `host/capture-host-dump.sh` | Host-side fallback dump: `virsh dump` + QEMU `elf2dmp` → WinDbg-readable `.dmp`, for when the guest's own dump mechanism fails. Preserves the raw ELF for offline re-conversion. |
| `guest/compress-dump.ps1` | Copy and compress `C:\Windows\MEMORY.DMP` for extraction over the guest agent. |

### Analyze
| File | Description |
|---|---|
| `guest/analyze-dump.ps1` | Symbolize a Windows crash dump and extract bucket ID, faulting image, and bug-check details. |
| `host/parse-dump-header.sh` | Read the bug-check code and parameters straight from a Windows kernel dump header (no debugger needed). |
| `guest/test-bugcheck-lookup.ps1` | Self-test: verify the collector's bug-check parsing/lookup resolves every code in `src/data/`. |

### Configure guest for capture
| File | Description |
|---|---|
| `guest/configure-dumps.ps1` | Configure Windows crash-dump settings so a dump is written on the next BSOD. |
| `guest/probe-dump-config.ps1` | Report the guest's current crash-dump configuration and dump inventory. |
| `guest/clear-dumps.ps1` | Delete existing crash dumps so a test captures only the new one. |

### Deploy / provision
| File | Description |
|---|---|
| `guest/stage-toolkit.ps1` | Unpack the uploaded toolkit archive into `C:\bsod-detector` in the guest. |
| `guest/install-debuggers.ps1` | Install the Windows Debugging Tools (cdb) in the guest for deep dump analysis. |
| `guest/install-ssh-key.ps1` | Install an SSH public key for passwordless admin login to the guest. |

### VM lifecycle (local test rig)
| File | Description |
|---|---|
| `host/vmctl.sh` | Manage the local libvirt test VM (`bsod-test`) and its `clean-baseline` snapshot: define / snapshot / revert / start / stop. Shared with `crash-injector/`. |
| `host/bsod-test.domain.xml` | libvirt domain definition for the golden Windows test VM (Q35+UEFI, virtio, TPM, guest agent). Shared with `crash-injector/`. |

### Shared library
| File | Description |
|---|---|
| `lib/Common.ps1` | Shared PowerShell helpers (path resolution to repo/data dirs, logging) used by the collector/config scripts. |

---

## src/data/ — reference data
| File | Description |
|---|---|
| `bugcheck-codes.json` | Bug-check code → human-readable name/description lookup. |
| `guest/crash-control.json` | Expected Windows CrashControl registry settings for a capture-ready guest. |
| `guest/event-sources.json` | Windows event-log sources relevant to crash/freeze correlation. |
| `host/host-signals.json` | Host-side signals to collect and how to correlate them. |
| `host/trigger-methods.json` | Per-`KeBugCheckEx` code parameters (also drives the injector's sweep). |
| `host/chaos-triggers.json` | 24 organic (non-`KeBugCheckEx`) fault-injection scenarios across 5 tiers; drives `sweep-chaos.sh`. |
| `host/blkdebug-read-errors.conf` | QEMU blkdebug config for injecting EIO on reads (the `blkdebug-config` trigger). |

---

## src/scripts/host/crash-injector/ — The Pitcher (intentional BSOD, test-only)

Quarantined destructive tooling used only to validate the detector against a
disposable snapshotted test VM. See
[`src/scripts/host/crash-injector/README.md`](src/scripts/host/crash-injector/README.md)
for the per-file breakdown (`trigger-bsod.ps1`, `setup-notmyfault.ps1`,
`diag-critical-api.ps1`, `prep-guest.ps1`, `run-dry-run.sh`, `sweep-crashme.sh`,
`test-driver/`).
