# BSOD Detector

Detect, capture, and analyze Blue Screen of Death (BSOD) events on Windows VMs
running under KVM/libvirt or KubeVirt/OpenShift Virtualization.

## Architecture

**Offline-first:** the guest is a pure crash target. After a BSOD, the host
stops the VM, mounts the guest disk via guestfs, and extracts crash dumps +
event logs offline. No guest-side scripts, staging, or SSH needed for evidence
collection.

**Backend-abstracted:** VM operations go through a dispatch layer that selects
`virsh` (KVM) or `virtctl`/`oc` (KubeVirt) based on the `BSOD_DET__HYP_PROV`
environment variable.

## What it captures

- Bug-check (stop) code and parameters, resolved via `data/bugcheck-codes.json`
- Crash dump files (`MEMORY.DMP`, minidumps) extracted offline from the guest disk
- Windows event log entries (System/Application `.evtx`) parsed offline
- Host-side signals (kernel log split-lock `#AC`, Hyper-V enlightenments)
- Raw VM memory backup (ELF format, via `virsh dump --memory-only`)
- BSOD screenshot (framebuffer capture)

## Quick start

```bash
# Run the unit test suite (no VM needed):
cd apps/bsod-detector && bash test/run-tests.sh

# Run the crash-injection verification sweep (requires test VM):
export LIBVIRT_DEFAULT_URI=qemu:///system
./src/scripts/crash-injector/sweep-crashme.sh

# Collect evidence offline after a crash:
./src/scripts/host/collect-offline.sh --vm bsod-test --out ./output/evidence
```

See [**docs/integration.md**](docs/integration.md) for CI/CD patterns, JSON
contracts, and agentic usage.

## Layout

```
apps/bsod-detector/
├── src/
│   ├── scripts/
│   │   ├── host/               # Host-side (Bash/Python) — detection, collection, analysis
│   │   │   ├── backends/       # KVM/KubeVirt backend abstraction
│   │   │   ├── collect-offline.sh  # Primary orchestrator (offline-first)
│   │   │   ├── extract-evtx.py     # Offline .evtx event log parser
│   │   │   └── ...
│   │   ├── guest/              # Guest-side (PowerShell) — one-time config only
│   │   └── crash-injector/     # Test-only BSOD triggers (The Pitcher)
│   └── data/                   # Source-of-truth lookups (bug-check codes, etc.)
├── host-tools/                 # Containerized guestfs extraction
├── test/                       # bats unit tests
├── docs/                       # Architecture, integration, tool selection
└── .gitignore
```

Container image definition: `image/container/bsod-detector/`.

## Notes

- BSOD dumps may contain host-identifying data. Never commit dumps to git.
- `AutoReboot=0` is the recommended CrashControl setting — this prevents
  Windows from rebooting before the crash dump is fully written, allowing
  offline extraction of a complete MEMORY.DMP.
