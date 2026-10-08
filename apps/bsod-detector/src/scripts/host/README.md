# Host Scripts

Scripts that run on the orchestration host (CI operator machine or laptop).

These scripts manage the full BSOD detection and artifact extraction pipeline orchestrated from outside the Kubernetes cluster.

## Script Overview

### `trigger-bsod-intentional.sh`

**Purpose**: Main orchestration entry point for intentional BSOD testing.

**Responsibilities**:
- Parse input parameters (crash type, VM name, namespace)
- Clean up leftover guestfish cache files from previous runs
- Validate evidence storage mount is accessible
- Call `preflight-rhov.sh` for environment validation
- Start `watch-crash.sh` in background (monitors VM)
- Inject intentional BSOD via NotMyFault crash trigger
- Wait for watcher to detect crash and extract artifacts
- Generate final evidence summary

**Environment Variables**:
- `GA_VM`: Target Windows VM name (default: `win2022-vm-hjoshi1`)
- `GA_NS`: Kubernetes namespace (default: `windows-bsod`)
- `BSOD_DET__EVIDENCE__DIR`: Evidence storage directory (default: `/mnt/persistent-bsod-evidence`)
- `BSOD_DET__SNAPSHOT__CLASS`: Storage snapshot class (default: `ocs-storagecluster-rbdplugin-snapclass`)
- `BSOD_DET__READY__TIMEOUT`: Watcher readiness timeout (default: 300s)
- `BSOD_DET__PREFLIGHT__TIMEOUT`: Preflight timeout (default: 300s)

**Output**:
- Run directory: `/mnt/persistent-bsod-evidence/{TIMESTAMP}-intentional-{PID}-{RANDOM}/`

**Example**:
```bash
GA_VM="win2022-vm-hjoshi1" GA_NS="windows-bsod" \
  ./trigger-bsod-intentional.sh 0x01
```

---

### `watch-crash.sh`

**Purpose**: Background BSOD detection and memory capture.

**Responsibilities**:
- Monitor VM for BSOD (poll vmi.status.guestOSInfo disappearance every 5s)
- Trigger `virtctl memory-dump` when BSOD detected
- Convert ELF dump to Windows PAGEDU64 format via `elf2dmp`
- Run volatility3 analysis (windows.info, crashinfo, driverscan, dumpfiles)
- Stop VM using `virtctl stop`
- Call `recover-natural-crash.sh` for offline artifact extraction
- Call `parse-dump-header.sh` to extract bugcheck code from dump
- Generate watcher logs and metadata

**Inputs**:
- Metadata file from `preflight-rhov.sh` (recoverymetadata.json)
- Output directory
- Expected BSOD detection timeout

**Output**:
- `vm-memory-windows.dmp` (16GB PAGEDU64 format dump)
- `vm-memory.elf.tar.gz` (compressed ELF dump)
- `volatility-*.txt` (volatility analysis results)
- `parse-dump-header.json` (bugcheck code extraction)
- `watcher.log` (detailed execution log)

**Note**: Runs in background started by `trigger-bsod-intentional.sh`.

---

### `preflight-rhov.sh`

**Purpose**: Pre-run validation before triggering crash.

**Responsibilities**:
- Verify VM exists and is in Running state
- Check qemu-guest-agent is responsive
- Validate crash dump settings via `guest-agent.py`
- Verify CrashControl registry matches expected state
- Check evidence storage PVC is mounted
- Build/verify extraction container image (if needed)
- Upload crash dump configuration scripts to VM
- Generate recovery-metadata.json for downstream phases

**Environment Variables**:
- `BSOD_DET__MEMORY__DUMP_PVC`: Memory dump PVC name
- `BSOD_DET__SNAPSHOT__CLASS`: Storage snapshot class
- `BSOD_DET__GUEST_AGENT_BIN`: Path to guest-agent.py
- `BSOD_DET__COMMAND__TIMEOUT`: Command timeout (default: 30s)

**Output**:
- `recovery-metadata.json` (contains VM config, storage details, image refs)
- Validated VM state and configuration

**Example**:
```bash
./preflight-rhov.sh \
  --ns windows-bsod \
  --vm win2022-vm-hjoshi1 \
  --out /mnt/persistent-bsod-evidence/20261007T120000Z-intentional-12345-6789 \
  --metadata /mnt/persistent-bsod-evidence/20261007T120000Z-intentional-12345-6789/recovery-metadata.json
```

---

### `recover-natural-crash.sh`

**Purpose**: Offline NTFS artifact extraction from stopped VM disk.

**Responsibilities**:
- Validate input parameters and recovery metadata
- Discover NTFS partitions dynamically via `guestfish list-filesystems`
- Search for .evtx files across all partitions using `guestfish find /`
- Create `guestfs-ntfs` pod using public `quay.io/konveyor/oadp-vmfr-access` image
- Extract files via two-phase approach:
  - Phase 1: guestfish mounts NTFS and downloads to pod `/tmp/`
  - Phase 2: `oc cp` transfers file from pod to host
- Parse extracted EventLogs using `extract-evtx.py`
- Validate artifact formats (dump, evtx, etc)
- Generate checksums for all artifacts
- Auto-cleanup pod and temp files

**Environment Variables**:
- `BSOD_DET__COMMAND__TIMEOUT`: Command timeout (default: 30s)
- `BSOD_DET__EXTRACT_EVTX__BIN`: Path to extract-evtx.py
- `BSOD_DET__DATA__DIR`: Data directory for evtx metadata
- `BSOD_DET__GUESTFS__NTFS_IMAGE`: guestfs pod image (default: `quay.io/konveyor/oadp-vmfr-access:latest`)

**Key Features**:
- ✅ No PSS escalation required (runs with baseline policy)
- ✅ Two-phase extraction avoids stdout redirection issues
- ✅ Dynamic partition discovery (works on any Windows configuration)
- ✅ Comprehensive file search across all partitions
- ✅ Clean error handling and fallback extraction
- ✅ Automatic pod cleanup (trap EXIT ensures cleanup on crash)

**Output**:
- `guestFS/Windows/System32/winevt/Logs/System.evtx` (7.1MB typical)
- `guestFS/Windows/System32/winevt/Logs/Application.evtx` (5.1MB typical)
- `EventLogs/System.json` (parsed EventLog)
- `EventLogs/Application.json` (parsed EventLog)
- `extraction.log` (detailed extraction log)
- `checksums.sha256` (artifact integrity verification)

---

### `guest-agent.py`

**Purpose**: Tunnel PowerShell commands into Windows VM via qemu-guest-agent.

**Responsibilities**:
- Establish connection to qemu-guest-agent via `virsh` RPC
- Upload files (PowerShell scripts, crash tools) into VM
- Execute PowerShell commands in VM
- Capture stdout/stderr from VM execution
- Timeout command execution if needed
- Return exit codes

**How It Works**:
```
oc exec virt-launcher
  ↓
virsh RPC (connect to qemu-ga socket)
  ↓
qemu-guest-agent (inside VM)
  ↓
PowerShell execution in Windows
```

**Common Usage**:
- Upload: `configure-dumps.ps1` (crash dump settings)
- Upload: `NotMyFault.exe` (crash injection tool)
- Execute: Crash trigger commands
- Execute: Cleanup commands before/after test

**Key Constants** (lines 114-134):
- `GA_SOCKET`: qemu-ga socket path in libvirt domain
- `GA_TIMEOUT`: Default command timeout
- `UPLOAD_RETRIES`: Retry count for file uploads

---

### `parse-dump-header.sh`

**Purpose**: Extract Windows bugcheck code from dump header.

**Responsibilities**:
- Read vm-memory-windows.dmp at specific offsets
- Extract bugcheck code (4 bytes at offset 0x38, little-endian)
- Extract bugcheck parameters (4x 8-byte values at offsets 0x40-0x58)
- Look up bugcheck name from crash-control.json database
- Output parse-dump-header.json with human-readable crash details

**Output Format**:
```json
{
  "ok": true,
  "bugCheckCode": "0x00000161",
  "bugCheckName": "THREAD_STUCK_IN_DEVICE_DRIVER",
  "parameters": ["0x...", "0x...", "0x...", "0x..."],
  "arch": "x86_64",
  "dumpType": "MEMORY_DUMP"
}
```

---

### `reliability.py`

**Purpose**: Artifact validation and evidence summary generation.

**Responsibilities**:
- Validate artifact file formats (PAGEDU64, EVTX, PNG, JSON, etc)
- Verify required artifacts present for current mode
- Generate checksums for integrity verification
- Create evidence-summary.json report
- Check for errors in stage-errors.jsonl

**Commands**:
- `write-summary`: Generate final validation report
- `validate-artifact`: Check individual file format

**Output**:
- `extraction-summary.json` (comprehensive artifact inventory)
- `evidence-summary.json` (final validation report)

---

### `extract-evtx.py`

**Purpose**: Parse Windows Event Log (.evtx) files to JSON.

**Responsibilities**:
- Parse binary EVTX files using python-evtx library
- Extract event XML from compressed chunks
- Convert to JSON format
- Handle parsing errors gracefully
- Output event count and metadata

**Input**: One or more `.evtx` files  
**Output**: JSON with parsed events and metadata

**Note**: Falls back to individual file parsing if extract-evtx tool fails.

---

## Execution Order (Intentional Crash Flow)

```
1. trigger-bsod-intentional.sh (main orchestrator)
   ├─ Cleanup leftover cache files
   ├─ Call preflight-rhov.sh (validates VM & setup)
   ├─ Start watch-crash.sh (background monitoring)
   ├─ Inject BSOD crash via guest-agent.py
   ├─ Watch waits for BSOD detection
   │  └─ Calls recover-natural-crash.sh (extracts artifacts)
   │     └─ Calls parse-dump-header.sh
   │        └─ Calls extract-evtx.py
   ├─ Watch completes, calls reliability.py write-summary
   └─ Return exit code (0=success, 1=failure)
```

## Environment Variable Naming Convention

All environment variables follow Red Hat Chaos Team best practices:
- **Prefix**: `BSOD_DET` (BSOD Detector)
- **Separator**: Double underscore `__` between components
- **Multi-word**: Single underscore `_` within component names

Examples:
- `BSOD_DET__COMMAND__TIMEOUT` (component: COMMAND, property: TIMEOUT)
- `BSOD_DET__GUESTFS__NTFS_IMAGE` (component: GUESTFS, property: NTFS_IMAGE)
