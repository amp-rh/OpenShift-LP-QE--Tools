# bsod-detector — File Manifest

A catalog of what ships in this tool and why each file is kept. The guiding
split:

- **The Catcher** — detect, capture, and analyze a *real, naturally-occurring*
  BSOD/freeze on an OpenShift **KubeVirt** Windows VM. Everything in
  `src/scripts/` (except the `crash-injector/` subfolder) serves this.
- **The Pitcher** — *intentionally* crash a disposable test guest to validate the
  Catcher. Quarantined under [`src/scripts/crash-injector/`](src/scripts/crash-injector/README.md).

Primary production path (OCP KubeVirt): `watch-crash.sh` → `guest-agent.py` →
`collect-guest.ps1`/`compress-dump.ps1` → `analyze-dump.ps1`, using data files in
`src/data/`.

---

## src/scripts/ — detection & analysis toolkit (The Catcher)

### Detect / watch
| File | Description |
|---|---|
| `watch-crash.sh` | **Primary OCP entry point.** Watch a KubeVirt Windows VM for a natural BSOD/freeze (via the guest agent through the virt-launcher pod) and kick off evidence collection when one is seen. |
| `collect-from-host.sh` | libvirt/KVM host-side BSOD/freeze detector + dump recovery — the local-VM counterpart to `watch-crash.sh` (used for development/validation on a libvirt host). |
| `collect-host-signals.sh` | Capture Linux/KVM **host-side** crash-correlation signals (qemu/libvirt logs, dmesg, VM state) to pair with in-guest evidence. |
| `collect-from-host.ps1` | Hyper-V host-side detector counterpart to `collect-guest.ps1`. **Not part of the OCP KubeVirt path** — kept for Windows/Hyper-V hosts only. |

### Access layer (guest ↔ host)
| File | Description |
|---|---|
| `guest-agent.py` | Drive a KubeVirt Windows guest via the qemu-guest-agent (maps `<ns>_<vm>` domain names, runs commands, moves files). Core of the no-SSH OCP access model. |
| `guest-ssh.sh` | Run PowerShell in a guest over SSH robustly (EncodedCommand, CLIXML filtering). Used for the local libvirt test VM; shared with `crash-injector/`. |

### Collect / capture evidence
| File | Description |
|---|---|
| `collect-all.sh` | Host-side evidence-collection orchestrator that ties the guest + host collectors together. |
| `collect-guest.ps1` | Collect BSOD post-mortem evidence from **inside** the guest after reboot (dump, event log, config). |
| `capture-vm-screen.sh` | Rapid-fire VM framebuffer capture — grabs the BSOD screen as image evidence. |
| `compress-dump.ps1` | Copy and compress `C:\Windows\MEMORY.DMP` for extraction over the guest agent. |

### Analyze
| File | Description |
|---|---|
| `analyze-dump.ps1` | Symbolize a Windows crash dump and extract bucket ID, faulting image, and bug-check details. |
| `parse-dump-header.sh` | Read the bug-check code and parameters straight from a Windows kernel dump header (no debugger needed). |
| `test-bugcheck-lookup.ps1` | Self-test: verify the collector's bug-check parsing/lookup resolves every code in `src/data/`. |

### Configure guest for capture
| File | Description |
|---|---|
| `configure-dumps.ps1` | Configure Windows crash-dump settings so a dump is written on the next BSOD. |
| `probe-dump-config.ps1` | Report the guest's current crash-dump configuration and dump inventory. |
| `clear-dumps.ps1` | Delete existing crash dumps so a test captures only the new one. |

### Deploy / provision
| File | Description |
|---|---|
| `stage-toolkit.ps1` | Unpack the uploaded toolkit archive into `C:\bsod-detector` in the guest. |
| `install-debuggers.ps1` | Install the Windows Debugging Tools (cdb) in the guest for deep dump analysis. |
| `install-ssh-key.ps1` | Install an SSH public key for passwordless admin login to the guest. |

### VM lifecycle (local test rig)
| File | Description |
|---|---|
| `vmctl.sh` | Manage the local libvirt test VM (`bsod-test`) and its `clean-baseline` snapshot: define / snapshot / revert / start / stop. Shared with `crash-injector/`. |
| `bsod-test.domain.xml` | libvirt domain definition for the golden Windows test VM (Q35+UEFI, virtio, TPM, guest agent). Shared with `crash-injector/`. |

### Shared library
| File | Description |
|---|---|
| `lib/Common.ps1` | Shared PowerShell helpers (path resolution to repo/data dirs, logging) used by the collector/config scripts. |

---

## src/data/ — reference data
| File | Description |
|---|---|
| `bugcheck-codes.json` | Bug-check code → human-readable name/description lookup. |
| `crash-control.json` | Expected Windows CrashControl registry settings for a capture-ready guest. |
| `event-sources.json` | Windows event-log sources relevant to crash/freeze correlation. |
| `host-signals.json` | Host-side signals to collect and how to correlate them. |
| `trigger-methods.json` | Per-`KeBugCheckEx` code parameters (also drives the injector's sweep). |

---

## src/scripts/crash-injector/ — The Pitcher (intentional BSOD, test-only)

Quarantined destructive tooling used only to validate the detector against a
disposable snapshotted test VM. See
[`src/scripts/crash-injector/README.md`](src/scripts/crash-injector/README.md)
for the per-file breakdown (`trigger-bsod.ps1`, `setup-notmyfault.ps1`,
`diag-critical-api.ps1`, `prep-guest.ps1`, `run-dry-run.sh`, `sweep-crashme.sh`,
`test-driver/`).
