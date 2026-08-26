# Scripts

Catalog of executable tooling. Each script does one job, takes well-defined inputs, and writes **exactly one JSON object** to stdout (the consumer contract). Diagnostic chatter goes to the information/error streams, never stdout.

All scripts are PowerShell 5.1+ (Windows) and read their lookup tables from [`../data/`](../data/README.md) — no table is duplicated inside a script. Tool selection rationale is in [`../../docs/tool-selection.md`](../../docs/tool-selection.md).

## Pipeline

Typical test run (guest unless noted):

1. `configure-dumps.ps1` — set `CrashControl` so a dump gets written (prerequisite).
2. Trigger via CrashMe driver (`crashme-ctl.exe <code> <p1> <p2> <p3> <p4>`).
3. After reboot, `collect-guest.ps1` — pull dumps, events, context.
4. `collect-from-host.ps1` (Hyper-V host) — detect the crash and recover the
   dump when the guest is frozen or won't boot. On a **libvirt/KVM (KubeVirt)**
   host use `collect-from-host.sh` instead (same JSON contract).

## Shared library

### `lib/Common.ps1`

**Purpose:** Dot-sourced helpers. Resolves the repo/`data` paths, loads
source-of-truth JSON (`Get-BsodData`), emits the single stdout JSON result
(`Write-JsonResult`), writes structured errors (`Fail`), and checks elevation
(`Test-IsAdministrator`).

## Index

Status: `collect-guest.ps1` is **implemented and verified** against a live
Windows Server 2025 guest. All 19 bug-check codes in `data/trigger-methods.json`
have been verified end-to-end using the KeBugCheckEx test driver
(`vm/sweep-crashme.sh`). `configure-dumps.ps1` (guest, CrashControl registry)
and `collect-from-host.ps1` (Hyper-V host-side detect + offline VHDX/LiveKd
dump recovery) are **implemented**. For the Linux/KVM (KubeVirt) target the
freeze-detect + offline-recovery job is covered by `collect-from-host.sh` (the
libvirt-native sibling) on top of `host-tools/`, and dump configuration by
`vm/prep-guest.ps1`.

### configure-dumps.ps1  _(guest, elevated)_

**Purpose:** Configure or verify Windows crash-dump settings so a dump is written
on the next BSOD.

**Inputs:** `-DumpType <none|complete|kernel|small|automatic>` (default from
`data/crash-control.json` recommendation), `-VerifyOnly`.

**Reads:** `data/crash-control.json`.

**Output:** `{ ok, action, requestedDumpType, applied?, current, matchesRecommended, rebootRequired, pageFile }`.

### collect-guest.ps1  _(guest, elevated)_

**Purpose:** Collect post-mortem evidence from inside the guest after reboot
(dumps, bug-check, crash-timeline events, system context, driver signature).
Detects **any** bug-check code implicitly via the WER BugCheck event
(System/1001); does not require the code to be pre-registered.

**Inputs:** `-OutputDir` (default `<repo>\output\<timestamp>`, git-ignored),
`-SysinternalsPath`, `-Symbolize` (also run `analyze-dump.ps1` on MEMORY.DMP to
resolve the failure bucket + faulting image and populate
`crash.faultingModule` / `crash.analysis` / `suspectDriver`).

**Reads:** `data/bugcheck-codes.json`, `data/event-sources.json`.

**Output:** `{ ok, collectedAt, outputDir, system, crash, events, suspectDriver, warnings }`.
The bug-check code and its 4 parameters are parsed from the WER BugCheck event
(System/1001) — reliable without a kernel debugger. Deep dump analysis
(`analyze-dump.ps1`, `cdb !analyze -v`) runs only when `-Symbolize` is passed.

### analyze-dump.ps1  _(any Windows with cdb.exe)_

**Purpose:** Symbolize a crash dump with `cdb !analyze -v` and extract the
failure bucket, faulting image (`IMAGE_NAME`), module, bugcheck code +
parameters, and the top call-stack frames. This is the deep-analysis step that
turns a raw stop code into the bucket/image attribution needed for triage
relied on (e.g. `0x7a_c0000185_DUMP_VIOSTOR` -> viostor.sys, or
`PAGE_HASH_ERRORS_0x1a_3f`).

**Inputs:** `-DumpPath` (required), `-CdbPath` (default: search SDK install
locations + PATH), `-SymbolPath` (default: MS public symbol server cached under
the output dir), `-OutputDir`.

**Reads:** `data/bugcheck-codes.json`.

**Requires:** `cdb.exe` (Debugging Tools for Windows / Windows SDK) and network
access to the symbol server (or a local symbol cache).

**Output:** `{ ok, dump, analyzedAt, bugCheckCode, bugCheckName, parameters, failureBucket, imageName, moduleName, faultingModule, stack, rawLog, warnings }`.

### collect-from-host.ps1  _(host, elevated)_

**Purpose:** Detect a guest BSOD and recover the dump (VHDX mount or LiveKd)
when the guest is frozen, rebooting, or unbootable.

**Inputs:** `-VmName` (required), `-VhdxPath`, `-PipeName`, `-OutputDir`,
`-Mode <detect|recover>`.

**Output:** `{ ok, vm, mode, guestState, crashDetected, recovery, warnings }`.

### collect-from-host.sh  _(libvirt/KVM host, bash)_

**Purpose:** The libvirt-native counterpart to `collect-from-host.ps1` for the
KubeVirt/OpenShift-Virtualization target. Detects a guest hang/freeze and
recovers dumps offline when the guest is frozen or unbootable. Detection uses
`virsh domstate` plus a `qemu-guest-agent` `guest-ping` — a domain that is
`running` but no longer answers the agent within 5 s is the classic BSOD/hang
signature. Recovery resolves the guest disk via `virsh domblklist` and delegates
the actual offline dump pull to `host-tools/extract-dump.sh` (libguestfs on the
host) or `host-tools/run.sh` (same, in a container); an optional
`virsh dump --memory-only` fallback captures live guest memory (a QEMU/ELF image,
**not** a Windows `MEMORY.DMP`) when the guest cannot be powered off.

**Inputs:** `--vm <name>` (required), `--mode <detect|recover>` (default
`recover`), `--out <dir>`, `--disk <path>` (auto-resolved if omitted),
`--windows-root <path>` (default `/Windows`), `--force` (read the disk while the
VM is still `running`; risks an inconsistent image), `--virsh-dump` (enable the
live-memory fallback).

**Requires:** `virsh`, `jq`, and for recovery either `virt-copy-out` (libguestfs)
or `podman` (to run `host-tools/`).

**Output:** `{ ok, vm, mode, guestState, crashDetected, recovery:{ method, dumpFiles, outputDir }, warnings }`
— the same contract as `collect-from-host.ps1`. `guestState` is one of
`running|off|hung|crashed|rebooting|unknown`; `method` is one of
`none|guestfs-copy-out|guestfs-container|virsh-memory-dump`.

**Usage:**
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
# 1. Detect a freeze (no disk access):
./src/scripts/collect-from-host.sh --vm bsod-test --mode detect
# 2. After powering off a wedged guest (e.g. vmctl.sh kill), recover its dumps:
./src/scripts/collect-from-host.sh --vm bsod-test --mode recover --out ./output/dumps
```

### parse-dump-header.sh  _(host, Linux/macOS)_

**Purpose:** Read the bug-check code and 4 parameters directly from a Windows
kernel crash dump (PAGEDU64) file header, then resolve the code via
`bugcheck-codes.json`. Works without a Windows debugger.

**Inputs:** One or more `.DMP` file paths, or `--dir <directory>` to scan all
`.DMP` files in a directory.

**Reads:** `data/bugcheck-codes.json`.

**Requires:** `xxd`, `jq`, `python3`.

**Output:** `{ ok, totalDumps, dumps: [{ file, bugCheckCode, bugCheckName, parameters[], valid }], warnings[] }`.

Use this to validate that the lookup table covers codes found in real crash
dumps without needing to boot a Windows guest.

### test-bugcheck-lookup.ps1  _(guest or any Windows, no elevation needed)_

**Purpose:** Data-integrity and parsing test. Verifies that the collector's
regex + normalization logic resolves every code in `bugcheck-codes.json` to the
correct name. Fabricates a synthetic WER 1001 message per code and runs the
exact parsing path from `collect-guest.ps1`.

**Inputs:** None.

**Reads:** `data/bugcheck-codes.json`.

**Output:** `{ ok, totalCodes, passed, failed, results: [{ code, expectedName, resolvedCode, resolvedName, parametersFound, pass }] }`.

Run after adding or modifying codes in the lookup table to confirm the collector
will catch them.

---

## Host-side scripts (vm/)

These live under `vm/` rather than `scripts/` because they run on the Linux/KVM
host, not inside the Windows guest.

### vm/sweep-crashme.sh  _(host, bash)_

**Purpose:** Automated verification sweep of all KeBugCheckEx-triggered
bug-check codes. Iterates through every code in `data/trigger-methods.json`,
reverts the VM to a snapshot with the CrashMe driver installed, triggers each
code with exact parameters, waits for reboot, and collects evidence.

**Inputs:** None (codes and parameters read from `trigger-methods.json`).

**Requires:** `virsh`, SSH access to the guest, the `crashme-installed` snapshot
(which has the CrashMe KeBugCheckEx driver pre-loaded), and `guest-ssh.sh`.

**Output:** Per-code directories under `output/sweep-<CODE>/collect-guest.json`,
each containing the full `collect-guest.ps1` JSON output. Console output shows
pass/fail per code with the observed bug-check code and dump file list.

**Usage:**
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
./vm/sweep-crashme.sh
```

### src/scripts/collect-host-signals.sh  _(host, bash)_

**Purpose:** Capture Linux/KVM **host-side** crash-correlation signals that are
invisible from inside the guest dump. Greps the host kernel log for the patterns
in `data/host-signals.json` (notably Intel `split lock detection: #AC` traps)
and extracts the guest's Hyper-V enlightenment features (`tlbflush`, `ipi`, ...)
from the libvirt domain XML. This is the evidence that root-causes
HYPERVISOR_ERROR (split-lock #AC during the Hyper-V enlightened TLB-flush
hypercall) — a signal that never appears in the Windows guest.

**Inputs:** `--vm <name>` (default `$VM_NAME`/`bsod-test`), `--since <window>`
(journalctl window, default "2 hours ago"), `--dmesg` (read `dmesg` instead of
`journalctl -k`), `--log-file <path>` (parse a captured kernel log file),
`--domain-xml <path>` (read the domain XML from a file instead of `virsh dumpxml`).

**On OpenShift/KubeVirt** the node kernel log and the libvirt domain live in
different execution contexts (worker node vs `virt-launcher` pod), and the domain
is named `<namespace>_<vmname>`. Capture both to files and feed them in offline:

```bash
NODE=$(oc get vmi -n <ns> <vm> -o jsonpath='{.status.nodeName}')
POD=$(oc get pod -n <ns> -l kubevirt.io=virt-launcher,kubevirt.io/created-by \
        -o name | head -n1)   # or: oc get pod -n <ns> | grep virt-launcher-<vm>
oc debug node/$NODE -- chroot /host dmesg          > kern.log
oc exec -n <ns> $POD -- virsh dumpxml <ns>_<vm>    > dom.xml
./src/scripts/collect-host-signals.sh --vm <ns>_<vm> \
    --log-file kern.log --domain-xml dom.xml
```

Prerequisite: the worker node must have split-lock detection enabled
(`split_lock_detect=warn`/`on`) or the `#AC` line never appears, regardless of
the crash.

**Reads:** `data/host-signals.json` (kernel-log patterns + Hyper-V feature list;
source of truth).

**Requires:** `jq`, and `journalctl`/`dmesg` + `virsh` for live capture.

**Output:** `{ ok, vm, collectedAt, kernelSignals[], splitLockDetected, hyperv:{features[], mitigationApplied}, assessment[], warnings[] }`.

**Usage:**
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
./src/scripts/collect-host-signals.sh --vm bsod-test --since "3 hours ago"
```

<!-- Template for new entries:

### script-name.ps1

**Purpose:** One-sentence description.

**Inputs:** Parameters or stdin shape.

**Output:** JSON schema or example.
-->

---

## Testing

Unit tests live in `test/` and use [bats-core](https://github.com/bats-core/bats-core).
Run the full suite:

```bash
cd test && bash run-tests.sh
```

The suite covers:
- JSON validation and schema checks for all `data/` files
- Cross-reference integrity (trigger-methods -> bugcheck-codes; host-signals
  relatedBugCheck -> bugcheck-codes)
- `parse-dump-header.sh` against synthetic PAGEDU64 dumps
- `collect-host-signals.sh` split-lock detection + Hyper-V feature parsing
  against a synthetic split-lock kernel log
- `sweep-crashme.sh` argument consistency with `trigger-methods.json`
- WER bugcheck regex parsing and normalization
- Cross-compilation build (requires `mingw64-gcc`)
