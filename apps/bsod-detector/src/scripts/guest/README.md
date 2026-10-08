# Guest Scripts

PowerShell scripts that run inside Windows VMs via qemu-guest-agent tunnel.

These scripts configure Windows crash dump settings and manage pre-test/post-test state.

## Script Overview

### `configure-dumps.ps1`

**Purpose**: Configure Windows crash dump settings for BSOD detection and EventLog recording.

**Primary Responsibilities**:
1. **AutoReboot=0** — Most critical — prevents VM reboot after BSOD so detection can capture the crash state
2. **EventLog recording** — Enables System.evtx to capture crash events and timestamps
3. **DedicatedDump.sys** — Safety measure to prevent Windows from trying to write to pagefile.sys (blocked by VirtIO Balloon)

**Additional Responsibilities**:
- Set CrashDumpEnabled registry value (determines dump behavior)
- Set DumpFile path (custom dump location)
- Create DedicatedDump.sys pre-allocated file
- Verify configuration was applied correctly
- Report current crash dump state

**What Gets Extracted vs What Doesn't**:
- ✅ **System.evtx** (7.1MB) — Extracted successfully, contains crash events
- ✅ **Application.evtx** (5.1MB) — Extracted successfully, contains app-level crash events
- ✅ **vm-memory-windows.dmp** (16GB) — Captured via `virtctl memory-dump`, contains full RAM
- ❌ **Minidump** (256KB) — Cannot be extracted (VirtIO Balloon blocks pagefile.sys creation, minidump has nowhere to write)
- ❌ **DedicatedDump.sys** (16GB) — Not extracted (redundant with vm-memory-windows.dmp which is more complete)

**Execution**:
```powershell
# Run via guest-agent.py tunnel from host
./guest-agent.py exec configure-dumps.ps1
```

**Configuration Parameters** (passed via crash-control.json):

| Parameter | Type | Typical Value | Purpose |
|---|---|---|---|
| `CrashDumpEnabled` | INT | `1` or `3` or `7` or `11` | Determines what gets dumped (see values below) |
| `AutoReboot` | INT | `0` | 0 = don't reboot (stay at BSOD), 1 = auto reboot |
| `DumpFile` | STRING | `C:\DedicatedDump.sys` | Optional custom dump path |
| `DedicatedDumpSize` | INT | 17179869184 | DedicatedDump.sys size in bytes (16GB typical) |

**CrashDumpEnabled Values**:

| Value | Name | Behavior | Size |
|---|---|---|---|
| `0x00` | None | No dump | 0 bytes |
| `0x01` | Minidump | Only kernel stack traces | 256 KB |
| `0x03` | Kernel dump | Full kernel memory | Variable (~2GB) |
| `0x07` | Complete dump | Full RAM dump to pagefile.sys | ~16GB |
| `0x0B` (11) | Automatic | CrashDumpEnabled=1 + DedicatedDump.sys | 16GB |

**How It Works**:

```powershell
# 1. Load crash-control.json configuration
$config = Get-Content crash-control.json | ConvertFrom-Json

# 2. Set registry values
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" `
  -Name "CrashDumpEnabled" `
  -Value $config.CrashControl.CrashDumpEnabled `
  -Type DWord

# 3. Verify settings applied
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" | 
  Select-Object CrashDumpEnabled, AutoReboot, DumpFile
```

**Environment Handling**:
- Requires **Administrator** privileges (run as SYSTEM via virsh RPC)
- Must disable VirtIO Balloon driver before setting crash dumps (blocks pagefile.sys creation)
- Registry changes take effect on next BSOD
- DedicatedDump.sys is pre-allocated at configuration time (faster than pagefile)

**Output**:
- Registry updated with crash dump settings
- DedicatedDump.sys created on disk (if configured)
- Verification output showing current settings

**Typical Configuration**:

For BSOD detector pipeline, we use:
```json
{
  "CrashDumpEnabled": 11,
  "AutoReboot": 0,
  "DumpFile": "C:\\DedicatedDump.sys",
  "DedicatedDumpSize": 17179869184
}
```

**Why each setting**:
- **CrashDumpEnabled=11**: Configures Windows to attempt writing a dump (though minidump won't succeed due to pagefile blocker)
- **AutoReboot=0**: ⭐ CRITICAL — Keeps VM frozen at BSOD so `watch-crash.sh` can detect it via vmi.status.guestOSInfo disappearance
- **DumpFile + DedicatedDump.sys (16GB)**: Safety measure — gives Windows a fallback location to attempt writing, prevents errors when pagefile.sys unavailable
- **Result**: Crash is detected reliably, EventLogs are recorded properly, Windows doesn't error out

**Note**: We DON'T extract the DedicatedDump.sys file itself — it's just a safety fallback. Our actual dump comes from `virtctl memory-dump` (16GB vm-memory-windows.dmp) which is more complete.

---

### `clear-dumps.ps1`

**Purpose**: Clean up old crash dumps and log files before testing.

**Responsibilities**:
- Remove old crash dumps from C:\Windows\Minidump\
- Remove old .dmp files from system directories
- Clear dump configuration metadata
- Prepare VM disk for fresh BSOD test

**Execution**:
```powershell
# Run via guest-agent.py tunnel to clean up before test
./guest-agent.py exec clear-dumps.ps1
```

**What It Clears**:

| Location | Pattern | Purpose |
|---|---|---|
| `C:\Windows\Minidump\` | `*.dmp` | Old minidump files |
| `C:\` | `MEMORY.DMP`, `Minidump/` | Legacy dump locations |
| System logs | Old event logs | Clean audit trail |

**Why Important**:
- Ensures fresh test state — no old crash artifacts in Minidump directory
- Prevents confusion between old and new crash evidence
- Keeps filesystem clean for new DedicatedDump.sys or pagefile.sys

**Side Effects**:
- Does NOT reset CrashControl registry settings (keeps them as-is)
- Does NOT delete DedicatedDump.sys (pre-allocated file stays)
- Only removes actual dump files and logs from previous crashes

---

## Execution Flow (Full Test Sequence)

```
1. Host: trigger-bsod-intentional.sh
   ├─ Call preflight-rhov.sh
   │  ├─ Call guest-agent.py
   │  │  └─ Execute configure-dumps.ps1 (set crash dump settings)
   │  └─ Verify CrashControl registry configured
   │
   ├─ Optional: clear-dumps.ps1 (clean old artifacts)
   │
   ├─ Inject crash via guest-agent.py
   │  └─ Upload NotMyFault.exe
   │  └─ Execute notmyfault.exe /crash 0x01
   │
   └─ Watch detects BSOD and captures memory
```

## Guest-Agent Communication Protocol

These scripts run **inside the Windows VM** via the qemu-guest-agent tunnel.

**How Host → Guest Communication Works**:

```
Host: guest-agent.py exec configure-dumps.ps1
  ↓
ssh/oc exec → virt-launcher pod
  ↓
virsh RPC → qemu-guest-agent socket
  ↓
qemu-guest-agent (inside VM via QEMU serial channel)
  ↓
PowerShell execution in Windows (guest context)
  ↓
Output captured and returned to host
```

**Key Constraints**:
- Scripts run as SYSTEM (highest Windows privilege level)
- No interactive input possible (command-line only)
- Output limited to stdout/stderr capture
- Files must be uploaded separately (not embedded in commands)
- Timeout: typically 30-60 seconds per command

## Registry Locations

All crash dump configuration is stored in:
```
HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl\
```

**Key Values**:
- `CrashDumpEnabled` (DWORD): What gets dumped (0-11)
- `AutoReboot` (DWORD): Reboot after BSOD (0=no, 1=yes)
- `DumpFile` (STRING): Custom dump file path
- `Overwrite` (DWORD): Overwrite existing dump (1=yes)

**Related Keys**:
- `HKLM:\SYSTEM\CurrentControlSet\Services\VirtIO` — KVM drivers
- `HKLM:\SYSTEM\CurrentControlSet\Services\VirtIOBalloon` — Memory balloon driver

## Known Issues & Architectural Blockers

### Blocker: DedicatedDump.sys Never Extracted

**Situation**:
- We configure `CrashDumpEnabled=11` with `DedicatedDump.sys` (16GB pre-allocated)
- Windows successfully writes the dump to C:\DedicatedDump.sys during BSOD
- **BUT**: We never extract it

**Why**:
- `virtctl memory-dump` captures full 16GB RAM dump at BSOD moment → `vm-memory-windows.dmp`
- DedicatedDump.sys contains the same data (kernel memory) but is redundant
- Extracting both would be wasteful (32GB transfer for same information)
- We chose virtctl dump because it's more reliable and complete

**Result**: DedicatedDump.sys is configured for safety (gives Windows a write location) but never extracted

### Other Known Issues & Workarounds

**Issue**: Pagefile.sys never created (VirtIO Balloon blocks it)
- **Workaround**: Use DedicatedDump.sys instead (`CrashDumpEnabled=11`)
- **Config**: Pre-allocate 16GB file at C:\DedicatedDump.sys
- **Note**: This prevents Windows from erroring, even though we don't extract it

**Issue**: AutoReboot doesn't stick (registry reverts)
- **Workaround**: Disable Windows Update that resets this value
- **Config**: Force `AutoReboot=0` in configure-dumps.ps1

**Issue**: Minidump never created (pagefile.sys unavailable)
- **Cause**: CrashDumpEnabled=0x01 would create minidump, but pagefile.sys blocked by VirtIO Balloon
- **Impact**: Minidump never appears on disk to extract
- **Solution**: Use `CrashDumpEnabled=11` (attempts full dump), extract via `virtctl memory-dump` instead

**Issue**: Registry changes require reboot
- **Workaround**: Some settings take effect immediately via group policy refresh
- **Command**: `gpupdate /force` if needed

## Debugging

**From Host**: Check what settings were actually applied
```bash
guest-agent.py exec 'Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"'
```

**From Guest**: Manual registry check (if you have VM access)
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" | 
  Select-Object CrashDumpEnabled, AutoReboot, DumpFile, Overwrite
```

## Related Resources

- **crash-control.json**: Database of Windows CrashControl registry values (see `src/data/`)
- **guest-agent.py**: Tunnel for executing these scripts (see `src/scripts/host/`)
- **configure-dumps.ps1**: Main configuration script (this directory)
- **Windows Crash Dump Docs**: https://docs.microsoft.com/en-us/windows-hardware/drivers/debugger/kernel-memory-dump

## Integration with BSOD Detector Pipeline

These guest scripts are called during two phases:

**Phase 1: Preflight (preflight-rhov.sh)**
- Executes configure-dumps.ps1 to set crash dump settings
- Verifies settings via registry read-back
- Builds recovery-metadata.json with configuration details

**Phase 2: Cleanup (optional pre-test)**
- Can run clear-dumps.ps1 to remove old artifacts
- Ensures fresh test state with no prior crash evidence
