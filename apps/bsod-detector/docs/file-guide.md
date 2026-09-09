# File Guide — what every file does, and which one to run

> Orientation doc. If you opened `src/scripts/` and could not tell which script
> to run, start here. For the JSON contract of each script (exact inputs and
> output shape) see [`../src/scripts/README.md`](../src/scripts/README.md); this
> guide is about *what things are* and *what order to run them in*.

## 1. The two axes (read this first)

Almost all the confusion in this tool comes from mixing up two independent
questions. Keep them separate:

**Axis 1 — where does the file execute?**

| | Runs on | Directory |
|---|---|---|
| **Guest** | inside the Windows VM | `src/scripts/guest/`, `src/data/guest/` |
| **Host** | on the Linux host / OCP worker node / your laptop | `src/scripts/host/`, `src/data/host/` |
| **Both** | shared | `src/scripts/lib/`, `src/data/bugcheck-codes.json` |

The file extension does **not** tell you this. `host/collect-from-host.ps1` is
PowerShell that runs on a *Hyper-V host*, not in the guest. That is exactly why
the directories exist.

**Axis 2 — are you *catching* a crash or *causing* one?**

| | Role | Directory |
|---|---|---|
| **The Catcher** | detect / capture / analyze a crash | everything in `src/scripts/` **except** `crash-injector/` |
| **The Pitcher** | deliberately crash a disposable VM, to prove the Catcher works | `src/scripts/host/crash-injector/` ⚠️ destructive |

If your goal is "watch our real Windows VM and tell me when it BSODs", you never
touch `crash-injector/`.

## 2. Three kinds of crash — this is the part people conflate

"Triggering a BSOD" means three very different things in this repo:

| | Kind | How the crash happens | Deterministic? | Entry point |
|---|---|---|---|---|
| **1** | **Synthetic** | You *ask* the kernel to bug-check — `KeBugCheckEx` via the CrashMe driver, or NotMyFault, or killing a critical process | Yes — you pick the exact stop code | `crash-injector/sweep-crashme.sh`, `crash-injector/trigger-bsod.ps1` |
| **2** | **Organic / chaos** | You create a *real* fault condition (yank a disk, inject an NMI, exhaust nonpaged pool, corrupt an MSR) and see whether Windows dies | No — "no crash" is a valid outcome | `crash-injector/sweep-chaos.sh` |
| **3** | **Natural** | Nothing is injected at all. The VM's own config + workload crashes it | No — you wait | `host/stakeout.sh` (wraps `host/watch-crash.sh`) |

**The single most important point:** for kind 3 there is *no trigger script*.
`watch-crash.sh` does **not** cause the crash — it only polls, detects, and
captures. You make a natural BSOD happen by putting the VM into the
crash-prone *configuration* and running the workload; see §6.

Kinds 1 and 2 exist to validate that the Catcher works. Kind 3 is the actual
product.

## 3. Directory map

```
apps/bsod-detector/
├── src/
│   ├── scripts/
│   │   ├── guest/          10 PowerShell scripts — run INSIDE Windows
│   │   ├── host/           host orchestration, capture, analysis
│   │   │   └── crash-injector/   ⚠️ destructive, test-only
│   │   │       └── test-driver/  CrashMe kernel driver (C, mingw64)
│   │   └── lib/            Common.ps1 — shared by guest and host PowerShell
│   └── data/
│       ├── guest/          staged into the VM
│       ├── host/           never staged into the VM
│       └── bugcheck-codes.json   shared
├── host-tools/             containerized libguestfs offline dump extraction
├── test/                   bats unit tests
└── docs/                   this file and friends
```

## 4. What every file does

### 4.1 `src/scripts/guest/` — runs inside the Windows VM

All PowerShell 5.1+. Each emits exactly one JSON object on stdout.

| File | Elevated? | What it does |
|---|---|---|
| `configure-dumps.ps1` | yes | **Prerequisite for everything.** Sets the `CrashControl` registry keys + page file so Windows actually writes a dump on the next BSOD. `-VerifyOnly` to check without changing. |
| `probe-dump-config.ps1` | no | Read-only sanity check: current CrashControl, existing dumps, free space, RAM, last boot, whether the toolkit is staged. Run before and after a test. |
| `clear-dumps.ps1` | yes | Deletes existing minidumps + `MEMORY.DMP` so the next run's evidence is unambiguous. |
| `stage-toolkit.ps1` | yes | Unzips the uploaded `bsod-src.zip` into `C:\bsod-detector`. One-time setup, because the cluster has no `scp`. |
| `collect-guest.ps1` | yes | **The main in-guest collector.** After reboot, gathers dumps, the bug-check code, the crash-timeline events, system context and driver signature. Uses the three-tier fallback in §7. |
| `analyze-dump.ps1` | no (needs `cdb`) | Deep triage: runs `cdb !analyze -v` on a dump and pulls out the failure bucket, faulting image/module, stop code + parameters, top stack frames. This is what turns `0x7A` into "viostor.sys". |
| `install-debuggers.ps1` | yes, internet, ~5 min | Installs the Windows SDK debuggers so `analyze-dump.ps1` can run in-guest. |
| `compress-dump.ps1` | yes | `MEMORY.DMP` is locked and huge. Makes a shared-read copy, zips it (~14%), prints sizes + sha256 — so `guest-agent.py get` can actually pull it. |
| `install-ssh-key.ps1` | yes | Installs a public key into `C:\ProgramData\ssh\administrators_authorized_keys` with the ACL Windows OpenSSH demands. Only needed for the **local libvirt** rig; the cluster path uses the guest agent, not SSH. |
| `test-bugcheck-lookup.ps1` | no | Self-test. Fabricates a synthetic WER 1001 message per code in `bugcheck-codes.json` and runs the collector's real parsing path against it. Run after editing the lookup table. |

### 4.2 `src/scripts/host/` — runs on the Linux host / your laptop

**Access layer** — how you talk to the guest at all:

| File | What it does |
|---|---|
| `guest-agent.py` | **The cluster access model.** Drives the Windows guest through the `qemu-guest-agent`, via `oc exec <virt-launcher> -- virsh qemu-agent-command`. No SSH required. Subcommands: `ping`, `exec`, `psfile` (upload+run a `.ps1`), `put`, `get`. Auto-resolves the VM/namespace/pod when there is one VMI. |
| `guest-ssh.sh` | The **local libvirt** access model. Runs PowerShell over SSH using `-EncodedCommand` so quoting never breaks, and strips PowerShell's CLIXML noise. Used by the crash-injector harnesses. |

**Detect / watch:**

| File | What it does |
|---|---|
| `stakeout.sh` | **Primary entry point for a natural-BSOD campaign.** Wraps the four phases of §6: preflight (gate on preconditions), stage, watch, and — the part `watch-crash.sh` never did — escalate to a host-side capture on hard freeze. Writes `stakeout-summary.json` with a verdict. Provider-agnostic (`--provider kubevirt\|kvm`). |
| `watch-crash.sh` | The detection engine `stakeout.sh` delegates to; also usable standalone. Polls the guest agent; when it stops answering while the domain is still alive, captures screenshot + host signals + (after reboot) the guest report, and writes `evidence-summary.json`. Detects only — never triggers. |
| `collect-from-host.sh` | libvirt/KVM host-side detector **and offline recovery**. `--mode detect` reports guest state; `--mode recover` pulls dumps off the guest disk with libguestfs when the guest is frozen or won't boot. This is your fallback when `watch-crash.sh` reports `hardFreeze`. |
| `collect-from-host.ps1` | The Hyper-V equivalent of the above (VHDX mount / LiveKd). **Not part of the OCP path** — kept for Windows hosts. |

**Capture / collect:**

| File | What it does |
|---|---|
| `collect-all.sh` | Host-side orchestrator that ties screenshot + guest report + host signals together into one evidence dir. Invoked by `run-dry-run.sh`, or as a CI post-step. |
| `capture-vm-screen.sh` | Rapid-fire `virsh screenshot` burst so at least one frame catches the blue screen before auto-reboot wipes it. **The VM must use QXL or VGA video** — virtio-video shows "Display output is not active" during a kernel crash. |
| `capture-host-dump.sh` | Last-resort dump capture from the host: `virsh dump` + QEMU's `elf2dmp` to produce a WinDbg-readable `.dmp`. Needed when the guest-side dump mechanism itself fails. Keeps the raw ELF as a backup so you can re-convert offline with correct symbols. |
| `collect-host-signals.sh` | **The only place TLB-flush / split-lock evidence exists.** Greps the host kernel log for the patterns in `data/host/host-signals.json` (notably Intel `split lock detection: #AC`) and reads the Hyper-V enlightenments out of the domain XML. None of this is visible from inside the guest. |

**Analyze:**

| File | What it does |
|---|---|
| `parse-dump-header.sh` | Reads the stop code + 4 parameters straight out of a Windows dump file header (PAGEDU64) and resolves the name — **no Windows and no debugger needed**. Great offline cross-check of what the guest reported. |

**Local test rig lifecycle:**

| File | What it does |
|---|---|
| `vmctl.sh` | Manage the local libvirt VM `bsod-test` and its `clean-baseline` snapshot: `define / snapshot / revert / start / stop / kill / console / status / ip`. |
| `bsod-test.domain.xml` | The libvirt domain definition for that golden VM (Q35 + UEFI, virtio, TPM 2.0, guest agent). |

### 4.3 `src/scripts/host/crash-injector/` — ⚠️ The Pitcher

Destructive. Never point at anything but a disposable, snapshotted VM.

| File | Runs on | What it does |
|---|---|---|
| `sweep-crashme.sh` | host | Full **synthetic** sweep: iterates all 19 codes in `data/host/trigger-methods.json`, reverting → triggering → collecting for each. This is the regression suite for the detector. |
| `sweep-chaos.sh` | host | Full **organic** sweep: 24 chaos triggers from `data/host/chaos-triggers.json`. Records "no crash" as a valid outcome. |
| `run-dry-run.sh` | host | One crash, one code: revert → boot → trigger → `collect-all.sh` → summary. Your smoke test. |
| `kvm-msr-write.py` | host, root | Writes MSRs to a live vCPU by duplicating QEMU's KVM vCPU fd via `pidfd_getfd` and issuing `KVM_SET_MSRS` — QEMU/QMP has no MSR-write command. Backs the `poison-msr-pat` and `tsc-skew-inject` triggers. |
| `prep-guest.ps1` | guest | One-time golden-guest prep: kernel-dump CrashControl, system-managed page file, installs the CrashMe driver service. Idempotent. |
| `trigger-bsod.ps1` | guest | Driver-free crash → `0xEF CRITICAL_PROCESS_DIED`. Marks itself critical then terminates itself. Fire async — the guest dies mid-call. |
| `setup-notmyfault.ps1` | guest | Downloads Sysinternals NotMyFault; `notmyfaultc64.exe /crash 0x01` → `0xD1` with `myfault.sys` as the faulting driver. Driver-based alternative to CrashMe. |
| `diag-critical-api.ps1` | guest | Validates the `RtlSetProcessIsCritical` P/Invoke **without** crashing. Use when a trigger silently no-ops. |
| `test-driver/` | build on host, load in guest | The **CrashMe** kernel driver: `crashme.c` (`KeBugCheckEx` with your chosen code + 4 params), `crashme-ctl.c` (userspace control), `.inf`, `install.ps1`, and a mingw64 `Makefile` with `ntddk-shim.h` / `ntoskrnl.def` to cross-compile a Windows driver from Linux. Build artifacts (`.sys`, `.exe`) are git-ignored. |

### 4.4 `src/scripts/lib/`

| File | What it does |
|---|---|
| `Common.ps1` | Dot-sourced by guest *and* host PowerShell — which is why it sits in neither. Provides `Get-BsodData` (loads a data file by bare name, searching `data/`, `data/guest/`, `data/host/`), `Write-JsonResult` (the single-stdout-object contract), `Fail`, `Test-IsAdministrator`. |

### 4.5 `src/data/`

| File | Location | Read by |
|---|---|---|
| `bugcheck-codes.json` | root (shared) | code → name/description. Guest collector, `parse-dump-header.sh`, host-signals cross-ref. |
| `crash-control.json` | `guest/` | `configure-dumps.ps1` — the recommended registry values. |
| `event-sources.json` | `guest/` | `collect-guest.ps1` — which event log entries make up a crash timeline. |
| `trigger-methods.json` | `host/` | `sweep-crashme.sh` — the 19 codes and their exact `KeBugCheckEx` parameters. |
| `chaos-triggers.json` | `host/` | `sweep-chaos.sh` — 24 organic triggers, 5 tiers. |
| `host-signals.json` | `host/` | `collect-host-signals.sh` — kernel-log grep patterns + Hyper-V feature list. |
| `blkdebug-read-errors.conf` | `host/` | QEMU, manually, for the `blkdebug-config` trigger. |

Only `guest/` + `bugcheck-codes.json` are ever shipped into the VM.

### 4.6 `host-tools/`, `test/`

| File | What it does |
|---|---|
| `host-tools/extract-dump.sh` | Pulls `MEMORY.DMP` / `Minidump\*.dmp` off a powered-off guest disk with libguestfs. |
| `host-tools/run.sh` | The same, inside a container, for hosts without libguestfs. |
| `test/run-tests.sh` | bats suite runner. |
| `test/test-*.bats` | JSON schema validation, cross-reference integrity, `parse-dump-header.sh` against synthetic PAGEDU64 dumps, split-lock log parsing, sweep-arg consistency, WER regex, and the driver cross-compile. |

## 5. Step by step — deliberate BSOD (kinds 1 & 2)

Use this to prove the detector works, or to produce a known dump for testing.

### 5.1 On the OCP cluster (guest agent, no SSH) — the path we actually ran

Verified end-to-end on `hjoshi-win2022` / namespace `windows-bsod` for `0xEF`
and `0xD1`.

```bash
cd apps/bsod-detector
export KUBECONFIG=<cluster kubeconfig>
export GA_VM=<vm> GA_NS=<ns>        # optional — omit if there is a single VMI

# --- 1. Stage the toolkit into the guest (one time) ---
zip -r /tmp/bsod-src.zip src
python3 src/scripts/host/guest-agent.py put /tmp/bsod-src.zip 'C:\Windows\Temp\bsod-src.zip'
python3 src/scripts/host/guest-agent.py psfile src/scripts/guest/stage-toolkit.ps1

# --- 2. Confirm the guest will actually write a dump ---
python3 src/scripts/host/guest-agent.py psfile src/scripts/guest/probe-dump-config.ps1
#   look for CrashDumpEnabled = 1 (complete) or 2 (kernel), and enough free space.
#   If not: psfile src/scripts/guest/configure-dumps.ps1, then reboot.

# --- 3. Clear old evidence so the run is unambiguous ---
python3 src/scripts/host/guest-agent.py psfile src/scripts/guest/clear-dumps.ps1

# --- 4. Trigger. Pick ONE. Fire async — the guest dies mid-call. ---
#   0xEF CRITICAL_PROCESS_DIED, no driver needed:
python3 src/scripts/host/guest-agent.py psfile src/scripts/host/crash-injector/trigger-bsod.ps1
#   ...or 0xD1 via NotMyFault (needs internet in the guest):
#   psfile src/scripts/host/crash-injector/setup-notmyfault.ps1
#   then exec: C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01

# --- 5. While it crashes, grab the blue screen ---
#   loop `virsh screenshot` inside the virt-launcher pod

# --- 6. After it reboots, collect ---
python3 src/scripts/host/guest-agent.py exec powershell.exe -NoProfile \
  -File 'C:\bsod-detector\src\scripts\guest\collect-guest.ps1'
python3 src/scripts/host/guest-agent.py get 'C:\Windows\Minidump\<file>.dmp' ./out/minidump.dmp

# --- 7. Cross-check offline, no Windows needed ---
bash src/scripts/host/parse-dump-header.sh ./out/minidump.dmp

# --- 8. Optional deep triage / full dump ---
#   psfile install-debuggers.ps1 -> analyze-dump.ps1 (or collect-guest.ps1 -Symbolize)
#   psfile compress-dump.ps1 -> guest-agent.py get MEMORY.DMP.zip
```

### 5.2 On the local libvirt rig (SSH) — the automated sweeps

```bash
cd apps/bsod-detector
export LIBVIRT_DEFAULT_URI=qemu:///system

# One crash, one code — smoke test:
./src/scripts/host/crash-injector/run-dry-run.sh --code 0x19

# All 19 KeBugCheckEx codes — the regression sweep:
./src/scripts/host/crash-injector/sweep-crashme.sh
#   -> output/sweep-<CODE>/collect-guest.json per code

# Organic chaos triggers (kind 2) — "no crash" is a valid result:
./src/scripts/host/crash-injector/sweep-chaos.sh --tier 1
./src/scripts/host/crash-injector/sweep-chaos.sh --trigger nmi-inject
```

Both sweeps assume the golden VM and its snapshot already exist. To rebuild
them, see [`../src/scripts/host/crash-injector/README.md`](../src/scripts/host/crash-injector/README.md).

> **Caveat:** `sweep-chaos.sh` is the least-exercised script here. It was
> written against the older `vm/` layout and had stale paths that were only
> fixed by inspection — treat its first run as a debugging session, not a
> regression suite.

## 6. Step by step — natural BSOD (kind 3)

**There is no trigger step.** You configure the VM into the crash-prone state,
start the watcher, run the workload, and wait. The reference scenario is the
Intel split-lock `#AC` raised during the Hyper-V *enlightened TLB-flush*
hypercall → `HYPERVISOR_ERROR (0x00020001)`, which typically **hard-freezes and
writes no minidump at all** — which is precisely why host-side capture exists.

```bash
cd apps/bsod-detector
export KUBECONFIG=<cluster kubeconfig>
```

`stakeout.sh` runs the whole campaign. Use it rather than driving the pieces by
hand — it gates on the preconditions *before* you commit hours to a watch, and
it is the only path that recovers evidence from a hard freeze.

### The short version

```bash
cd apps/bsod-detector
export KUBECONFIG=<cluster kubeconfig>

./src/scripts/host/stakeout.sh preflight --scenario tlb-flush   # gate: is this even possible?
./src/scripts/host/stakeout.sh stage                            # one-time guest setup
./src/scripts/host/stakeout.sh watch --out ./output/natural \
    --workload 'your-load-generator.sh'                         # watch, escalate, verdict
```

### Step 1 — preflight: can the crash happen, and can you capture it?

```bash
./src/scripts/host/stakeout.sh preflight --scenario tlb-flush
```

Read-only. It never modifies the VM or the node — it reports the remedy and
exits non-zero if the campaign is pointless. It checks:

| Check | Why it matters |
|---|---|
| `hyperv-enlightenments` | Both `tlbflush` **and** `ipi` must be on. Without them the TLB-flush crash **cannot occur** — with `--scenario tlb-flush` this is a hard blocker. |
| `split-lock-detect` | Node needs `split_lock_detect=warn\|on`. Without it the `#AC` line never appears **even when the crash happens** — you lose the only host-side attribution. Blocker under `--scenario tlb-flush`. |
| `pvpanic` | Present → expect `domstate` to leave `running` at bugcheck. Absent → a pure hang. Changes what detection sees. |
| `video-device` | virtio-video produces no framebuffer during a kernel crash, so no blue-screen image. |
| `guest-dump-config` | `CrashDumpEnabled` and free space — no config, no dump, and no retroactive fix. |
| `toolkit-staged` | Without it, post-reboot collection is skipped. |
| `offline-recovery`, `elf2dmp` | Whether a hard freeze can be salvaged at all. |
| `target`, `guest-agent`, `tooling`, `siblings` | The basics. |

**Neither of the two blockers is something a script should fix for you.**
Enlightenments need a VM restart; `split_lock_detect` needs a node MachineConfig
and a reboot. On a shared cluster that is your call, so preflight prints the
exact change and stops.

Use `--scenario any` when you are hunting *any* natural crash rather than the
TLB-flush one specifically — both blockers demote to warnings.

Preflight also runs offline against captured artifacts, which is handy for
checking a cluster you cannot reach directly:

```bash
./src/scripts/host/stakeout.sh preflight --scenario tlb-flush \
    --domain-xml dom.xml --node-cmdline cmdline.txt
```

### Step 2 — stage the guest

```bash
./src/scripts/host/stakeout.sh stage
```

Zips `src/`, uploads it, runs `stage-toolkit.ps1` and `configure-dumps.ps1`.
Idempotent. Needed only for the post-reboot collection step — if the guest hard
-freezes it is never used, but you cannot add it after the fact. **Reboot the
guest** if `configure-dumps` reports `rebootRequired`.

### Step 3 — stake it out

```bash
./src/scripts/host/stakeout.sh watch --out ./output/natural \
    [--duration 7200] [--workload 'CMD'] [--workload-guest load.ps1]
```

Re-runs preflight and aborts on blockers (`--skip-preflight` to override), then
delegates detection to `watch-crash.sh`. `--workload` runs your load generator
alongside the watch and kills it when the watch ends; `--duration` bounds the
campaign, and a clean timeout is recorded as a legitimate `no-crash` result.

There is deliberately no built-in workload generator — reproducing the
TLB-flush hypercall pattern is workload-specific and nothing here is validated
to do it.

### Step 4 — what happens on detection

The moment the agent goes silent while the domain is still alive
(`running|paused|crashed|pmsuspended`):

1. bursts `virsh screenshot` and picks the blue-screen frame by size — a solid
   colour frame compresses to ~36 KB, vs ~874 KB for a desktop and ~3 KB for
   DPMS-black;
2. captures the worker-node `dmesg` + domain XML and runs
   `collect-host-signals.sh` → **the only place the split-lock `#AC` shows up**;
3. then branches:
   - **guest rebooted** → `collect-guest.ps1`, pull the newest minidump,
     cross-check with `parse-dump-header.sh`;
   - **hard freeze** → **escalation** (below).

### Step 5 — escalation on hard freeze

This is the phase `watch-crash.sh` on its own does not have, and it matters
because a frozen guest still holds its memory **in host RAM**. It is the
highest-value capture window, and the last one before anyone power-cycles the VM.

1. `virsh dump --memory-only` (inside the virt-launcher pod on KubeVirt, copied
   out with `oc cp`), then `elf2dmp` → a WinDbg-readable `.dmp`. **The raw ELF is
   always kept** so a symbol mismatch can be re-converted offline later.
2. Offline disk extraction via `collect-from-host.sh --mode recover`
   (libguestfs), once the guest is powered off — `stakeout.sh` does not power it
   off for you.

You can run this phase on its own against an already-frozen VM:

```bash
./src/scripts/host/stakeout.sh escalate --out ./output/natural
```

### Step 6 — read the verdict

```bash
jq . ./output/natural/stakeout-summary.json
```

| Verdict | Means |
|---|---|
| `hard-freeze-splitlock` | Freeze **plus** a node `#AC` — the strongest available evidence for the TLB-flush `HYPERVISOR_ERROR` path. No guest dump, as expected. |
| `hard-freeze-unattributed` | Froze, but no split-lock signal. Confirm `split_lock_detect` is on — absence of the signal is not absence of the cause. |
| `bugcheck-captured` | Rebooted and a dump was recovered. Run `analyze-dump.ps1` next. |
| `crash-no-dump` | Rebooted, no dump — see the three-tier detection in §7. |
| `no-crash` | Nothing happened in the window. A valid, recorded outcome. |

### Doing it by hand

`stakeout.sh` composes existing scripts and adds nothing you cannot do
manually. The equivalent sequence is `guest-agent.py put`/`psfile` for staging,
then `watch-crash.sh --out DIR`, then `capture-host-dump.sh` and
`collect-from-host.sh --mode recover` if it freezes. Use the pieces directly if
you need to deviate.

## 7. Why a crash can produce no dump — three-tier detection

`collect-guest.ps1` does not assume a stop code exists. Organic and natural
crashes routinely bypass the traditional dump path, so it falls back:

| Tier | Signal | Means |
|---|---|---|
| 1 | `System/1001` WER BugCheck | Textbook BSOD with a stop code and a dump |
| 2 | `Application/1001` `LiveKernelEvent` | Non-fatal kernel crash; dumps land in `LiveKernelReports\` and bypass the normal mechanism |
| 3 | `System/6008` dirty shutdown, no diagnostic event | It crashed and bypassed *both* dump mechanisms |

Observed: `verifier-lowres`, `verifier-special-pool`,
`verifier-systematic-lowres` and `mce-uncorrectable` all crashed the guest and
wrote **no** `System/1001` and **no** dump. Tiers 2–3 are the only reason those
were caught at all.

## 8. Guest is frozen or won't boot — offline recovery

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system

# Just report state, no disk access:
./src/scripts/host/collect-from-host.sh --vm <name> --mode detect

# Power the guest off, then pull dumps off the disk with libguestfs:
./src/scripts/host/collect-from-host.sh --vm <name> --mode recover --out ./output/dumps

#   --force        read the disk while still running (risks an inconsistent image)
#   --virsh-dump   last resort: live guest memory as QEMU/ELF — NOT a Windows
#                  MEMORY.DMP. Convert with capture-host-dump.sh / elf2dmp.
```

## 9. Which script produces which artifact

| Artifact | Produced by |
|---|---|
| `preflight.json` | `stakeout.sh preflight` |
| `stakeout-summary.json` | `stakeout.sh` — the verdict and campaign manifest |
| `host-recovery/guest-memory.elf`, `host-recovery/host-crash.dmp` | `stakeout.sh escalate` |
| `bsod-screenshot.png` / `bsod-frame-N.png` | `watch-crash.sh`, `capture-vm-screen.sh` |
| `host-signals.json` | `collect-host-signals.sh` |
| `kern.log`, `dom.xml` | `watch-crash.sh` (inputs to the above) |
| `collect-guest.json` | `collect-guest.ps1` |
| `Minidump/*.dmp`, `MEMORY.DMP` | guest copy, or `collect-from-host.sh --mode recover` |
| `parse-dump-header.json` | `parse-dump-header.sh` |
| `host-crash.dmp` + `guest-memory.elf` | `capture-host-dump.sh` |
| `evidence-summary.json` | `watch-crash.sh`, `collect-all.sh` |

## 10. Gotchas worth knowing before you start

- **No dump config, no dump.** `configure-dumps.ps1` (or `prep-guest.ps1`)
  must have run *and the guest rebooted* before the crash. There is no
  retroactive fix.
- **Screenshots need QXL or VGA.** virtio-video reports "Display output is not
  active" during a kernel crash, so you get nothing.
- **The most interesting crash writes no dump.** `HYPERVISOR_ERROR` hard-freezes.
  Host-side signals are the whole evidence package — don't skip §6 step 1.
- **Driver Verifier is on in the golden guest** and changes outcomes: `0x0A` is
  observed as `0xD1`. `trigger-methods.json` records codes *as observed*, not as
  theorised. If you turn Verifier off, re-run the sweep to re-baseline.
- **`MEMORY.DMP` is locked and large.** Use `compress-dump.ps1` before `get`.
- **Guest-agent reads are capped by the QMP payload limit** — 2 MB works, 4 MB
  fails. `guest-agent.py get` seeks and retries per chunk for this reason.
- **Never commit captured dumps or logs** — they carry host-identifying data.
  `output/` is git-ignored; keep them there.

## Related

- [`../src/scripts/README.md`](../src/scripts/README.md) — per-script inputs and exact JSON output contracts
- [`../MANIFEST.md`](../MANIFEST.md) — one-line catalog of every shipped file
- [`natural-bsod-workflow.md`](natural-bsod-workflow.md) — the §6 runbook in depth
- [`../src/scripts/host/crash-injector/README.md`](../src/scripts/host/crash-injector/README.md) — the Pitcher, and rebuilding the test VM
- [`architecture.md`](architecture.md) — component overview
- [`integration.md`](integration.md) — CI post-mortem, exit codes, agent-driven triage
- [`architecture-review-response.md`](architecture-review-response.md) — open design work
