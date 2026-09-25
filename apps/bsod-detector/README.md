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

## What It Captures

Keep it simple. Prefer a small, well-defined tool over a broad framework.

---

## Deployment Model: Where Scripts Run

BSOD detection is a **3-tier distributed system**:

```
┌─────────────────────────┐
│   CI Operator           │  Orchestration host: manages test execution
│   (Local/CI Agent)      │
│                         │
│ • watch-crash.sh        │
│ • guest-agent.py        │
│ • collect-from-host.sh  │
│ • crash-injector/       │
│                         │
└────────────┬────────────┘
             │ oc exec / SSH
             ↓
┌─────────────────────────┐
│ Virt-Launcher Pod       │  Kubernetes: manages the VM
│ (or KVM Host)           │
│                         │
│ • virsh commands        │
│ • VM lifecycle mgmt     │
│ • Evidence extraction   │
│                         │
└────────────┬────────────┘
             │ qemu-guest-agent
             ↓
┌─────────────────────────┐
│ Windows VM (Guest)      │  Test target: configuration and monitoring
│                         │
│ • configure-dumps.ps1   │
│ • clear-dumps.ps1       │
│ • NotMyFault.exe        │
│ (crash trigger)         │
└─────────────────────────┘
```

### CI Operator (CI/CD System or Orchestration Host)

Scripts executed on the orchestration layer to coordinate the entire test pipeline:

- `watch-crash.sh` — natural BSOD detection with automatic escalation
- `guest-agent.py` — tunnel PowerShell commands into the VM
- `collect-from-host.sh` — coordinate detection → capture → analysis
- `src/scripts/crash-injector/` — intentional crash triggers

**Execution context:**
- **KubeVirt:** Via `oc exec` into virt-launcher pod
- **KVM/libvirt:** Directly on the hypervisor host via SSH

---

### Virt-Launcher Pod (Kubernetes) or KVM Host

The hypervisor layer that manages the VM. Scripts here are invoked **indirectly** by the CI Operator:

- `virsh` commands (executed inside the pod or on the KVM host)
- VM lifecycle management (start, stop, snapshot)
- Evidence extraction from disk images
- Memory/screen capture

**Execution method:**
- **KubeVirt:** Inside the `virt-launcher-<vm>-*` pod
- **KVM/libvirt:** On the Linux host directly

---

### Windows VM (Guest)

PowerShell scripts **inside** the Windows guest for one-time configuration:

- `configure-dumps.ps1` — enable full crash dumps (CrashControl registry)
- `clear-dumps.ps1` — clear existing crash dumps before test
- NotMyFault.exe — optional crash trigger utility

**Execution context:**
- **KubeVirt:** Via qemu-guest-agent protocol (SSH not available)
- **KVM/libvirt:** Via SSH connection to Windows guest

---

## Testing Workflow: Commands by Layer

This section shows **exactly which commands run on each layer** during a complete test.

### Complete Test Sequence: Intentional Crash Injection

```
╔════════════════════════════════════════════════════════════════════════════╗
║                         INTENTIONAL CRASH INJECTION FLOW                   ║
╚════════════════════════════════════════════════════════════════════════════╝

PHASE 1: SETUP (One-Time)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator (Orchestration)  │
│  - Stage toolkit            │
│  - Configure dumps          │
│  - Setup NotMyFault injector│
└──────────────┬──────────────┘
               │ guest-agent.py psfile
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward via qemu-agent    │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [Setup Scripts Execute]     │
│  - Directories created       │
│  - Registry configured       │
│  - NotMyFault.exe installed  │
└──────────────────────────────┘

PHASE 2: CRASH TRIGGER (Per-Test)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Clear old dumps (optional)│
│  - Execute crash command     │
└──────────────┬──────────────┘
               │ guest-agent.py exec
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward crash trigger     │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [CRASH OCCURS]              │
│  notmyfaultc64.exe /crash    │
│  ↓ BSOD triggered (0x01)     │
│  ↓ MEMORY.DMP written        │
│  ↓ Agent unresponsive        │
└──────────────────────────────┘

PHASE 3: EVIDENCE COLLECTION (Offline)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Run host-tools extraction │
└──────────────┬──────────────┘
               │ libguestfs container
               ↓
┌──────────────────────────────┐
│ Disk Image (Offline Mount)   │
│  [Read-Only NTFS Access]     │
│  - Extract MEMORY.DMP        │
│  - Extract Minidump/*.dmp    │
│  - Extract System.evtx       │
│  - Extract Application.evtx  │
└──────────────┬───────────────┘
               │
               ↓
┌──────────────────────────────┐
│ Evidence Directory           │
│  ./evidence/                 │
│  ├── MEMORY.DMP              │
│  ├── Minidump/               │
│  ├── winevt/System.evtx      │
│  ├── winevt/Application.evtx │
│  └── evidence-summary.json   │
└──────────────────────────────┘
```

---

### Layer-by-Layer Commands

#### Layer 1: CI Operator (Your Machine)

**What runs:** Bash/Python orchestration scripts

**Location:** Your laptop, CI/CD pipeline, or anywhere with `oc`/SSH access to cluster

**Commands you execute:**

```bash
# Set variables
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Setup: Stage toolkit on guest
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected output: [uploaded ...] [exit 0]

# 2. Setup: Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\bsod-detector\src\scripts\guest\configure-dumps.ps1'
# Expected output: Registry keys set, dump type configured

# 3. Prepare: Setup NotMyFault
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected output: [uploaded ...] notmyfaultc64.exe present: True

# 4. Action: Trigger crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected output: (timeout or error — guest has crashed, agent unresponsive)
# This is NORMAL and EXPECTED

# 5. Collect: Extract dumps offline
# Resolve disk image dynamically first (see "Resolving Disk Image Paths Dynamically" section)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected output: MEMORY.DMP extracted, minidumps extracted, JSON result

# 6. Verify: Check evidence
ls -lah ./evidence/dumps/
cat ./evidence/dumps/MEMORY.DMP | head -c 100
```

---

#### Layer 2: Virt-Launcher Pod (Kubernetes)

**What runs:** `virsh` commands and qemu-guest-agent forwarding

**Location:** Inside the `virt-launcher-<vm>-*` pod in the cluster

**Commands that run indirectly** (invoked by `guest-agent.py` on Layer 1):

```bash
# You don't run these directly — guest-agent.py does it for you via oc exec
# But here's what happens inside the pod:

# Check VM is running
virsh -q domifaddr win2022-vm-hjoshi1
# Output: vnet0  52:54:00:12:34:56  ipv4  10.0.0.42/24

# Forward PowerShell command to guest agent
virsh qemu-agent-command "windows-bsod_win2022-vm-hjoshi1" \
  '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\cmd.exe",...}}'
# Output: {"return":{"pid":1234}}

# Check guest agent status
virsh qemu-agent-command "windows-bsod_win2022-vm-hjoshi1" '{"execute":"guest-ping"}'
# Output: (hangs or timeout if guest has crashed — EXPECTED)

# After crash: Stop the VM
virsh destroy win2022-vm-hjoshi1
# Output: Domain win2022-vm-hjoshi1 destroyed
```

**How to manually run these (for debugging):**

```bash
# SSH/exec into the pod
POD=$(oc get pod -n windows-bsod -o name | grep virt-launcher-win2022-vm-hjoshi1 | head -1 | cut -d/ -f2)
oc -n windows-bsod exec -it $POD -- bash

# Inside pod, now you can run virsh directly
virsh domifaddr win2022-vm-hjoshi1
virsh qemu-agent-command "windows-bsod_win2022-vm-hjoshi1" '{"execute":"guest-ping"}'
virsh dumpxml win2022-vm-hjoshi1 | grep disk  # Find disk path
```

---

#### Layer 3: Windows VM (Guest)

**What runs:** PowerShell scripts executed via guest-agent

**Location:** Inside the Windows guest VM

**Commands that execute** (via `GA_VM=... guest-agent.py exec`):

```powershell
# 1. Configure crash dumps (runs once)
C:\bsod-detector\src\scripts\guest\configure-dumps.ps1

# What it does:
#   - Sets HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\CrashControl
#   - AutoReboot = 1 (VM reboots after crash so evidence can be pulled via QGA)
#   - CrashDumpEnabled = 2 (kernel dump)
#   - AlwaysKeepMemoryDump = 1
#   - DumpFile = C:\Windows\MEMORY.DMP
#   - MinidumpDir = C:\Windows\Minidump

# 2. Clear existing dumps before test
C:\bsod-detector\src\scripts\guest\clear-dumps.ps1

# What it does:
#   - Deletes C:\Windows\Minidump\*
#   - Deletes C:\Windows\MEMORY.DMP
#   (MEMORY.DMP must be gone before crash — existing file causes Windows
#   to write only changed pages, producing a fast but partial dump)

# 3. Trigger crash
C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01

# What it does:
#   - Loads myfault.sys driver
#   - Executes crash code 0x01 (IRQL_NOT_LESS_OR_EQUAL → 0xD1)
#   - Windows writes MEMORY.DMP then reboots (AutoReboot=1)
#   - Guest becomes unresponsive to QGA queries during crash+dump write
```

**Expected behavior:**

| Step | Expected | What to Check |
|------|----------|---------------|
| Setup toolkit | [exit 0] | `oc exec <pod> -- virsh qemu-agent-command ... '{"execute":"guest-ping"}'` returns immediately |
| Configure dumps | Registry set | Guest still responsive to ping |
| Setup NotMyFault | notmyfaultc64.exe present | `ls C:\Temp\nmf\` shows files |
| Trigger crash | **TIMEOUT** | This is EXPECTED — guest crashed, agent unresponsive |
| After crash | No response | `virsh qemu-agent-command` hangs/times out |

---

### Troubleshooting: What to Check at Each Layer

| Symptom | Check | Solution |
|---------|-------|----------|
| `guest-agent.py` hangs on setup | Pod exists and running | `oc get pod -n $NS \| grep virt-launcher` |
| Setup commands timeout | Guest agent responsive | `GA_VM=... guest-agent.py ping` |
| Crash trigger timeout | Expected if crash worked | Wait 30s, VM should be unresponsive |
| Can't extract dumps | Disk image readable | `ls -l /var/lib/libvirt/images/...qcow2` |
| MEMORY.DMP not found | AutoReboot setting | Verify `configure-dumps.ps1` ran successfully |

---

## guest-agent.py Reference

**What it does:** Tunnel PowerShell commands into the Windows guest via qemu-guest-agent.  
**Where it runs:** CI Operator layer (orchestration host or CI/CD pipeline).  
**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest.

### Setup Environment

```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Verify guest agent is responsive before running anything
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Output: (empty/immediate if responsive; timeout if guest unreachable)
```

### Subcommands

| Command | Purpose | Example |
|---------|---------|---------|
| `ping` | Check if guest agent is alive | `GA_VM=$VM GA_NS=$NS python3 ... ping` |
| `exec <program> [args]` | Run a command in guest | `GA_VM=$VM GA_NS=$NS python3 ... exec powershell -Command 'Get-Date'` |
| `psfile <script.ps1> [args]` | Upload and run PowerShell script | `GA_VM=$VM GA_NS=$NS python3 ... psfile src/scripts/guest/configure-dumps.ps1` |
| `put <local> <guest-path>` | Upload file to guest | `GA_VM=$VM GA_NS=$NS python3 ... put file.zip 'C:\Temp\file.zip'` |
| `get <guest-path> <local>` | Download file from guest | `GA_VM=$VM GA_NS=$NS python3 ... get 'C:\Windows\MEMORY.DMP' ./MEMORY.DMP` |

### Quick Reference

```bash
# ONE-TIME SETUP (run once per VM)
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Stage toolkit
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

# 2. Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

# 3. Setup crash trigger (if using NotMyFault)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1

# BEFORE EACH TEST
# 4. Clear old dumps (optional, for clean evidence)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

# AFTER CRASH
# 5. Extract evidence (guest is now offline/crashed)
# Resolve disk image dynamically first (see "Resolving Disk Image Paths Dynamically" section)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
```

### Performance Considerations: guest-agent.py Slowness

**⚠️ Known Issue:** `guest-agent.py psfile` and `guest-agent.py exec` commands can be **very slow** (30-120+ seconds per command) due to:

1. **qemu-guest-agent overhead** — RPC communication through libvirt/KVM
2. **PowerShell startup time** — Even simple scripts take time to load
3. **Network latency** — oc exec → virt-launcher pod → virsh adds layers
4. **Guest system load** — Heavy I/O or high CPU makes responses slower

**Recommended Timeout Values:**
- `psfile <script>` — **120 seconds** (setup scripts can be slow)
- `exec <command>` — **60 seconds** (simpler commands are faster)
- Large file transfers (`put`, `get`) — **180+ seconds** (I/O bound)

**Optimization Tips:**
- ✅ Batch commands where possible (one large script vs. multiple small ones)
- ✅ Check `GA_VM=$VM GA_NS=$NS python3 ... ping` first (should return immediately)
- ✅ If `ping` hangs, the guest-agent is unresponsive — restart the VM
- ✅ For production, pre-stage setup scripts (stage-toolkit, configure-dumps) once during VM creation
- ✅ Use `host-tools/run.sh` for evidence extraction instead of guest-side collection (offline is faster)

**Debugging:**
```bash
# Check if guest-agent is reachable
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Expected: Returns immediately (empty output {})
# If it hangs: guest-agent is unresponsive

# Test with a simple command (60s timeout)
timeout 60 bash -c 'GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec powershell -NoProfile -Command "Write-Host done"'
# If this times out: guest may be under high load or unresponsive
```

---

## Integration: Detecting Externally-Triggered BSOD

**Scenario:** An external test operator generates a BSOD via an independent mechanism (not via our crash-injector). The BSOD Detector watches for the event, detects it, and captures evidence automatically.

### External Test Operator Responsibilities

1. **Pre-BSOD Setup** (one-time, before triggering crash):
   - Coordinate with CI Operator to confirm `configure-dumps.ps1` has been executed
   - Verify VM is ready to write full crash dumps (registry configured)
   - Note: AutoReboot=1 is required — VM reboots after crash so evidence can be pulled via QGA

2. **Generate BSOD**:
   - Trigger the crash using external mechanism (independent of this toolkit)
   - Windows writes crash dump to `C:\Windows\MEMORY.DMP`
   - Guest becomes unresponsive to network/agent

3. **Notify CI Operator**:
   - Inform CI Operator when BSOD has been triggered
   - Provide timestamp for correlation
   - CI Operator detects it automatically via `watch-crash.sh`

### CI Operator Responsibilities

```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Step 1: ONE-TIME GUEST SETUP (before external test operator triggers BSOD)
echo "=== Configuring guest for crash dump collection ==="
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

echo "Setup complete. Notify external test operator that VM is ready for BSOD."

# Step 2: START DETECTION WATCHER (before external operator triggers BSOD)
echo "=== Watching for externally-triggered BSOD (will block until detected or timeout) ==="
./src/scripts/host/watch-crash.sh \
  --provider kubevirt \
  --ns $NS \
  --vm $VM \
  --scenario natural \
  --out ./evidence \
  --duration 3600

# (This command will block until BSOD detected)
# External operator triggers crash while this is running
# Detector will automatically:
#   1. Capture screenshot at crash time
#   2. Capture raw VM memory
#   3. Stop the VM
#   4. Extract crash dumps offline via libguestfs

# Step 3: COLLECT & VERIFY RESULTS (after watch-crash.sh exits)
echo "=== Evidence collection complete ==="
ls -lah ./evidence/
cat ./evidence/evidence-summary.json | jq .
cat ./evidence/evidence-summary.json | jq .verdict
```

### Execution Flow

```
╔════════════════════════════════════════════════════════════════════════════╗
║                    EXTERNAL BSOD DETECTION & CAPTURE                       ║
╚════════════════════════════════════════════════════════════════════════════╝

External Operator               CI Operator                 VM (Guest)
     ┌─────────────┐            ┌─────────────┐          ┌──────────────┐
     │  PREPARE    │            │   SETUP     │          │   WAITING    │
     │ (Notify)    │────────→   │ configure   │   ┌─────→│    Ready     │
     │             │            │ dumps.ps1   │   │      │              │
     └─────────────┘            └─────────────┘   │      └──────────────┘
                                                   │
                                 ┌─────────────┐  │
                                 │  WATCH      │──┘
                                 │ watch-crash │
                                 │  (blocking)  │
                                 └──────┬──────┘
                                        │ polls
                                        │ guest-agent every 5s
                                        ├──────────────────→

     ┌──────────┐                                          ┌──────────────┐
     │ TRIGGER  │──→ (external mechanism) ──→ [Crash!] ──→│  BSOD        │
     │  BSOD    │                                         │ Writes MEMORY │
     └──────────┘                                         │ Agent DOWN    │
                                                          └──────┬───────┘
                                 ┌──────────────┐                │
                                 │ DETECTS ✅   │← ─ ─ ─ ─ ─ ─ ┘
                                 │ Unresponsive │
                                 └───────┬──────┘
                                        ┌┴──────────────────────┐
                                        │  ESCALATE:             │
                                        │  1. Screenshot         │
                                        │  2. Memory capture     │
                                        │  3. Stop VM            │
                                        │  4. Extract offline    │
                                        └───────┬────────────────┘
                                                ↓
                                    ┌──────────────────┐
                                    │ ./evidence/      │
     ┌──────────┐                  │  ├─ MEMORY.DMP   │
     │ NOTIFIED │←─────────────────│  ├─ Minidumps    │
     │  Done    │                  │  ├─ Event logs   │
     └──────────┘                  │  └─ JSON summary │
                                    └──────────────────┘
                                         ✅ Analysis Ready
```

### Coordination Checklist

**Pre-BSOD Coordination:**
1. ✅ CI Operator confirms `configure-dumps.ps1` executed successfully
2. ✅ External Test Operator confirms readiness to trigger crash
3. ✅ CI Operator initiates `watch-crash.sh`
4. ✅ Allow ~10 seconds for watch initialization

**During BSOD Trigger:**
5. ✅ External Test Operator triggers crash via designated mechanism
6. ✅ Verify AutoReboot=1 is set so VM reboots and evidence can be collected
7. ✅ Guest unresponsiveness is expected behavior

**Post-BSOD Collection:**
8. ✅ External Test Operator notifies CI Operator upon crash completion
9. ✅ CI Operator's `watch-crash.sh` detects event automatically
10. ✅ Evidence collection to `./evidence/` executes automatically

### Troubleshooting External Integration

| Issue | Cause | Resolution |
|-------|-------|-----------|
| Detector doesn't detect externally-triggered BSOD | Guest agent still responsive | Verify `configure-dumps.ps1` ran and set `AutoReboot=1` |
| MEMORY.DMP not found after crash | Dump not written before VM stopped | Increase detection timeout or verify crash actually occurred |
| Evidence directory empty | Guest agent responsive despite crash | Check if external mechanism actually triggered proper BSOD |
| Timeout waiting for crash | External operator hasn't triggered yet | Verify communication and timing with external operator |

---

## Resolving Disk Image Paths Dynamically

Instead of hardcoding disk image paths like `/var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2`, you can extract the disk path dynamically from the running VM.

### Why Dynamic Resolution?

✅ Works across different hypervisors (KVM/libvirt and KubeVirt)  
✅ Supports custom storage paths  
✅ Makes scripts portable and reusable  
✅ Doesn't depend on naming conventions  

### How to Extract the Disk Path

**For KubeVirt VMs**, query virsh inside the virt-launcher pod:

```bash
# Variables
VM="win2022-vm-hjoshi1"
NS="windows-bsod"
DOM_NAME="${NS}_${VM}"

# 1. Find the virt-launcher pod
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)

# 2. Extract disk path using virsh domblklist
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "$DOM_NAME" | grep vda | awk '{print $2}')

# 3. Use the resolved path
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

**What each step does:**

1. **Find the pod:** Queries KubeVirt for the virt-launcher pod managing your VM
2. **Extract disk:** Uses `virsh domblklist` to list block devices (returns path like `/var/lib/libvirt/images/...qcow2`)
3. **Use path:** Pass to `host-tools/run.sh` for offline evidence extraction

### In Your Test Script

The complete test script (`bsod-detector-test.sh`) automatically does this:

```bash
# Step 0: Resolve VM configuration
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')

# Step 3: Use resolved path for evidence extraction
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

This eliminates manual disk path lookups and makes the script work on any VM in any namespace.

---

## Test Scenarios

The toolkit supports **3 ways to trigger and capture a BSOD**:

### Scenario 1: Intentional Crash Injection (NotMyFault)

**When to use:** Controlled testing with a known crash code via NotMyFault.exe.

**CI Operator runs:**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=1 set, dump type=kernel

# 3. Setup NotMyFault injector (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected: notmyfaultc64.exe present in C:\Temp\nmf\

# PER-TEST SEQUENCE

# 4. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 5. Trigger the crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected: TIMEOUT (guest has crashed, this is expected)

# 6. Extract evidence offline (guest is now stopped)
# IMPORTANT: Use dynamic disk path resolution (see section above)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result
```

**What happens inside the VM:**
- configure-dumps.ps1 sets registry (AutoReboot=1, CrashDumpEnabled=2 kernel dump)
- NotMyFault.exe executes crash code 0x01
- Windows writes MEMORY.DMP to C:\Windows\

**What the CI Operator captures:**
- BSOD screenshot
- Raw VM memory (optional)
- MEMORY.DMP + minidumps (offline extraction)
- Event logs (.evtx files)

---

### Scenario 2: Natural BSOD Detection (Watch-Crash)

**When to use:** Detecting a real, unplanned BSOD triggered externally (by external test operator).

**CI Operator runs:**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=1 set, dump type=kernel

# PER-TEST SEQUENCE

# 3. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 4. Start watching for natural BSOD (blocks until detected)
./src/scripts/host/watch-crash.sh \
  --ns $NS \
  --vm $VM \
  --out ./evidence \
  --interval 5 \
  --miss 2 \
  --reboot-wait 300
# This will block until BSOD detected or timeout occurs
# External Test Operator triggers crash while this is running
# watch-crash.sh automatically:
#   1. Detects guest unresponsiveness
#   2. Captures screenshot
#   3. Captures host-side signals
#   4. Extracts evidence offline
#   5. Generates evidence-summary.json
```

**What happens during monitoring:**
- Continuously polls qemu-guest-agent health
- Detects BSOD/freeze when guest stops responding
- Automatically captures screenshot at crash moment
- Records host-side signals (TLB-flush, split-lock)
- Waits for guest reboot or detects hard-freeze

**What the CI Operator gets:**
- Automatic screenshot at crash time
- Host kernel log analysis
- Crash dump files (if guest reboots)
- Event log evidence
- Evidence summary JSON with crash metadata

See **[docs/natural-bsod-workflow.md](docs/natural-bsod-workflow.md)** for detailed runbook.

---

### Scenario 3: Offline Dump Extraction

**When to use:** VM is already crashed/frozen/stopped; extract evidence from disk image without VM interaction.

**CI Operator runs:**
```bash
# IMPORTANT: Resolve disk image dynamically (see section above)
VM="win2022-vm-hjoshi1"
NS="windows-bsod"
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')

# Method 1: Direct extraction via host-tools
./host-tools/run.sh \
  --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result

# Method 2: Via collect-offline orchestrator
./src/scripts/host/collect-offline.sh \
  --vm win2022-vm-hjoshi1 \
  --out ./evidence
# Expected: Full evidence bundle with analysis
```

**What happens:**
- ✅ Mounts disk image via libguestfs (read-only)
- ✅ Extracts MEMORY.DMP and minidumps from C:\Windows\
- ✅ Extracts event logs (.evtx files)
- ✅ Parses dump headers for crash analysis
- ✅ No VM interaction or reboots needed

**Useful for:**
- Unbootable/unconfigurable guests
- Frozen VMs (cannot reach via guest-agent)
- Post-mortem analysis of existing disk images
- Recovery from hard-freeze states

---

## Execution Environments

### KubeVirt (OpenShift Cluster)

**Use when:** Testing in Kubernetes/OpenShift environment.

**CI Operator location:** Your laptop or CI/CD pipeline  
**Command pattern:**
```bash
GA_VM=<vm-name> GA_NS=<namespace> python3 src/scripts/host/guest-agent.py <subcommand>
oc -n <namespace> exec <virt-launcher-pod> -- virsh <cmd>
```

**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest

**Example (from earlier):**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Trigger crash injection
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kubevirt --ns $NS --vm $VM --out ./evidence
```

---

### KVM/libvirt (Local Host)

**Use when:** Testing locally on KVM/libvirt infrastructure.

**CI Operator location:** The KVM host itself  
**Command pattern:**
```bash
export VM_NAME=bsod-test
export LIBVIRT_DEFAULT_URI=qemu:///system

src/scripts/host/guest-ssh.sh -c '<PowerShell command>'
# For disk path, use: virsh domblklist <vm> | grep vda | awk '{print $2}'
# or the dynamic resolution pattern (see "Resolving Disk Image Paths Dynamically" section)
./host-tools/run.sh --disk <resolved-disk-image> --out ./output
```

**Transport:** SSH to Windows guest or `virsh` on the host

**Example (local testing):**
```bash
export VM_NAME=bsod-test

# Trigger crash injection
src/scripts/host/guest-ssh.sh -f src/scripts/crash-injector/setup-notmyfault.ps1
src/scripts/host/guest-ssh.sh -c 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kvm --vm $VM_NAME --out ./evidence

# Or extract from offline image directly
# Resolve disk path: virsh domblklist $VM_NAME | grep vda | awk '{print $2}'
DISK_IMAGE=$(virsh domblklist $VM_NAME | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./output
```

---

## Conventions

### Scripts as tooling

Deterministic operations live in scripts with clear stdin/stdout contracts.

- **Scripts produce facts; humans make decisions.** Data collection, parsing dump files, reading event logs, and formatting output belong in scripts. Interpreting a crash or deciding how to act on it is a human call.
- `src/scripts/` contains guest collection and configuration scripts. Host-side collectors (such as `collect-host-signals.sh`) also live here when they consume `src/data/` lookups and follow the same output contract. Each collector script does one thing and emits exactly one JSON object to stdout so downstream steps can consume it with `jq` or `json.loads()`. Helper scripts like `capture-vm-screen.sh` that produce file artifacts instead of JSON are excluded from this contract.
- Every script is documented in [`src/scripts/README.md`](src/scripts/README.md): what it does, its inputs, and its output shape.
- **No hardcoded duplicated data.** Bug-check code tables, driver mappings, and log source names come from a single source-of-truth file that scripts read; never copy the same lookup into multiple scripts.

### Style

- Windows-first. Scripts are PowerShell (`.ps1`) unless there is a reason to use another language; note the requirement at the top of each script.
- Keep functions small and testable. Fail loudly with clear error messages.
- Never require interactive input in a script that may run unattended after a crash.

Keep it simple. Prefer a small, well-defined tool over a broad framework.

- Bug-check (stop) code and parameters, resolved via `data/bugcheck-codes.json`
- Crash dump files (`MEMORY.DMP`, minidumps) extracted offline from the guest disk
- Windows event log entries (System/Application `.evtx`) parsed offline
- Host-side signals (kernel log split-lock `#AC`, Hyper-V enlightenments)
- Raw VM memory backup (ELF format, via `virsh dump --memory-only`)
- BSOD screenshot (framebuffer capture)

---

## Deployment Model: Where Scripts Run

BSOD detection is a **3-tier distributed system**:

```
┌─────────────────────────┐
│   CI Operator           │  Orchestration host: manages test execution
│   (Local/CI Agent)      │
│                         │
│ • watch-crash.sh        │
│ • guest-agent.py        │
│ • collect-from-host.sh  │
│ • crash-injector/       │
│                         │
└────────────┬────────────┘
             │ oc exec / SSH
             ↓
┌─────────────────────────┐
│ Virt-Launcher Pod       │  Kubernetes: manages the VM
│ (or KVM Host)           │
│                         │
│ • virsh commands        │
│ • VM lifecycle mgmt     │
│ • Evidence extraction   │
│                         │
└────────────┬────────────┘
             │ qemu-guest-agent
             ↓
┌─────────────────────────┐
│ Windows VM (Guest)      │  Test target: configuration and monitoring
│                         │
│ • configure-dumps.ps1   │
│ • clear-dumps.ps1       │
│ • NotMyFault.exe        │
│ (crash trigger)         │
└─────────────────────────┘
```

### CI Operator (CI/CD System or Orchestration Host)

Scripts executed on the orchestration layer to coordinate the entire test pipeline:

- `watch-crash.sh` — natural BSOD detection with automatic escalation
- `guest-agent.py` — tunnel PowerShell commands into the VM
- `collect-from-host.sh` — coordinate detection → capture → analysis
- `src/scripts/crash-injector/` — intentional crash triggers

**Execution context:**
- **KubeVirt:** Via `oc exec` into virt-launcher pod
- **KVM/libvirt:** Directly on the hypervisor host via SSH

---

### Virt-Launcher Pod (Kubernetes) or KVM Host

The hypervisor layer that manages the VM. Scripts here are invoked **indirectly** by the CI Operator:

- `virsh` commands (executed inside the pod or on the KVM host)
- VM lifecycle management (start, stop, snapshot)
- Evidence extraction from disk images
- Memory/screen capture

**Execution method:**
- **KubeVirt:** Inside the `virt-launcher-<vm>-*` pod
- **KVM/libvirt:** On the Linux host directly

---

### Windows VM (Guest)

PowerShell scripts **inside** the Windows guest for one-time configuration:

- `configure-dumps.ps1` — enable full crash dumps (CrashControl registry)
- `clear-dumps.ps1` — clear existing crash dumps before test
- NotMyFault.exe — optional crash trigger utility

**Execution context:**
- **KubeVirt:** Via qemu-guest-agent protocol (SSH not available)
- **KVM/libvirt:** Via SSH connection to Windows guest

---

## Testing Workflow: Commands by Layer

This section shows **exactly which commands run on each layer** during a complete test.

### Complete Test Sequence: Intentional Crash Injection

```
╔════════════════════════════════════════════════════════════════════════════╗
║                         INTENTIONAL CRASH INJECTION FLOW                   ║
╚════════════════════════════════════════════════════════════════════════════╝

PHASE 1: SETUP (One-Time)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator (Orchestration)  │
│  - Stage toolkit            │
│  - Configure dumps          │
│  - Setup NotMyFault injector│
└──────────────┬──────────────┘
               │ guest-agent.py psfile
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward via qemu-agent    │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [Setup Scripts Execute]     │
│  - Directories created       │
│  - Registry configured       │
│  - NotMyFault.exe installed  │
└──────────────────────────────┘

PHASE 2: CRASH TRIGGER (Per-Test)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Clear old dumps (optional)│
│  - Execute crash command     │
└──────────────┬──────────────┘
               │ guest-agent.py exec
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward crash trigger     │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [CRASH OCCURS]              │
│  notmyfaultc64.exe /crash    │
│  ↓ BSOD triggered (0x01)     │
│  ↓ MEMORY.DMP written        │
│  ↓ Agent unresponsive        │
└──────────────────────────────┘

PHASE 3: EVIDENCE COLLECTION (Offline)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Run host-tools extraction │
└──────────────┬──────────────┘
               │ libguestfs container
               ↓
┌──────────────────────────────┐
│ Disk Image (Offline Mount)   │
│  [Read-Only NTFS Access]     │
│  - Extract MEMORY.DMP        │
│  - Extract Minidump/*.dmp    │
│  - Extract System.evtx       │
│  - Extract Application.evtx  │
└──────────────┬───────────────┘
               │
               ↓
┌──────────────────────────────┐
│ Evidence Directory           │
│  ./evidence/                 │
│  ├── MEMORY.DMP              │
│  ├── Minidump/               │
│  ├── winevt/System.evtx      │
│  ├── winevt/Application.evtx │
│  └── evidence-summary.json   │
└──────────────────────────────┘
```

---

### Layer-by-Layer Commands

#### Layer 1: CI Operator (Operator Workstation)

**What runs:** Bash/Python orchestration scripts

**Location:** The operator workstation, CI/CD pipeline, or anywhere with `oc`/SSH access to cluster

**Commands executed at this layer:**

```bash
# Set these to match the target environment
export VM="<vm-name>"
export NS="<namespace>"

# 1. Setup: Stage toolkit on guest
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected output: [uploaded ...] [exit 0]

# 2. Setup: Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\bsod-detector\src\scripts\guest\configure-dumps.ps1'
# Expected output: Registry keys set, dump type configured

# 3. Prepare: Setup NotMyFault
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected output: [uploaded ...] notmyfaultc64.exe present: True

# 4. Action: Trigger crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected output: (timeout or error — guest has crashed, agent unresponsive)
# This is NORMAL and EXPECTED

# 5. Collect: Extract dumps offline
# Resolve disk image dynamically first (see "Resolving Disk Image Paths Dynamically" section)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected output: MEMORY.DMP extracted, minidumps extracted, JSON result

# 6. Verify: Check evidence
ls -lah ./evidence/dumps/
cat ./evidence/dumps/MEMORY.DMP | head -c 100
```

---

#### Layer 2: Virt-Launcher Pod (Kubernetes)

**What runs:** `virsh` commands and qemu-guest-agent forwarding

**Location:** Inside the `virt-launcher-<vm>-*` pod in the cluster

**Commands that run indirectly** (invoked by `guest-agent.py` on Layer 1):

```bash
# Set these to match the target environment
VM="<vm-name>"
NS="<namespace>"

# These are not executed directly by the operator — guest-agent.py handles this via oc exec
# Here is what happens inside the pod:

# Check VM is running
virsh -q domifaddr "$VM"
# Output: vnet0  52:54:00:12:34:56  ipv4  10.0.0.42/24

# Forward PowerShell command to guest agent
virsh qemu-agent-command "${NS}_${VM}" \
  '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\cmd.exe",...}}'
# Output: {"return":{"pid":1234}}

# Check guest agent status
virsh qemu-agent-command "${NS}_${VM}" '{"execute":"guest-ping"}'
# Output: (hangs or timeout if guest has crashed — EXPECTED)

# After crash: Stop the VM
virsh destroy "$VM"
# Output: Domain <vm-name> destroyed
```

**How to manually run these (for debugging):**

```bash
# SSH/exec into the pod
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
oc -n "$NS" exec -it $POD -- bash

# Inside pod, virsh commands can be run directly
virsh domifaddr "$VM"
virsh qemu-agent-command "${NS}_${VM}" '{"execute":"guest-ping"}'
virsh dumpxml "$VM" | grep disk  # Find disk path
```

---

#### Layer 3: Windows VM (Guest)

**What runs:** PowerShell scripts executed via guest-agent

**Location:** Inside the Windows guest VM

**Commands that execute** (via `GA_VM=... guest-agent.py exec`):

```powershell
# 1. Configure crash dumps (runs once)
C:\bsod-detector\src\scripts\guest\configure-dumps.ps1

# What it does:
#   - Sets HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\CrashControl
#   - AutoReboot = 0 (don't reboot after crash)
#   - CrashDumpEnabled = 1 (full kernel+user dump)
#   - DumpFile = C:\Windows\MEMORY.DMP
#   - MinidumpDir = C:\Windows\Minidump

# 2. Stage toolkit (runs once)
C:\bsod-detector\src\scripts\guest\clear-dumps.ps1

# What it does:
#   - Extracts bsod-src.zip
#   - Sets up crash-injector tools
#   - Verifies paths

# 3. Trigger crash
C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01

# What it does:
#   - Loads notmyfault driver
#   - Executes crash code 0x01 (IRQL_NOT_LESS_OR_EQUAL)
#   - Windows writes MEMORY.DMP while rebooting
#   - BUT: AutoReboot=0 means no reboot, stays at crash screen
#   - Guest becomes unresponsive to guest-agent queries
```

**Expected behavior:**

| Step | Expected | What to Check |
|------|----------|---------------|
| Setup toolkit | [exit 0] | `oc exec <pod> -- virsh qemu-agent-command ... '{"execute":"guest-ping"}'` returns immediately |
| Configure dumps | Registry set | Guest still responsive to ping |
| Setup NotMyFault | notmyfaultc64.exe present | `ls C:\Temp\nmf\` shows files |
| Trigger crash | **TIMEOUT** | This is EXPECTED — guest crashed, agent unresponsive |
| After crash | No response | `virsh qemu-agent-command` hangs/times out |

---

### Troubleshooting: What to Check at Each Layer

| Symptom | Check | Solution |
|---------|-------|----------|
| `guest-agent.py` hangs on setup | Pod exists and running | `oc get pod -n $NS \| grep virt-launcher` |
| Setup commands timeout | Guest agent responsive | `GA_VM=... guest-agent.py ping` |
| Crash trigger timeout | Expected if crash worked | Wait 30s, VM should be unresponsive |
| Can't extract dumps | Disk image readable | `ls -l /var/lib/libvirt/images/...qcow2` |
| MEMORY.DMP not found | AutoReboot setting | Verify `configure-dumps.ps1` ran successfully |

---

## guest-agent.py Reference

**What it does:** Tunnel PowerShell commands into the Windows guest via qemu-guest-agent.  
**Where it runs:** CI Operator layer (orchestration host or CI/CD pipeline).  
**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest.

### Setup Environment

```bash
export VM="<vm-name>"
export NS="<namespace>"

# Verify guest agent is responsive before running anything
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Output: (empty/immediate if responsive; timeout if guest unreachable)
```

### Subcommands

| Command | Purpose | Example |
|---------|---------|---------|
| `ping` | Check if guest agent is alive | `GA_VM=$VM GA_NS=$NS python3 ... ping` |
| `exec <program> [args]` | Run a command in guest | `GA_VM=$VM GA_NS=$NS python3 ... exec powershell -Command 'Get-Date'` |
| `psfile <script.ps1> [args]` | Upload and run PowerShell script | `GA_VM=$VM GA_NS=$NS python3 ... psfile src/scripts/guest/configure-dumps.ps1` |
| `put <local> <guest-path>` | Upload file to guest | `GA_VM=$VM GA_NS=$NS python3 ... put file.zip 'C:\Temp\file.zip'` |
| `get <guest-path> <local>` | Download file from guest | `GA_VM=$VM GA_NS=$NS python3 ... get 'C:\Windows\MEMORY.DMP' ./MEMORY.DMP` |

### Quick Reference

```bash
# ONE-TIME SETUP (run once per VM)
export VM="<vm-name>"
export NS="<namespace>"

# 1. Stage toolkit
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

# 2. Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

# 3. Setup crash trigger (if using NotMyFault)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1

# BEFORE EACH TEST
# 4. Clear old dumps (optional, for clean evidence)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

# AFTER CRASH
# 5. Extract evidence (guest is now offline/crashed)
# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
```

### Performance Considerations: guest-agent.py Slowness

**⚠️ Known Issue:** `guest-agent.py psfile` and `guest-agent.py exec` commands can be **very slow** (30-120+ seconds per command) due to:

1. **qemu-guest-agent overhead** — RPC communication through libvirt/KVM
2. **PowerShell startup time** — Even simple scripts take time to load
3. **Network latency** — oc exec → virt-launcher pod → virsh adds layers
4. **Guest system load** — Heavy I/O or high CPU makes responses slower

**Recommended Timeout Values:**
- `psfile <script>` — **120 seconds** (setup scripts can be slow)
- `exec <command>` — **60 seconds** (simpler commands are faster)
- Large file transfers (`put`, `get`) — **180+ seconds** (I/O bound)

**Optimization Tips:**
- ✅ Batch commands where possible (one large script vs. multiple small ones)
- ✅ Check `GA_VM=$VM GA_NS=$NS python3 ... ping` first (should return immediately)
- ✅ If `ping` hangs, the guest-agent is unresponsive — restart the VM
- ✅ For production, pre-stage setup scripts (stage-toolkit, configure-dumps) once during VM creation
- ✅ Use `host-tools/run.sh` for evidence extraction instead of guest-side collection (offline is faster)

**Debugging:**
```bash
# Check if guest-agent is reachable
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Expected: Returns immediately (empty output {})
# If it hangs: guest-agent is unresponsive

# Test with a simple command (60s timeout)
timeout 60 bash -c 'GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec powershell -NoProfile -Command "Write-Host done"'
# If this times out: guest may be under high load or unresponsive
```

---

## Integration: Detecting Externally-Triggered BSOD

**Scenario:** An external test operator generates a BSOD via an independent mechanism (not via our crash-injector). The BSOD Detector watches for the event, detects it, and captures evidence automatically.

### External Test Operator Responsibilities

1. **Pre-BSOD Setup** (one-time, before triggering crash):
   - Coordinate with CI Operator to confirm `configure-dumps.ps1` has been executed
   - Verify VM is ready to write full crash dumps (registry configured)
   - Note: AutoReboot=0 is critical — ensures guest stays at crash screen

2. **Generate BSOD**:
   - Trigger the crash using external mechanism (independent of this toolkit)
   - Windows writes crash dump to `C:\Windows\MEMORY.DMP`
   - Guest becomes unresponsive to network/agent

3. **Notify CI Operator**:
   - Inform CI Operator when BSOD has been triggered
   - Provide timestamp for correlation
   - CI Operator detects it automatically via `watch-crash.sh`

### CI Operator Responsibilities

```bash
export VM="<vm-name>"
export NS="<namespace>"

# Step 1: ONE-TIME GUEST SETUP (before external test operator triggers BSOD)
echo "=== Configuring guest for crash dump collection ==="
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

echo "Setup complete. Notify external test operator that VM is ready for BSOD."

# Step 2: START DETECTION WATCHER (before external operator triggers BSOD)
echo "=== Watching for externally-triggered BSOD (will block until detected or timeout) ==="
./src/scripts/host/watch-crash.sh \
  --provider kubevirt \
  --ns $NS \
  --vm $VM \
  --scenario natural \
  --out ./evidence \
  --duration 3600

# (This command will block until BSOD detected)
# External operator triggers crash while this is running
# Detector will automatically:
#   1. Capture screenshot at crash time
#   2. Capture raw VM memory
#   3. Stop the VM
#   4. Extract crash dumps offline via libguestfs

# Step 3: COLLECT & VERIFY RESULTS (after watch-crash.sh exits)
echo "=== Evidence collection complete ==="
ls -lah ./evidence/
cat ./evidence/evidence-summary.json | jq .
cat ./evidence/evidence-summary.json | jq .verdict
```

### Execution Flow

```
╔════════════════════════════════════════════════════════════════════════════╗
║                    EXTERNAL BSOD DETECTION & CAPTURE                       ║
╚════════════════════════════════════════════════════════════════════════════╝

External Operator               CI Operator                 VM (Guest)
     ┌─────────────┐            ┌─────────────┐          ┌──────────────┐
     │  PREPARE    │            │   SETUP     │          │   WAITING    │
     │ (Notify)    │────────→   │ configure   │   ┌─────→│    Ready     │
     │             │            │ dumps.ps1   │   │      │              │
     └─────────────┘            └─────────────┘   │      └──────────────┘
                                                   │
                                 ┌─────────────┐  │
                                 │  WATCH      │──┘
                                 │ watch-crash │
                                 │  (blocking)  │
                                 └──────┬──────┘
                                        │ polls
                                        │ guest-agent every 5s
                                        ├──────────────────→

     ┌──────────┐                                          ┌──────────────┐
     │ TRIGGER  │──→ (external mechanism) ──→ [Crash!] ──→│  BSOD        │
     │  BSOD    │                                         │ Writes MEMORY │
     └──────────┘                                         │ Agent DOWN    │
                                                          └──────┬───────┘
                                 ┌──────────────┐                │
                                 │ DETECTS ✅   │← ─ ─ ─ ─ ─ ─ ┘
                                 │ Unresponsive │
                                 └───────┬──────┘
                                        ┌┴──────────────────────┐
                                        │  ESCALATE:             │
                                        │  1. Screenshot         │
                                        │  2. Memory capture     │
                                        │  3. Stop VM            │
                                        │  4. Extract offline    │
                                        └───────┬────────────────┘
                                                ↓
                                    ┌──────────────────┐
                                    │ ./evidence/      │
     ┌──────────┐                  │  ├─ MEMORY.DMP   │
     │ NOTIFIED │←─────────────────│  ├─ Minidumps    │
     │  Done    │                  │  ├─ Event logs   │
     └──────────┘                  │  └─ JSON summary │
                                    └──────────────────┘
                                         ✅ Analysis Ready
```

### Coordination Checklist

**Pre-BSOD Coordination:**
1. ✅ CI Operator confirms `configure-dumps.ps1` executed successfully
2. ✅ External Test Operator confirms readiness to trigger crash
3. ✅ CI Operator initiates `watch-crash.sh`
4. ✅ Allow ~10 seconds for watch initialization

**During BSOD Trigger:**
5. ✅ External Test Operator triggers crash via designated mechanism
6. ✅ Ensure AutoReboot=0 prevents automatic VM restart
7. ✅ Guest unresponsiveness is expected behavior

**Post-BSOD Collection:**
8. ✅ External Test Operator notifies CI Operator upon crash completion
9. ✅ CI Operator's `watch-crash.sh` detects event automatically
10. ✅ Evidence collection to `./evidence/` executes automatically

### Troubleshooting External Integration

| Issue | Cause | Resolution |
|-------|-------|-----------|
| Detector doesn't detect externally-triggered BSOD | Guest agent still responsive | Verify `configure-dumps.ps1` disabled AutoReboot |
| MEMORY.DMP not found after crash | Dump not written before VM stopped | Increase detection timeout or verify crash actually occurred |
| Evidence directory empty | Guest agent responsive despite crash | Check if external mechanism actually triggered proper BSOD |
| Timeout waiting for crash | External operator hasn't triggered yet | Verify communication and timing with external operator |

---

## Resolving Disk Image Paths Dynamically

Instead of hardcoding disk image paths like `/var/lib/libvirt/images/<vm-name>.qcow2`, the disk path can be extracted dynamically from the running VM.

### Why Dynamic Resolution?

✅ Works across different hypervisors (KVM/libvirt and KubeVirt)  
✅ Supports custom storage paths  
✅ Makes scripts portable and reusable  
✅ Doesn't depend on naming conventions  

### How to Extract the Disk Path

**For KubeVirt VMs**, query virsh inside the virt-launcher pod:

```bash
# Variables
VM="<vm-name>"
NS="<namespace>"
DOM_NAME="${NS}_${VM}"

# 1. Find the virt-launcher pod
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)

# 2. Extract disk path using virsh domblklist
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "$DOM_NAME" | grep vda | awk '{print $2}')

# 3. Use the resolved path
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

**What each step does:**

1. **Find the pod:** Queries KubeVirt for the virt-launcher pod managing the target VM
2. **Extract disk:** Uses `virsh domblklist` to list block devices (returns path like `/var/lib/libvirt/images/...qcow2`)
3. **Use path:** Pass to `host-tools/run.sh` for offline evidence extraction

### In the Test Script

The complete test script (`bsod-detector-test.sh`) automatically does this:

```bash
# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above

# Use resolved path for evidence extraction
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

This eliminates manual disk path lookups and makes the script work on any VM in any namespace.

---

## Test Scenarios

The toolkit supports **3 ways to trigger and capture a BSOD**:

### Scenario 1: Intentional Crash Injection (NotMyFault)

**When to use:** Controlled testing with a known crash code via NotMyFault.exe.

**CI Operator runs:**
```bash
export VM="<vm-name>"
export NS="<namespace>"
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=0 set, dump type configured

# 3. Setup NotMyFault injector (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected: notmyfaultc64.exe present in C:\Temp\nmf\

# PER-TEST SEQUENCE

# 4. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 5. Trigger the crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected: TIMEOUT (guest has crashed, this is expected)

# 6. Extract evidence offline (guest is now stopped)
# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result
```

**What happens inside the VM:**
- configure-dumps.ps1 sets registry (AutoReboot=0, dump type to kernel+user)
- NotMyFault.exe executes crash code 0x01
- Windows writes MEMORY.DMP to C:\Windows\

**What the CI Operator captures:**
- BSOD screenshot
- Raw VM memory (optional)
- MEMORY.DMP + minidumps (offline extraction)
- Event logs (.evtx files)

---

### Scenario 2: Natural BSOD Detection (Watch-Crash)

**When to use:** Detecting a real, unplanned BSOD triggered externally (by external test operator).

**CI Operator runs:**
```bash
export VM="<vm-name>"
export NS="<namespace>"
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=0 set, dump type configured

# PER-TEST SEQUENCE

# 3. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 4. Start watching for natural BSOD (blocks until detected)
./src/scripts/host/watch-crash.sh \
  --ns $NS \
  --vm $VM \
  --out ./evidence \
  --interval 5 \
  --miss 3 \
  --reboot-wait 300
# This will block until BSOD detected or timeout occurs
# External Test Operator triggers crash while this is running
# watch-crash.sh automatically:
#   1. Detects guest unresponsiveness
#   2. Captures screenshot
#   3. Captures host-side signals
#   4. Extracts evidence offline
#   5. Generates evidence-summary.json
```

**What happens during monitoring:**
- Continuously polls qemu-guest-agent health
- Detects BSOD/freeze when guest stops responding
- Automatically captures screenshot at crash moment
- Records host-side signals (TLB-flush, split-lock)
- Waits for guest reboot or detects hard-freeze

**What the CI Operator gets:**
- Automatic screenshot at crash time
- Host kernel log analysis
- Crash dump files (if guest reboots)
- Event log evidence
- Evidence summary JSON with crash metadata

See **[docs/natural-bsod-workflow.md](docs/natural-bsod-workflow.md)** for detailed runbook.

---

### Scenario 3: Offline Dump Extraction

**When to use:** VM is already crashed/frozen/stopped; extract evidence from disk image without VM interaction.

**CI Operator runs:**
```bash
# Set these to match the target environment
VM="<vm-name>"
NS="<namespace>"

# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above

# Method 1: Direct extraction via host-tools
./host-tools/run.sh \
  --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result

# Method 2: Via collect-offline orchestrator
./src/scripts/host/collect-offline.sh \
  --vm "$VM" \
  --out ./evidence
# Expected: Full evidence bundle with analysis
```

**What happens:**
- ✅ Mounts disk image via libguestfs (read-only)
- ✅ Extracts MEMORY.DMP and minidumps from C:\Windows\
- ✅ Extracts event logs (.evtx files)
- ✅ Parses dump headers for crash analysis
- ✅ No VM interaction or reboots needed

**Useful for:**
- Unbootable/unconfigurable guests
- Frozen VMs (cannot reach via guest-agent)
- Post-mortem analysis of existing disk images
- Recovery from hard-freeze states

---

## Execution Environments

### KubeVirt (OpenShift Cluster)

**Use when:** Testing in Kubernetes/OpenShift environment.

**CI Operator location:** The operator workstation or CI/CD pipeline  
**Command pattern:**
```bash
GA_VM=<vm-name> GA_NS=<namespace> python3 src/scripts/host/guest-agent.py <subcommand>
oc -n <namespace> exec <virt-launcher-pod> -- virsh <cmd>
```

**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest

**Example (from earlier):**
```bash
export VM="<vm-name>"
export NS="<namespace>"

# Trigger crash injection
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kubevirt --ns $NS --vm $VM --out ./evidence
```

---

### KVM/libvirt (Local Host)

**Use when:** Testing locally on KVM/libvirt infrastructure.

**CI Operator location:** The KVM host itself  
**Command pattern:**
```bash
export VM_NAME=bsod-test
export LIBVIRT_DEFAULT_URI=qemu:///system

src/scripts/host/guest-ssh.sh -c '<PowerShell command>'
# For disk path, use: virsh domblklist <vm> | grep vda | awk '{print $2}'
# or the dynamic resolution pattern (see "Resolving Disk Image Paths Dynamically" section)
./host-tools/run.sh --disk <resolved-disk-image> --out ./output
```

**Transport:** SSH to Windows guest or `virsh` on the host

**Example (local testing):**
```bash
export VM_NAME=bsod-test

# Trigger crash injection
src/scripts/host/guest-ssh.sh -f src/scripts/crash-injector/setup-notmyfault.ps1
src/scripts/host/guest-ssh.sh -c 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kvm --vm $VM_NAME --out ./evidence

# Or extract from offline image directly
# Resolve disk path: virsh domblklist $VM_NAME | grep vda | awk '{print $2}'
DISK_IMAGE=$(virsh domblklist $VM_NAME | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./output
```

---

## Conventions

### Scripts as tooling

Deterministic operations live in scripts with clear stdin/stdout contracts.

- **Scripts produce facts; humans make decisions.** Data collection, parsing dump files, reading event logs, and formatting output belong in scripts. Interpreting a crash or deciding how to act on it is a human call.
- `src/scripts/` contains guest collection and configuration scripts. Host-side collectors (such as `collect-host-signals.sh`) also live here when they consume `src/data/` lookups and follow the same output contract. Each collector script does one thing and emits exactly one JSON object to stdout so downstream steps can consume it with `jq` or `json.loads()`. Helper scripts like `capture-vm-screen.sh` that produce file artifacts instead of JSON are excluded from this contract.
- Every script is documented in [`src/scripts/README.md`](src/scripts/README.md): what it does, its inputs, and its output shape.
- **No hardcoded duplicated data.** Bug-check code tables, driver mappings, and log source names come from a single source-of-truth file that scripts read; never copy the same lookup into multiple scripts.

### Style

- Windows-first. Scripts are PowerShell (`.ps1`) unless there is a reason to use another language; note the requirement at the top of each script.
- Keep functions small and testable. Fail loudly with clear error messages.
- Never require interactive input in a script that may run unattended after a crash.

## Quick start

```bash
# Run the unit test suite (no VM needed):
cd apps/bsod-detector && bash test/run-tests.sh

# Intentional BSOD — fully automated (KubeVirt/RHOV):
bash src/scripts/crash-injector/trigger-bsod-intentional.sh
# Custom crash type: bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x08

# Natural crash watcher (KubeVirt/RHOV):
bash src/scripts/host/watch-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 \
  --out ./evidence --interval 5 --miss 2

# Hard freeze recovery (when guest won't reboot):
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 --out ./evidence/recovery

# Collect evidence offline after a crash:
./src/scripts/host/collect-offline.sh --vm bsod-test --out ./output/evidence
```

See [**docs/integration.md**](docs/integration.md) for CI/CD patterns, JSON
contracts, and agentic usage.

---

## New Scripts (2026-09-24)

### `src/scripts/crash-injector/trigger-bsod-intentional.sh`

Fully automated end-to-end intentional BSOD trigger for KubeVirt/RHOV. Handles
the complete workflow from cleanup through evidence collection.

**Key design decisions:**
- **STEP 0** — deletes all BSOD/dump files from previous runs on host + guest
  (including `MEMORY.DMP` which must be gone before triggering or Windows writes
  only a partial differential dump — fast but incomplete)
- **STEP 0d** — runs `configure-dumps.ps1` and verifies `matchesRecommended:true`;
  dies if `rebootRequired:true` (settings won't apply until reboot)
- **STEP 6** — fires `notmyfaultc64.exe /crash <type>` as a **background process**;
  the `exec` call never returns when guest crashes (virsh blocks on dead QGA socket),
  so detection uses an independent ping loop instead
- **STEP 7** — polls ping every 5s; waits for DOWN (crash) then UP (reboot); retries
  the entire trigger if no crash is confirmed within 10 minutes
- **STEP 8** — verifies a fresh minidump was written on guest post-reboot; warns if
  dump is missing (indicates dump config problem)

```
STEP 0  Delete dump files from previous runs + configure-dumps.ps1
STEP 1  Verify watch-crash.sh + guest-agent.py present
STEP 2  Guest online re-verify
STEP 2b VM status snapshot + last 5 Windows events
STEP 3  NotMyFault confirmed
STEP 4  Create ./evidence/
STEP 5  Start watch-crash.sh in background (PID tracked)
STEP 6  Fire notmyfaultc64.exe /crash <type> in background
STEP 7  Poll ping: wait for DOWN (crash confirmed) → UP (reboot complete)
STEP 8  Final online check + verify fresh minidump on guest
STEP 9  Wait 180s for watch-crash.sh evidence collection
STEP 10 Terminate watch-crash.sh if still running
STEP 11 Report results + print evidence-summary.json
```

**Usage:**
```bash
# Default crash type 0x01 (High IRQL → 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL)
bash src/scripts/crash-injector/trigger-bsod-intentional.sh

# Other crash types
bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x08  # double free
bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x09  # HAL timer watchdog
```

**Crash types (`notmyfaultc64.exe /crash <type>`):**

| Type | Name | Bug Check |
|------|------|-----------|
| `0x01` | High IRQL fault (kernel) | `0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL` |
| `0x02` | Buffer overflow | `0xD1` |
| `0x03` | Code overwrite | various |
| `0x04` | Stack trash | various |
| `0x06` | Stack overflow | `0x7F` |
| `0x07` | Hardcoded breakpoint | `0x80` |
| `0x08` | Double free | `0xC5` |
| `0x09` | HAL timer watchdog | `0x101` |

**Configuration (top of script):**
```bash
VM_NAME="win2022-vm-hjoshi1"   # target VM
NAMESPACE="windows-bsod"       # KubeVirt namespace
WATCH_CRASH_TIMEOUT=1800       # 30 min watcher timeout
REBOOT_WAIT=300                # 5 min per crash detection attempt
COLLECTION_WAIT=180            # 3 min evidence collection wait
```

---

### `src/scripts/host/recover-natural-crash.sh`

Evidence recovery for a hard-frozen VM — when `watch-crash.sh` reports
`hardFreeze:true` and the guest agent never returns.

Runs two parallel recovery paths:

**PATH 1 — `virsh dump --memory-only`**
Captures live QEMU/ELF memory image via `oc exec` into the virt-launcher pod.
Immediate; does not require powering off the VM. Output is NOT a Windows crash
dump — use `volatility3` to analyze.

**PATH 2 — ODF VolumeSnapshot → libguestfs pod**
1. Takes a CSI `VolumeSnapshot` of the guest PVC (`win2022-dv-hjoshi1`) via
   `ocs-storagecluster-rbdplugin-snapclass` — non-destructive, VM stays running
2. Creates a recovery PVC from the snapshot
3. Launches a libguestfs pod mounting the PVC read-only
4. Runs `virt-copy-out` to extract `MEMORY.DMP` + `Minidump\*.dmp`
5. Runs `parse-dump-header.sh` offline on extracted dumps
6. Cleans up: deletes snapshot, recovery PVC, recovery pod

```bash
# Full recovery (both paths)
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 --out ./evidence/recovery

# PATH 1 only (fast ELF dump)
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 \
  --out ./evidence/recovery --path1-only

# PATH 2 only (Windows dump via ODF snapshot)
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 \
  --out ./evidence/recovery --path2-only
```

**Output:**
```
evidence/recovery/
├── qemu-memory.dump         PATH 1: QEMU/ELF (volatility3)
├── MEMORY.DMP               PATH 2: Windows kernel dump (WinDbg/parse-dump-header.sh)
├── Minidump/*.dmp           PATH 2: Windows minidumps
├── parse-dump-header.json   bug check code + parameters
├── host-signals.json        split-lock detection, Hyper-V features
├── dom.xml                  VM domain XML at recovery time
├── kern.log                 worker node kernel log
└── recovery-summary.json    master recovery report
```

**When to call it:**
```bash
# After watch-crash.sh reports hardFreeze
if jq -e '.hardFreeze == true' ./evidence/evidence-summary.json >/dev/null 2>&1; then
  bash src/scripts/host/recover-natural-crash.sh \
    --ns windows-bsod --vm win2022-vm-hjoshi1 \
    --out ./evidence/recovery
fi
```

---

### `watch-crash.sh` — Fixes Applied (2026-09-24)

Two bugs fixed that caused crash detection to fail silently:

1. **`ping_ok` timeout** — now uses `timeout 10 python3 guest-agent.py ping`.
   Without this, if the guest crashes while virsh is mid-call, the orphaned QGA
   socket blocks for virsh's full 300s internal timeout. The missed-ping counter
   never increments and the crash is missed entirely.

2. **`powercfg` keep-awake exec** — now wrapped with `timeout 15`. A crash
   immediately after watcher startup would block this exec for 5 minutes before
   the poll loop even starts.

---

### `image/container/bsod-detector/` — Updated Container Image

The existing Dockerfile was extended to support three modes via the `MODE`
environment variable. Nothing is hardcoded — the same image works for any VM
in any cluster.

| Mode | Script | Use case |
|------|--------|----------|
| `watch` (default) | `watch-crash.sh` | Continuous natural crash detection |
| `recover` | `recover-natural-crash.sh` | Hard-freeze evidence recovery |
| `extract` | `extract-dump` | Original offline libguestfs dump pull |

Key env vars (all have defaults except `GA_VM` / `GA_NS`):

| Variable | Default | Description |
|----------|---------|-------------|
| `GA_VM` | required | KubeVirt VM name |
| `GA_NS` | required | Kubernetes namespace |
| `WATCH_INTERVAL` | `5` | QGA poll interval (seconds) |
| `WATCH_MISS` | `2` | Missed pings before crash declared |
| `WATCH_REBOOT_WAIT` | `300` | Seconds to wait for reboot |
| `EVIDENCE_DIR` | `/evidence` | Output directory |

```bash
# Watch a VM (natural crash detection)
podman run --rm -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
  -v ./evidence:/evidence quay.io/redhatqe/bsod-detector:latest

# Hard-freeze recovery
podman run --rm -e MODE=recover \
  -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
  -v ./evidence:/evidence quay.io/redhatqe/bsod-detector:latest

# Offline dump extraction (original behaviour unchanged)
podman run --rm -e MODE=extract \
  -v /path/to/guest.qcow2:/disk.qcow2:ro -v ./out:/out \
  quay.io/redhatqe/bsod-detector:latest --disk /disk.qcow2 --out /out

# Build
make -C image/container/bsod-detector build
```

---

## Hard Freeze Recovery Strategy

When the guest BSODs but does not reboot (`hardFreeze:true`), three options:

| Method | Tool | Format | Notes |
|--------|------|--------|-------|
| `virsh dump --memory-only` | `recover-natural-crash.sh --path1-only` | QEMU/ELF | Immediate; needs `volatility3` |
| ODF VolumeSnapshot → libguestfs | `recover-natural-crash.sh --path2-only` | Windows MEMORY.DMP | Non-destructive; real Windows dump |
| S3 / object storage | External agent (pre-crash) | Any | Pre-crash event logs only; agent dead during freeze |

S3 shipping cannot capture `MEMORY.DMP` in real-time — Windows writes the dump
after the kernel stops, so no agent can ship it mid-crash. Use S3 for
pre-crash event forwarding and post-reboot startup shipping.

---

## Layout

```
apps/bsod-detector/
├── src/
│   ├── scripts/
│   │   ├── host/                         # Host-side (Bash/Python)
│   │   │   ├── backends/                 # KVM/KubeVirt backend abstraction
│   │   │   ├── watch-crash.sh            # Natural crash detector (primary entry point)
│   │   │   ├── recover-natural-crash.sh  # Hard-freeze evidence recovery (NEW)
│   │   │   ├── guest-agent.py            # QGA bridge (all guest comms)
│   │   │   ├── collect-from-host.sh      # libvirt-native dump recovery
│   │   │   ├── collect-host-signals.sh   # Host kernel log + Hyper-V analysis
│   │   │   ├── parse-dump-header.sh      # Offline Windows dump header parser
│   │   │   ├── collect-offline.sh        # Full offline collection orchestrator
│   │   │   ├── capture-vm-screen.sh      # Framebuffer burst capture
│   │   │   ├── extract-evtx.py           # Offline .evtx event log parser
│   │   │   └── vmctl.sh                  # VM lifecycle control
│   │   ├── guest/                        # Guest-side (PowerShell) — one-time config
│   │   │   ├── configure-dumps.ps1       # CrashControl registry settings
│   │   │   ├── clear-dumps.ps1           # Delete existing dumps
│   │   │   └── stage-toolkit.ps1         # Create guest directory structure
│   │   └── crash-injector/               # Intentional BSOD triggers (The Pitcher)
│   │       ├── trigger-bsod-intentional.sh  # Automated KubeVirt crash + collection (NEW)
│   │       ├── trigger-bsod.ps1          # Driver-free crash (NtRaiseHardError)
│   │       ├── setup-notmyfault.ps1      # Download NotMyFault to guest
│   │       ├── sweep-crashme.sh          # Sweep all 19 crash types
│   │       └── sweep-chaos.sh            # Chaos crash sweep
│   └── data/                             # Source-of-truth lookups
│       ├── bugcheck-codes.json           # All Windows bug check codes
│       └── host-signals.json             # Split-lock patterns + Hyper-V features
├── host-tools/                           # Containerised guestfs extraction
├── test/                                 # bats unit tests
├── docs/                                 # Architecture, integration, tool selection
├── evidence/                             # Runtime output (gitignored)
└── .gitignore
```

## Notes

- BSOD dumps may contain host-identifying data. Never commit dumps to git.
  `evidence/` is in `.gitignore`.
- `MEMORY.DMP` must be deleted before each intentional crash run —
  if it exists, Windows writes only changed pages (fast but partial).
  `trigger-bsod-intentional.sh` STEP 0 handles this and verifies deletion.
- `configure-dumps.ps1` must be run before any crash. If it returns
  `rebootRequired:true`, reboot the VM before triggering — otherwise
  dump settings are not active and no dump will be written.
- The QGA ping mechanism (not ICMP) is used for all guest health checks.
  QGA dies instantly on kernel panic; ICMP can stay alive for several seconds
  after a BSOD, making it unreliable for crash detection.
