# Scripts

Catalog of executable tooling. The directory contains both PowerShell 5.1+ (Windows guest-side) and Bash 4+ (Linux host-side) scripts. Each collector and analysis script does one job, takes well-defined inputs, and writes **exactly one JSON object** to stdout (the consumer contract). Helper scripts like `capture-vm-screen.sh` that produce file artifacts instead of JSON are excluded from this contract. Diagnostic chatter goes to the information/error streams, never stdout.

All scripts read their lookup tables from [`../data/`](../data/README.md); no table is duplicated inside a script. Tool selection rationale is in [`../../docs/tool-selection.md`](../../docs/tool-selection.md).

## Layout

- **This folder** is *The Catcher*: detect / capture / analyze a real,
  naturally-occurring BSOD/freeze on an OCP KubeVirt VM, plus the shared
  access/lifecycle helpers (`guest-agent.py`, `guest-ssh.sh`, `vmctl.sh`).
- **[`crash-injector/`](crash-injector/README.md)** is *The Pitcher*: destructive,
  test-only scripts that intentionally crash a disposable guest to validate the
  Catcher. Never point them at production.
- A per-file catalog lives in [`../../MANIFEST.md`](../../MANIFEST.md).

## Pipeline

Typical test run (guest unless noted):

1. `configure-dumps.ps1` — set `CrashControl` so a dump gets written (prerequisite).
2. Trigger via CrashMe driver (`crashme-ctl.exe <code> <p1> <p2> <p3> <p4>`) or via
   chaos fault injection (`vm/sweep-chaos.sh`).
3. After reboot, `collect-guest.ps1` — pull dumps, events, context.
4. `collect-from-host.ps1` (Hyper-V host) — detect the crash and recover the
   dump when the guest is frozen or won't boot. On a **libvirt/KVM (KubeVirt)**
   host use `collect-from-host.sh` instead (same JSON contract).

### Chaos testing pipeline

For organic fault injection (not KeBugCheckEx), the sweep loop is:
revert → start → SSH → [workload] → inject fault → detect crash → collect.
Chaos triggers may produce no crash (valid outcome). See `vm/sweep-chaos.sh`
and `data/chaos-triggers.json` for trigger definitions.

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
(`src/scripts/crash-injector/sweep-crashme.sh`). `configure-dumps.ps1` (guest, CrashControl registry)
and `collect-from-host.ps1` (Hyper-V host-side detect + offline VHDX/LiveKd
dump recovery) are **implemented**. For the Linux/KVM (KubeVirt) target the
freeze-detect + offline-recovery job is covered by `collect-from-host.sh` (the
libvirt-native sibling) on top of `host-tools/`, and dump configuration by
`src/scripts/crash-injector/prep-guest.ps1`.

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
Uses a three-tier detection fallback:

1. **bugcheck**: System/1001 WER BugCheck event (traditional BSOD with stop code)
2. **livekernelevent**: Application/1001 with EventName=LiveKernelEvent (non-fatal
   kernel crash that produces dumps in `LiveKernelReports\` but bypasses the
   traditional crash dump mechanism)
3. **dirtyshutdown**: System/6008 dirty shutdown with no diagnostic event (crash
   that bypassed both dump mechanisms entirely)

Collects dumps from `Minidump\`, `MEMORY.DMP`, and `LiveKernelReports\`.

**Inputs:** `-OutputDir` (default `<repo>\output\<timestamp>`, git-ignored),
`-SysinternalsPath`, `-Symbolize` (also run `analyze-dump.ps1` on MEMORY.DMP to
resolve the failure bucket + faulting image and populate
`crash.faultingModule` / `crash.analysis` / `suspectDriver`).

**Reads:** `data/bugcheck-codes.json`, `data/event-sources.json`.

**Output:** `{ ok, collectedAt, outputDir, system, crash, events, suspectDriver, warnings }`.
The `crash` object includes `detected` (bool), `crashType` (one of `bugcheck`,
`livekernelevent`, `dirtyshutdown`, or null if no crash evidence found), and the
bug-check code/parameters when available. Deep dump analysis (`analyze-dump.ps1`,
`cdb !analyze -v`) runs only when `-Symbolize` is passed.

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

### src/scripts/crash-injector/sweep-crashme.sh  _(host, bash)_

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
./src/scripts/crash-injector/sweep-crashme.sh
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

## KubeVirt cluster tooling (guest-agent, no SSH)

On a KubeVirt/OpenShift cluster the VM has no passt SSH; it is driven through the
**qemu-guest-agent** spoken by `virsh` inside the VM's `virt-launcher` pod. These
scripts were used to reproduce the local BSOD runs (0xEF CRITICAL_PROCESS_DIED and
0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL) end-to-end on the goldman-sachs cluster VM
`hjoshi-win2022` (ns `windows-bsod`). `guest-exec` runs as `nt authority\system`.

### guest-agent.py  _(host, python3 + oc)_

**Purpose:** Driver for the qemu-guest-agent via `oc exec <virt-launcher> -- virsh
qemu-agent-command <ns>_<vm>`. Subcommands: `ping`, `exec`, `psfile` (upload+run a
`.ps1`), `put`, `get` (seek-based, retriable download). Importable helpers
(`guest_exec`, `guest_put`, `guest_get`) for scripting a full run.

**Config (all optional — target is auto-resolved):** `GA_VM` (VM name), `GA_NS`
(namespace), `GA_DOM` (domain, defaults to `<ns>_<vm>`), `GA_POD` (defaults to the
running `virt-launcher-<vm>-*` pod resolved from the cluster — no stale pod
suffixes). With a single VMI on the cluster you can run with no env vars at all;
otherwise set `GA_VM` (and `GA_NS` if ambiguous).

**Notes:** read chunks are capped by the QMP payload limit (2MB ok, 4MB fails);
`get` seeks per chunk and retries so a truncated response is recoverable.

### stage-toolkit.ps1  _(guest)_

**Purpose:** Expand the uploaded `bsod-src.zip` into `C:\bsod-detector` so the
in-guest collectors resolve. (Host side: `zip -r bsod-src.zip src` then
`guest-agent.py put bsod-src.zip C:\Windows\Temp\bsod-src.zip`.)

### probe-dump-config.ps1  _(guest)_

**Purpose:** Read-only snapshot of CrashControl settings, dump inventory, free
space, RAM, last boot time, toolkit-staged flag. Pre/post-test sanity check.

### clear-dumps.ps1  _(guest, elevated)_

**Purpose:** Delete existing minidumps + MEMORY.DMP before a run so the evidence
package holds only the new crash.

### trigger-bsod.ps1  _(guest, elevated, synchronous)_

**Purpose:** Driver-free BSOD → 0x000000EF CRITICAL_PROCESS_DIED. Marks itself
critical (`RtlSetProcessIsCritical`) then `TerminateProcess((IntPtr)-1)`. Fire via
`guest_exec(..., wait=False)` — the guest dies mid-call.

### diag-critical-api.ps1  _(guest)_

**Purpose:** Validate the `RtlSetProcessIsCritical` P/Invoke path (NTSTATUS return
codes) WITHOUT crashing — use when a trigger is a silent no-op.

### setup-notmyfault.ps1  _(guest, internet)_

**Purpose:** Download Sysinternals NotMyFault to `C:\Temp\nmf`. Crash with
`notmyfaultc64.exe /accepteula /crash 0x01` → 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL
(faulting `myfault.sys`). A driver-based alternative to crashme.sys.

### install-debuggers.ps1  _(guest, internet, ~5 min)_

**Purpose:** Install `cdb` (Windows SDK debuggers) so `analyze-dump.ps1` /
`collect-guest.ps1 -Symbolize` can symbolize. Drive with a long `poll_timeout`.

### compress-dump.ps1  _(guest)_

**Purpose:** Stage a shared-read copy of the locked `MEMORY.DMP` and zip it (~14%)
for a smaller, more reliable pull via `guest-agent.py get`; prints sizes + sha256.

### Execution order (cluster run)

```bash
export KUBECONFIG=<cluster kubeconfig>          # e.g. goldman-sachs
export GA_VM=<vm> GA_NS=<ns>                     # optional; omit if there is a single VMI
zip -r /tmp/bsod-src.zip src                     # from apps/bsod-detector
python3 src/scripts/guest-agent.py put /tmp/bsod-src.zip 'C:\Windows\Temp\bsod-src.zip'
python3 src/scripts/guest-agent.py psfile src/scripts/stage-toolkit.ps1
python3 src/scripts/guest-agent.py psfile src/scripts/probe-dump-config.ps1   # confirm CrashDumpEnabled=7
python3 src/scripts/guest-agent.py psfile src/scripts/clear-dumps.ps1
# --- trigger (async) ---   EF: trigger-bsod.ps1   |   D1: setup-notmyfault.ps1 then notmyfaultc64 /crash 0x01
# --- while it crashes: loop `virsh screenshot` inside the pod to catch the blue screen ---
python3 src/scripts/guest-agent.py exec powershell.exe -NoProfile -File 'C:\bsod-detector\src\scripts\collect-guest.ps1'
python3 src/scripts/guest-agent.py get 'C:\Windows\Minidump\<file>.dmp' ./out/minidump.dmp
bash src/scripts/parse-dump-header.sh ./out/minidump.dmp                       # offline cross-check
# deep analysis (optional): install-debuggers.ps1 -> analyze-dump.ps1 / collect-guest.ps1 -Symbolize
# full dump (optional): compress-dump.ps1 -> guest-agent.py get MEMORY.DMP.zip
```

### watch-crash.sh  _(host, bash + oc)_ — natural crash, NO trigger

**Purpose:** Watch a KubeVirt Windows VM for a **naturally-occurring** BSOD/freeze
and auto-capture evidence with **no trigger at all** — no NotMyFault, no
`trigger-bsod.ps1`. This is the path for crashes the workload/config produces on
its own, notably the **TLB-flush scenario**: the Intel split-lock `#AC` raised
during the Hyper-V *enlightened TLB-flush* hypercall on an unmitigated VM →
`HYPERVISOR_ERROR (0x00020001)`, which typically **hard-freezes and writes no
minidump**.

It polls the `qemu-guest-agent` (via `guest-agent.py`, no SSH). When the agent
stops answering while the domain is still alive (`running`/`paused`/`crashed`/
`pmsuspended` — a **pvpanic** device can move a bugcheck out of `running`) it, in
one shot:

1. bursts `virsh screenshot` inside the `virt-launcher` pod and flags the blue
   screen by size (solid-colour frames compress to ~36 KB, vs ~874 KB desktop and
   ~3 KB DPMS-black — see the `SS_MIN`/`SS_MAX` band);
2. captures **host-side signals** — worker-node `dmesg` (`oc debug node`) + domain
   XML → `collect-host-signals.sh`. **This is the only place the TLB-flush /
   split-lock `#AC` is visible**; it never appears in the guest dump;
3. if the guest reboots, runs `collect-guest.ps1`, pulls the newest minidump and
   cross-checks it offline with `parse-dump-header.sh`; if it stays frozen (typical
   for `HYPERVISOR_ERROR`) it records the hard-freeze and stops.

**Inputs:** `--ns <namespace>` and `--vm <name>` are **optional** — with a single
VMI on the cluster both are auto-detected; pass them only to disambiguate. `--out
<dir>`, `--interval <s>` (poll cadence, default 5),
`--miss <n>` (consecutive missed pings = crash, default 3), `--node <worker>`
(auto-detected from the VMI if omitted), `--reboot-wait <s>` (default 300),
`--burst <n>` (screenshot frames, default 25).

**Requires:** `oc`, `python3`, `jq`, and (same dir) `guest-agent.py`,
`collect-host-signals.sh`, `parse-dump-header.sh`. The toolkit must already be
staged in the guest (`stage-toolkit.ps1`) for the `collect-guest` step. The VM
must have a working `qemu-guest-agent`.

**Output package** (in `--out`): `bsod-screenshot.png`, `host-signals.json`,
`dom.xml`, `kern.log`, `collect-guest.json`, `Minidump/*.dmp` +
`parse-dump-header.json` (only if it reboots), and **`evidence-summary.json`**
tying it together: `{ ok, mode:"natural", crashDetected, detectedAt,
domStateAtCrash, guestRebooted, hardFreeze, bugCheck, splitLockDetected,
artifacts }`.

**Prerequisites for the TLB-flush crash to actually occur** (environment, not this
script — `watch-crash.sh` only detects and captures, it does not induce the crash):
- the VM runs the **unmitigated** Hyper-V enlightenment config — `<hyperv>` with
  `tlbflush` **and** `ipi` enabled (verify in `dom.xml` / `host-signals.json`);
- the worker node has split-lock detection on: `split_lock_detect=warn` or `on`
  (otherwise the `#AC` line never appears, regardless of the crash).

**Usage:**
```bash
export KUBECONFIG=<cluster kubeconfig>          # e.g. goldman-sachs
# stage the toolkit once (needed only for the post-reboot collect-guest step);
# GA_VM/GA_NS are optional — omit them if there is a single VMI on the cluster:
export GA_VM=<vm> GA_NS=<ns>
zip -r /tmp/bsod-src.zip src && \
  python3 src/scripts/guest-agent.py put /tmp/bsod-src.zip 'C:\Windows\Temp\bsod-src.zip' && \
  python3 src/scripts/guest-agent.py psfile src/scripts/stage-toolkit.ps1

# then just watch — run the workload/TLB scenario in parallel and wait for it to crash.
# --ns/--vm are optional (auto-detected with a single VMI):
./src/scripts/watch-crash.sh --out ./output/natural
```

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
