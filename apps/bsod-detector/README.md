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

Keep it simple. Prefer a small, well-defined tool over a broad framework.

---

## Deployment Model: Where Scripts Run

BSOD detection is a **3-tier distributed system**:

```
┌─────────────────────────┐
│   CI Operator           │  Your machine: orchestrates the test
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
│ Windows VM (Guest)      │  Inside the VM: one-time setup
│                         │
│ • configure-dumps.ps1   │
│ • stage-toolkit.ps1     │
│ • NotMyFault.exe        │
│ (crash trigger)         │
└─────────────────────────┘
```

### CI Operator (CI/CD System or Your Machine)

Scripts that **you run** to orchestrate the entire test pipeline:

- `stakeout.sh` — main orchestrator (watch, preflight, collect)
- `guest-agent.py` — tunnel PowerShell commands into the VM
- `collect-from-host.sh` — coordinate detection → capture → analysis
- `src/scripts/crash-injector/` — intentional crash triggers

**Execution method:**
- **KubeVirt:** Via `oc exec` into virt-launcher pod
- **KVM/libvirt:** Via SSH to the host

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

**Execution method:**
- **KubeVirt:** Via qemu-guest-agent (no SSH)
- **KVM/libvirt:** Via SSH to Windows guest

---

## Test Scenarios

The toolkit supports **3 ways to trigger and capture a BSOD**:

### Scenario 1: Intentional Crash Injection (NotMyFault)

**When to use:** Controlled testing with a known crash code.

**CI Operator runs:**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Preflight check
./src/scripts/host/stakeout.sh preflight \
  --provider kubevirt --ns $NS --vm $VM \
  --scenario any --out ./evidence

# 2. Stage toolkit (one-time)
mkdir -p bsod-src && zip -r bsod-src.zip \
  src/scripts/guest/ src/scripts/lib/Common.ps1 \
  src/data/bugcheck-codes.json src/data/guest/
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py put \
  bsod-src.zip 'C:\Windows\Temp\bsod-src.zip'
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

# 3. Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\bsod-detector\src\scripts\guest\configure-dumps.ps1'

# 4. Setup NotMyFault on guest
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/host/crash-injector/setup-notmyfault.ps1

# 5. Trigger the crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# 6. VM will crash; you can wait for offline extraction or run immediately
./host-tools/run.sh --disk /var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2 \
  --out ./evidence/dumps
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

### Scenario 2: Natural BSOD Detection (Stakeout)

**When to use:** Waiting for a real, unplanned BSOD to occur.

**CI Operator runs:**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Preflight check
./src/scripts/host/stakeout.sh preflight \
  --provider kubevirt --ns $NS --vm $VM \
  --scenario natural --out ./evidence

# 2. Watch for naturally occurring BSOD (blocks until crash detected)
./src/scripts/host/stakeout.sh watch \
  --provider kubevirt --ns $NS --vm $VM \
  --scenario natural --out ./evidence --duration 3600

# If hard-freeze detected, escalates to offline extraction automatically
```

**What happens inside the VM:**
- Runs as a long-lived watcher
- Polls guest agent for crash signals
- On BSOD detection, automatically stops VM and escalates

**What the CI Operator captures:**
- Automatic screenshot at crash time
- Automatic memory capture
- Offline dump extraction
- Evidence summary

See **[docs/natural-bsod-workflow.md](docs/natural-bsod-workflow.md)** for detailed runbook.

---

### Scenario 3: Offline Dump Extraction

**When to use:** VM is already crashed/frozen; you need to extract evidence without triggering a new crash.

**CI Operator runs:**
```bash
export DISK_IMAGE=/var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2

# Direct extraction (no VM interaction)
./host-tools/run.sh --disk $DISK_IMAGE --out ./evidence/dumps

# Or via orchestrator
./src/scripts/host/collect-offline.sh \
  --vm win2022-vm-hjoshi1 --out ./evidence
```

**What happens:**
- Mounts disk image via libguestfs (read-only)
- Extracts MEMORY.DMP and minidumps
- Parses .evtx event logs
- No VM interaction needed

**Useful for:**
- Unbootable guests
- Frozen VMs (cannot SSH/agent)
- Post-mortem analysis of existing images

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
