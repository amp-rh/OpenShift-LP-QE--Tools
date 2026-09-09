# Natural-BSOD Detection Workflow (the "Catcher")

> Runbook for detecting a **naturally-occurring** Windows BSOD/freeze on an
> OpenShift Virtualization (KubeVirt) VM and auto-capturing evidence — **with no
> deliberate trigger**. For the deliberate-crash path (validating the detector)
> see [`../src/scripts/host/crash-injector/README.md`](../src/scripts/host/crash-injector/README.md)
> (the "Pitcher"). For CI/agent integration patterns see
> [`integration.md`](integration.md).

## When to use this

Use this flow for crashes that happen **on their own** — e.g. the Intel
split-lock `#AC` during the Hyper-V enlightened TLB-flush hypercall
(`HYPERVISOR_ERROR 0x00020001`), or any organic fault (see
[`../src/data/host/chaos-triggers.json`](../src/data/host/chaos-triggers.json)). Nothing
is injected; you *watch* a live VM and capture the moment it crashes.

The single entry point is [`../src/scripts/host/stakeout.sh`](../src/scripts/host/stakeout.sh),
which runs the campaign end to end: **preflight → stage → watch → escalate →
verdict**. It delegates detection to
[`watch-crash.sh`](../src/scripts/host/watch-crash.sh) (still usable standalone)
and adds the two things a bare watch cannot do — gating on the preconditions
before you commit to a long watch, and recovering evidence from a hard freeze.
Both use the **qemu-guest-agent** (no SSH) and auto-detect the VMI when there is
exactly one on the cluster.

```bash
./src/scripts/host/stakeout.sh preflight --scenario tlb-flush
./src/scripts/host/stakeout.sh stage
./src/scripts/host/stakeout.sh watch --out ./output/natural
```

The step-by-step walkthrough, including what each preflight check gates on, is
in [`file-guide.md`](file-guide.md#6-step-by-step--natural-bsod-kind-3).

## Prerequisites

**Operator box (where you run `watch-crash.sh`):**
- `oc`, `python3`, `jq`, and `virtctl` on `PATH`
- `KUBECONFIG` exported and pointing at the cluster
- These scripts co-located (same dir as `watch-crash.sh`): `guest-agent.py`,
  `collect-host-signals.sh`, `parse-dump-header.sh`

**Guest (one-time staging, so post-reboot collection works):**
- `qemu-guest-agent` installed and running in the Windows guest
- Toolkit staged in the guest via
  [`stage-toolkit.ps1`](../src/scripts/guest/stage-toolkit.ps1) (needed for the
  `collect-guest.ps1` step)
- Crash dump configured via
  [`configure-dumps.ps1`](../src/scripts/guest/configure-dumps.ps1) (or
  `crash-injector/prep-guest.ps1`) so a dump is written on the next BSOD —
  `CrashControl` set to a kernel/complete dump, system-managed page file

## The workflow

```
export KUBECONFIG=<cluster kubeconfig>

# Watch (auto-detects the single VMI; pass --ns/--vm only to disambiguate):
./src/scripts/host/watch-crash.sh \
    [--ns <namespace>] [--vm <name>] \
    [--out <evidence-dir>] \
    [--interval 5]      # seconds between guest-agent health polls
    [--miss 3]          # consecutive missed pings (domain still 'running') => crash
    [--node <worker>]   # worker node for the kernel log (auto-detected if omitted)
    [--reboot-wait 300] # seconds to wait for the guest to reboot after a crash
```

### What happens, step by step

1. **Poll.** `watch-crash.sh` pings the guest-agent every `--interval` seconds.
2. **Detect.** When the guest misses `--miss` consecutive pings *while the domain
   is still alive* (`domstate` in `running|paused|crashed|pmsuspended` — pvpanic
   can move a bug check out of `running`), that is the classic BSOD/hang
   signature and capture begins immediately.
3. **Screenshot.** Bursts `virsh screenshot` from the `virt-launcher` pod to
   catch the blue screen → `bsod-screenshot.png`.
4. **Host signals.** Captures the worker-node kernel log + domain XML and runs
   `collect-host-signals.sh` → `host-signals.json`. **This is the only place a
   TLB-flush / `HYPERVISOR_ERROR` is visible — it never appears in the guest
   dump.**
5. **Reboot or freeze.** Waits up to `--reboot-wait`:
   - **Rebooted** → runs `collect-guest.ps1`, pulls the minidump, cross-checks it
     offline with `parse-dump-header.sh`.
   - **Hard freeze** (common for `HYPERVISOR_ERROR`) → records `hardFreeze` and
     stops; continue with the offline path below.
6. **Summarize.** Everything lands in one evidence directory, tied together by
   `evidence-summary.json` (`crashDetected`, `guestRebooted`/`hardFreeze`,
   `bugCheck`, `splitLockDetected`).

### Three-tier crash detection (inside `collect-guest.ps1`)

Organic crashes frequently **bypass the traditional crash dump**, so detection
falls back through three tiers — this is why the detector catches them at all:

1. **bugcheck** — `System/1001` WER BugCheck (traditional BSOD with stop code)
2. **livekernelevent** — `Application/1001` `LiveKernelEvent` (dumps in
   `LiveKernelReports\`, bypasses the traditional dump)
3. **dirtyshutdown** — `System/6008` dirty shutdown with no diagnostic event
   (crash that bypassed both dump mechanisms entirely)

> Verified example: `verifier-lowres`, `verifier-special-pool`,
> `verifier-systematic-lowres`, and `mce-uncorrectable` all crashed but wrote
> **no** `System/1001` and **no** dump — they were caught only at tiers 2–3.

## Guest frozen or unbootable (offline recovery)

When the guest won't reboot, recover the dump off the disk from the host:

```
./src/scripts/host/collect-from-host.sh --vm <name> --mode recover [--out <dir>]
#   --mode detect   report guest state only (no disk access)
#   --mode recover  detect, then pull MEMORY.DMP / Minidump\*.dmp offline
#                   (libguestfs via host-tools/extract-dump.sh)
#   --virsh-dump    last resort: capture live guest memory (QEMU/ELF, not a
#                   Windows crash dump); briefly pauses the guest
```

## Deep triage (optional, needs Windows + cdb + symbols)

```
# On a Windows box with Debugging Tools for Windows:
analyze-dump.ps1 -DumpPath <MEMORY.DMP or minidump>
# -> failure bucket, faulting image/module, bugcheck code + params, top stack
```

## Output artifacts (one evidence directory)

| Artifact | Produced by | Contents |
|---|---|---|
| `bsod-screenshot.png` | `virsh screenshot` burst | Blue-screen framebuffer |
| `host-signals.json` | `collect-host-signals.sh` | Node kernel log + Hyper-V config; split-lock/TLB-flush signals |
| `collect-guest.json` | `collect-guest.ps1` | Three-tier crash record, events, system context |
| `Minidump/*.dmp`, `MEMORY.DMP` | guest copy / offline recovery | Crash dumps |
| `evidence-summary.json` | `watch-crash.sh` | Manifest: `crashDetected`, `guestRebooted`/`hardFreeze`, `bugCheck`, `splitLockDetected` |

## Related

- [`file-guide.md`](file-guide.md) — what every file does; the natural vs organic vs synthetic crash distinction
- [`integration.md`](integration.md) — CI post-mortem, agent-driven triage, exit codes, decision tree
- [`architecture.md`](architecture.md) — component overview
- [`../src/scripts/README.md`](../src/scripts/README.md) — per-script catalog + JSON contracts
- [`../src/data/host/chaos-triggers.json`](../src/data/host/chaos-triggers.json) — organic trigger definitions (for validation)
