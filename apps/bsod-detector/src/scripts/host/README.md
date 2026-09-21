# Host-Side Scripts

Bash and Python scripts that run on the **Linux host** (KVM/libvirt or
KubeVirt/OpenShift node), not inside the Windows guest.

## Detection & collection

| Script | Description |
|---|---|
| `watch-crash.sh` | Primary KubeVirt entry point: watch a VM for a natural BSOD/freeze via the guest agent, then collect evidence offline. |
| `collect-from-host.sh` | Libvirt host-side detector + offline dump recovery. |
| `collect-host-signals.sh` | Capture host-side crash-correlation signals (split-lock `#AC`, Hyper-V enlightenments). |
| `collect-offline.sh` | Offline evidence collection orchestrator: stop VM, extract dumps+evtx via guestfs, parse, assemble evidence. |
| `capture-host-dump.sh` | Capture raw VM memory via `virsh dump --memory-only` (ELF format backup artifact). |
| `capture-vm-screen.sh` | Rapid-fire VM framebuffer capture for BSOD screenshot evidence. |

## Analysis

| Script | Description |
|---|---|
| `parse-dump-header.sh` | Read bug-check code and parameters from a Windows crash dump header (no debugger needed). |
| `extract-evtx.py` | Parse offline-extracted `.evtx` event log files into structured JSON. |

## Access & lifecycle

| Script | Description |
|---|---|
| `guest-agent.py` | Drive a KubeVirt guest via the qemu-guest-agent (`oc exec` into the virt-launcher pod). |
| `guest-ssh.sh` | Run PowerShell in the guest over SSH. Used for **crash triggering only** (not evidence collection). |
| `vmctl.sh` | Manage the local libvirt test VM and its snapshots. |

## Backend abstraction

| Script | Description |
|---|---|
| `backends/dispatch.sh` | Source the correct backend (kvm or kubevirt) based on `BSOD_DET__HYP_PROV`. |
| `backends/kvm.sh` | virsh-based VM operations (DetectCrash, StartVM, StopVM, etc.). |
| `backends/kubevirt.sh` | virtctl/oc-based VM operations (untested — requires live KubeVirt cluster). |

## Data files

| File | Description |
|---|---|
| `bsod-test.domain.xml` | Libvirt domain definition for the golden Windows test VM. |
