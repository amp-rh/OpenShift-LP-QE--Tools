# Crash Injector Scripts

Scripts that orchestrate intentional BSOD injection for testing the detector pipeline.

These scripts are designed for **deliberate, controlled crash testing** — not production use.

## Script Overview

### `trigger-bsod-intentional.sh`

**Purpose**: Main entry point for intentional BSOD testing.

This script orchestrates the complete crash detection and artifact extraction pipeline:

**Usage**:
```bash
GA_VM="win2022-vm-hjoshi1" GA_NS="windows-bsod" \
  ./trigger-bsod-intentional.sh 0x01
```

**Arguments**:
- `crash_type`: NotMyFault bugcheck code (0x01-0x09)
  - `0x01`: EXCEPTION_ACCESS_VIOLATION
  - `0x02`: INVALID_KERNEL_HANDLE
  - `0x03`: SYSTEM_SERVICE_EXCEPTION
  - etc (see NotMyFault documentation for full list)

**Environment Variables**:

| Variable | Default | Purpose |
|---|---|---|
| `GA_VM` | `win2022-vm-hjoshi1` | Target Windows VM name |
| `GA_NS` | `windows-bsod` | Kubernetes namespace |
| `BSOD_DET__EVIDENCE__DIR` | `/mnt/persistent-bsod-evidence` | Evidence storage root |
| `BSOD_DET__SNAPSHOT__CLASS` | `ocs-storagecluster-rbdplugin-snapclass` | Storage snapshot class |
| `BSOD_DET__READY__TIMEOUT` | `300` | Watcher readiness timeout (seconds) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | `300` | Preflight validation timeout (seconds) |

**Execution Flow**:

```
1. Cleanup leftover cache files (file.0x* from previous guestfish runs)
2. Create unique run directory: /mnt/persistent-bsod-evidence/{TIMESTAMP}-intentional-{PID}-{RANDOM}/
3. Call ../host/preflight-rhov.sh
   ├─ Verify VM state (Running, runStrategy: Manual)
   ├─ Check qemu-guest-agent responsive
   ├─ Validate crash dump settings
   ├─ Verify evidence mount
   └─ Generate recovery-metadata.json
4. Start ../host/watch-crash.sh in background
   └─ Monitors for BSOD every 5 seconds
5. Call guest-agent.py to inject crash via NotMyFault.exe
6. wait-crash.sh detects BSOD
   ├─ Captures memory dump via virtctl memory-dump
   ├─ Converts ELF → Windows DMP format
   ├─ Runs volatility3 analysis
   ├─ Stops VM
   └─ Calls ../host/recover-natural-crash.sh (extracts artifacts)
7. Call reliability.py to validate all artifacts
8. Return exit code (0=success, 1=failure)
```

**Output Structure**:

```
/mnt/persistent-bsod-evidence/20261007T120000Z-intentional-12345-6789/
├── BSOD Detection Artifacts
│   ├── bsod-screenshot.png              (BSOD screenshot from virtctl)
│   ├── watcher-ready                     (marker: detection began)
│   └── watcher.log                       (detailed watcher execution log)
│
├── Memory Dumps
│   ├── vm-memory-windows.dmp             (16GB Windows PAGEDU64 dump)
│   └── vm-memory.elf.tar.gz              (compressed ELF dump from KubeVirt)
│
├── Volatility Analysis
│   ├── volatility-windows-info.txt       (OS/kernel version)
│   ├── volatility-driverscan.txt         (loaded drivers at crash)
│   ├── volatility-dumpfiles.txt          (dump files enumeration)
│   └── volatility-crashinfo.txt          (crash context)
│
├── NTFS Extraction (Offline)
│   ├── guestFS/Windows/System32/winevt/Logs/
│   │   ├── System.evtx                   (7.1MB System EventLog)
│   │   └── Application.evtx              (5.1MB Application EventLog)
│   └── EventLogs/                        (symlinks for backward compat)
│       ├── System.json                   (parsed System EventLog)
│       └── Application.json              (parsed Application EventLog)
│
├── Analysis & Validation
│   ├── parse-dump-header.json            (bugcheck code, parameters)
│   ├── recovery-metadata.json            (VM config, storage details)
│   ├── extraction.log                    (guestfs extraction log)
│   ├── extraction-summary.json           (artifact inventory)
│   ├── evidence-summary.json             (final validation report)
│   ├── checksums.sha256                  (integrity verification)
│   ├── stage-errors.jsonl                (error tracking by stage)
│   │
│   └── Diagnostics
│       ├── domain.xml                    (VM domain definition)
│       ├── host-signals.json             (host diagnostics)
│       └── launcher-compute.log          (KVM launcher logs)
```

**Exit Codes**:
- `0`: Success — all artifacts extracted and validated
- `1`: Failure — see watcher.log or extraction.log for details

**Key Features**:
- ✅ Automatic VM state validation before crash
- ✅ Background watcher detects BSOD via vmi.status.guestOSInfo disappearance
- ✅ Memory dump captured at precise BSOD moment
- ✅ Offline NTFS artifact extraction (VM stopped)
- ✅ No PSS escalation required (runs with baseline policy)
- ✅ Two-phase extraction for reliable file transfer
- ✅ Automatic cleanup on success or failure (trap EXIT)
- ✅ Comprehensive validation and error tracking

**Testing Different Crash Types**:

```bash
# Access Violation
./trigger-bsod-intentional.sh 0x01

# Invalid Kernel Handle
./trigger-bsod-intentional.sh 0x02

# System Service Exception
./trigger-bsod-intentional.sh 0x03

# Etc - see NotMyFault.exe /crash output for available codes
```

## Prerequisite Configuration

Before running intentional crash tests, ensure:

1. **VM is Running**: `oc get vm win2022-vm-hjoshi1 -n windows-bsod` shows `Running`
2. **Crash dumps configured**: `preflight-rhov.sh` validates this
3. **Evidence mount exists**: `/mnt/persistent-bsod-evidence` is writable
4. **Storage classes available**: Check `ocs-storagecluster-rbdplugin-snapclass` exists
5. **guestfs image available**: `quay.io/konveyor/oadp-vmfr-access:latest` is pullable

## Troubleshooting

**Pod startup timeout**:
- Check namespace PSS is not blocking pod creation
- Verify guestfs image is available: `oc get imagestream -A | grep guestfs`

**Artifact extraction fails**:
- Check `/mnt/persistent-bsod-evidence/{RUN}/extraction.log` for guestfish errors
- Verify NTFS partition exists on VM disk: `guestfish list-filesystems`

**Memory dump not captured**:
- Check watcher detected BSOD: `grep "BSOD detected" watcher.log`
- Verify virtctl memory-dump completed: `grep "elf2dmp" watcher.log`

**For detailed debugging**:
- Enable xtrace in shell options: `bash -x trigger-bsod-intentional.sh`
- Check watcher.log for full execution trace
- Check extraction.log for guestfish commands and errors

## Related Scripts

- `../host/watch-crash.sh` — Background BSOD detection and memory capture
- `../host/preflight-rhov.sh` — Pre-run environment validation
- `../host/recover-natural-crash.sh` — Offline NTFS artifact extraction
- `../guest/configure-dumps.ps1` — Windows crash dump configuration
