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

Keep it simple. Prefer a small, well-defined tool over a broad framework.

---

## Deployment Model: Where Scripts Run

BSOD detection is a **3-tier distributed system**:

```
┌─────────────────────────┐
│   CI Operator           │  Orchestration host: manages test execution
│   (Local/CI Agent)      │
│                         │
│ • stakeout.sh           │
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
│ • stage-toolkit.ps1     │
│ • NotMyFault.exe        │
│ (crash trigger)         │
└─────────────────────────┘
```

### CI Operator (CI/CD System or Orchestration Host)

Scripts executed on the orchestration layer to coordinate the entire test pipeline:

- `stakeout.sh` — main orchestrator (watch, preflight, collect)
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
- `stage-toolkit.ps1` — extract BSOD detector toolkit
- NotMyFault.exe — optional crash trigger utility

**Execution context:**
- **KubeVirt:** Via qemu-guest-agent protocol (SSH not available)
- **KVM/libvirt:** Via SSH connection to Windows guest

---

## Testing Workflow: Commands by Layer

This section shows **exactly which commands run on each layer** during a complete test.

### Complete Test Sequence: Intentional Crash Injection

```
CI Operator (Your Laptop)
    ↓ runs: GA_VM=... GA_NS=... python3 src/scripts/host/guest-agent.py psfile setup-notmyfault.ps1
    ↓
Virt-Launcher Pod
    ↓ forwards to: virsh qemu-agent-command <domain> '<qmp-exec>' (inside pod)
    ↓
Windows VM (Guest)
    ↓ executes: setup-notmyfault.ps1 (via guest-agent)
    ↓ downloads: NotMyFault.exe → C:\Temp\nmf\
    ↓
    ← returns: Setup complete, notmyfaultc64.exe present
    ↓
CI Operator triggers crash
    ↓ runs: GA_VM=... GA_NS=... python3 src/scripts/host/guest-agent.py exec \
            powershell -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
    ↓
Virt-Launcher Pod
    ↓ forwards to: virsh qemu-agent-command <domain> '<qmp-exec>' (inside pod)
    ↓
Windows VM (Guest)
    ↓ executes: NotMyFault.exe /crash 0x01
    ↓ bugcheck: Windows BSOD with code 0x01
    ↓ dump: Writes MEMORY.DMP to C:\Windows\
    ↓ (Guest becomes unresponsive)
    ↓
Virt-Launcher Pod
    ↓ detects: Guest agent no longer responding
    ↓ auto-stops VM (via stakeout.sh or manual)
    ↓
CI Operator extracts evidence
    ↓ runs: ./host-tools/run.sh --disk <qcow2> --out ./evidence/dumps
    ↓ (libguestfs container mounts disk read-only)
    ↓
Disk Image (Offline)
    ↓ virt-copy-out extracts: MEMORY.DMP, Minidump/*.dmp, System.evtx, Application.evtx
    ↓
CI Operator collects results
    ↓ results in: ./evidence/ directory
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
  src/scripts/guest/stage-toolkit.ps1
# Expected output: [uploaded ...] [exit 0]

# 2. Setup: Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\bsod-detector\src\scripts\guest\configure-dumps.ps1'
# Expected output: Registry keys set, dump type configured

# 3. Prepare: Setup NotMyFault
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/host/crash-injector/setup-notmyfault.ps1
# Expected output: [uploaded ...] notmyfaultc64.exe present: True

# 4. Action: Trigger crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected output: (timeout or error — guest has crashed, agent unresponsive)
# This is NORMAL and EXPECTED

# 5. Collect: Extract dumps offline
./host-tools/run.sh --disk /var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2 \
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
#   - AutoReboot = 0 (don't reboot after crash)
#   - CrashDumpEnabled = 1 (full kernel+user dump)
#   - DumpFile = C:\Windows\MEMORY.DMP
#   - MinidumpDir = C:\Windows\Minidump

# 2. Stage toolkit (runs once)
C:\bsod-detector\src\scripts\guest\stage-toolkit.ps1

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
# One-time setup (run once per VM)
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

# 2. Stage BSOD toolkit
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

# 3. Setup crash trigger (if using NotMyFault injector)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/host/crash-injector/setup-notmyfault.ps1

# After external BSOD generation is complete:
# 4. Extract evidence (guest is now offline/crashed)
./host-tools/run.sh --disk /var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2 \
  --out ./evidence/dumps
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
   - CI Operator detects it automatically via `stakeout.sh watch`

### CI Operator Responsibilities

```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Step 1: ONE-TIME GUEST SETUP (before external test operator triggers BSOD)
echo "=== Configuring guest for crash dump collection ==="
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

echo "Setup complete. Notify external test operator that VM is ready for BSOD."

# Step 2: START DETECTION WATCHER (before external operator triggers BSOD)
echo "=== Watching for externally-triggered BSOD (will block until detected or timeout) ==="
./src/scripts/host/stakeout.sh watch \
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

# Step 3: COLLECT & VERIFY RESULTS (after stakeout.sh exits)
echo "=== Evidence collection complete ==="
ls -lah ./evidence/
cat ./evidence/evidence-summary.json | jq .
cat ./evidence/stakeout-summary.json | jq .verdict
```

### Execution Flow

```
External Test Operator             CI Operator              VM (Guest)
         │                                │                       │
         │ Prepares BSOD trigger         │                       │
         │                        ↓      │                       │
         │ (notifies ready)  ←────────→ stakeout.sh watch ◀─ polls guest agent
         │                               │                       │
         │ Triggers BSOD              (watching, waiting)        │
         │ (external mechanism)         │                       │
         └──────────────────────────→  │                       │
                                        │                       ↓
                                        │                    Guest crashes
                                        │                    Writes MEMORY.DMP
                                        │                    to C:\Windows\
                                        │                       │
         │                              ← detects crash ──────→ Agent unresponsive
         │                              │                       │
         │ (notifies done)              │ stakeout escalates:
         └──────────────────→           │ 1. Screenshots
                                        │ 2. Captures memory
                                        │ 3. Stops VM
                                        │ 4. Extracts dumps (offline)
                                        │
                                        ↓
                                   ./evidence/ populated
                                   ✅ Analysis ready
```

### Coordination Checklist

**Pre-BSOD Coordination:**
1. ✅ CI Operator confirms `configure-dumps.ps1` executed successfully
2. ✅ External Test Operator confirms readiness to trigger crash
3. ✅ CI Operator initiates `stakeout.sh watch`
4. ✅ Allow ~10 seconds for watch initialization

**During BSOD Trigger:**
5. ✅ External Test Operator triggers crash via designated mechanism
6. ✅ Ensure AutoReboot=0 prevents automatic VM restart
7. ✅ Guest unresponsiveness is expected behavior

**Post-BSOD Collection:**
8. ✅ External Test Operator notifies CI Operator upon crash completion
9. ✅ CI Operator's `stakeout.sh watch` detects event automatically
10. ✅ Evidence collection to `./evidence/` executes automatically

### Troubleshooting External Integration

| Issue | Cause | Resolution |
|-------|-------|-----------|
| Detector doesn't detect externally-triggered BSOD | Guest agent still responsive | Verify `configure-dumps.ps1` disabled AutoReboot |
| MEMORY.DMP not found after crash | Dump not written before VM stopped | Increase detection timeout or verify crash actually occurred |
| Evidence directory empty | Guest agent responsive despite crash | Check if external mechanism actually triggered proper BSOD |
| Timeout waiting for crash | External operator hasn't triggered yet | Verify communication and timing with external operator |

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

# 1. Configure crash dumps (one-time setup)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=0 set

# 2. Clear existing dumps (optional, to isolate new crash)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared

# 3. Setup NotMyFault on guest
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/host/crash-injector/setup-notmyfault.ps1
# Expected: notmyfaultc64.exe present

# 4. Trigger the crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected: TIMEOUT (guest has crashed, this is expected)

# 5. Extract evidence offline (guest is now stopped)
DISK_IMAGE=/var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2
./host-tools/run.sh --disk $DISK_IMAGE --out ./evidence/dumps
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
export VM=win2022-vm-hjoshi1
export NS=windows-bsod
export KUBECONFIG=<path-to-kubeconfig>

# 1. Configure crash dumps (one-time setup)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=0 set

# 2. Clear existing dumps (optional, to isolate new crash)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared

# 3. Start watching for natural BSOD (blocks until detected)
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
export DISK_IMAGE=/var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2

# Method 1: Direct extraction via host-tools
./host-tools/run.sh \
  --disk $DISK_IMAGE \
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
  src/scripts/host/crash-injector/setup-notmyfault.ps1
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/stakeout.sh watch \
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
./host-tools/run.sh --disk /var/lib/libvirt/images/<vm>.qcow2 --out ./output
```

**Transport:** SSH to Windows guest or `virsh` on the host

**Example (local testing):**
```bash
export VM_NAME=bsod-test

# Trigger crash injection
src/scripts/host/guest-ssh.sh -f src/scripts/crash-injector/setup-notmyfault.ps1
src/scripts/host/guest-ssh.sh -c 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/stakeout.sh watch \
  --provider kvm --vm $VM_NAME --out ./evidence

# Or extract from offline image directly
./host-tools/run.sh --disk /var/lib/libvirt/images/bsod-test.qcow2 --out ./output
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
