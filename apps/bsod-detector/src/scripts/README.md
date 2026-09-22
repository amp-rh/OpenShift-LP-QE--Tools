# Scripts

Organized by execution context:

- **[`host/`](host/README.md)** — Bash/Python scripts that run on the Linux
  host (KVM or KubeVirt node). Detection, offline collection, analysis, VM
  lifecycle, and backend abstraction.

- **[`guest/`](guest/README.md)** — PowerShell scripts that run inside the
  Windows guest. One-time CrashControl configuration only; evidence collection
  is handled offline from the host side.

- **[`crash-injector/`](crash-injector/README.md)** — The Pitcher: destructive
  test-only scripts that intentionally crash a disposable guest to validate the
  detector. Never point them at production.

## Design

- **Offline-first:** the guest is a pure crash target. After a BSOD, the host
  stops the VM, mounts the disk via guestfs, and extracts dumps + event logs
  offline. No guest-side scripts, staging, or SSH needed for evidence collection.

- **One job per script**, each emits exactly one JSON object to stdout.

- **All lookup tables live in [`../data/`](../data/README.md).**

- A per-file catalog lives in [`../../MANIFEST.md`](../../MANIFEST.md).
