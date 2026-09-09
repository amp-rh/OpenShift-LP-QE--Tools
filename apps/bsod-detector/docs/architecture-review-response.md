# RFC: Architecture Review Response — BSOD Detector

**Status:** Draft for review (hjoshi + amp-rh) · target PR #19 · 2026-09-04

Captures the decisions and implementation plan for the seven-point architecture
& design review. Nothing here changes runtime behavior on its own — the large
items (#1 restructure, #2, #3, #6, #7) are **planned**, not yet implemented, so
they can be reviewed and sequenced before code lands. Small, self-contained items
(#4, #5, and the `data/` classification part of #1) are **already applied** as
local edits.

## Decisions at a glance

| # | Review point | Decision | Status |
|---|---|---|---|
| 4 | Document CrashMe-vs-NotMyFault tradeoff | **Adopt** | ✅ Done ([development-notes.md](development-notes.md#the-tradeoff-stated-plainly)) |
| 5 | Preserve raw ELF, stop discarding source | **Adopt** | ✅ Done (`capture-host-dump.sh`) |
| 1 | Separate guest/host; classify `data/` | **Adopt** (data classification done; file moves planned) | ◐ Partial |
| 3 | RHOV/KubeVirt backend abstraction | **Adopt** | ☐ Planned (Phase 2) |
| 6 | pvpanic race → capture-then-let-Windows-finish | **Adopt, pending crash validation** | ☐ Planned (Phase 3) |
| 2 | Minimize guest artifacts (offline-only) | **Adopt as target** | ☐ Planned (Phase 3) |
| 7 | Unified offline collection flow | **Adopt as end state** | ☐ Planned (Phase 4) |

---

## 1. Guest/host separation + `data/` classification

**Decision:** Adopt. Split by subdirectory rather than filename prefix.

**Done now (safe):** `src/data/README.md` now classifies each table as
guest-staged (`crash-control`, `event-sources`, `bugcheck-codes`) vs host-only
(`trigger-methods`, `chaos-triggers`, `host-signals`, `blkdebug-read-errors`).

**Planned (large, deferred):** move scripts to `src/scripts/guest/` and
`src/scripts/host/` (keeping `crash-injector/` under `host/`). The blast radius
is why this is deferred, not skipped:

- Every relative path in the 63 bats tests (`test/*.bats`)
- Container image (`image/container/bsod-detector/Dockerfile` copy paths)
- `MANIFEST.md`, all `README.md` trees, and doc links
- Guest staging paths (`stage-toolkit.ps1`, `prep-guest.ps1` → `C:\bsod-detector\scripts`)

**Migration approach:** `git mv` in one commit, then a mechanical
find-replace of path references, then `test/run-tests.sh` must stay green. Do
this *before* #7 so the offline rewrite lands in the final layout.

---

## 3. KVM / KubeVirt (RHOV) backend abstraction

**Decision:** Adopt. This is the highest-value item — the tool is currently
`virsh`-only and RHOV has no `virsh`. It aligns with the `virtctl`/krkn-lib
exploration already done in the `bsodpoc` POC.

**Design:** a backend shim selected by `BSOD_DET__HYP_PROV=kvm|kubevirt`,
exposing one stable interface that every orchestration script calls instead of
`virsh` directly:

```
DetectCrash   StartVM   StopVM   RestartVM   SSHCmd
Screenshot    SnapshotCreate   SnapshotRevert   MemoryDump
GuestIP       DomainState
```

| Capability | `kvm` (virsh) | `kubevirt` (virtctl / oc) |
|---|---|---|
| start/stop/restart | `virsh start/destroy/reset` | `virtctl start/stop/restart` |
| SSH | direct SSH | `virtctl ssh` |
| screenshot | `virsh screenshot` | `virtctl vnc screenshot` |
| snapshot | `virsh snapshot-create-as/revert` | `VirtualMachineSnapshot`/`Restore` CRDs (volume-only, cold — acceptable) |
| pvpanic setup | `virsh define` (`EnsurePvpanicConfig()`) | declarative in VM YAML (one-time) |
| crash detection | `virsh event --lifecycle` (blocking) | `oc get events -w` on pvpanic events (**KubeVirt ≥ v1.8.0**) |
| memory dump | `virsh dump --memory-only` (ELF) | `virtctl memory-dump` (raw, not ELF) |
| guest IP | `virsh domifaddr` | `oc get vmi -o jsonpath` |
| domain state | `virsh domstate` | **VMI `status.phase` + guest-agent liveness** (see note) |
| ACPI suspend | `virsh dompmsuspend` | no equivalent (affects 1 chaos trigger) |

**Correction to the review's table:** the "domain state → N/A" row overstates
it. On KubeVirt you have `VMI.status.phase` plus qemu-guest-agent liveness — a
VMI that is `Running` but stops answering guest-ping is the crash signature that
`watch-crash.sh` and the `bsodpoc` krkn-lib test already use. So `DetectCrash`
on KubeVirt should combine pvpanic events *and* guest-agent liveness, not rely on
VMI exit alone.

**Caveats to encode:** `virtctl memory-dump` emits raw (not ELF) — so the
`elf2dmp` path either changes format handling or (better, see #6) is dropped in
favor of offline `MEMORY.DMP` extraction. KubeVirt snapshots are volume-only (no
live memory) — fine for the cold revert→trigger→collect loop, not for live-memory
snapshots.

---

## 6. pvpanic race condition + capture strategy

**Decision:** Adopt, but gate on real-crash validation (needs the test VM).

**The problem (agreed):** with `on_crash=preserve`, pvpanic fires its callback
*before* `IoWriteCrashDump()` runs, QEMU pauses the VM, and the guest-written
`MEMORY.DMP` is never produced — which is the only reason the `elf2dmp` pipeline
exists.

**Why the fix is sound:** at `KeBugCheckEx` time IRQL is `HIGH_LEVEL` with
interrupts disabled, so the forensic memory (kernel stacks, KDBG, loaded modules,
bugcheck data) is already frozen; the dump write is a read-only scan into a
pre-allocated buffer. So we can capture host-side memory immediately *and* let
Windows finish its own dump without either altering crash-relevant memory.

**Target sequence:**
1. Capture VM memory immediately after pvpanic → **backup**, raw (ELF/raw), no conversion.
2. Let Windows complete the dump write (`AutoReboot=0` in `CrashControl`).
3. Wait for guest idle (I/O quiescence or generous timeout).
4. Stop the VM; extract `MEMORY.DMP` offline → **primary** artifact (native WinDbg, no conversion).

**Result:** no `elf2dmp` at runtime, no Microsoft PDB download, no race. The #5
change (preserve raw ELF) is the first step of this and is already in.

**Validation required:** must be proven against a real BSOD on the KVM (and
later KubeVirt) test VM before removing the current `elf2dmp` path — I cannot
verify this from this session without that environment.

---

## 2 & 7. Minimize guest artifacts → unified offline collection

**Decision:** Adopt as the end state, after #1/#3/#6 land.

**Target flow:**
```
Trigger BSOD → pvpanic fires
  → capture VM memory immediately (backup, raw)
  → let Windows write MEMORY.DMP (AutoReboot=0)
  → wait idle → stop VM
  → guestfs offline extraction: MEMORY.DMP, Minidump/*.dmp, *.evtx
  → host-side analysis:
       parse-dump-header.sh (stop code + params)
       .evtx parsing (python-evtx, replaces Get-WinEvent)
       bugcheck-codes.json lookup
       collect-host-signals.sh (kernel log + Hyper-V correlation)
  → JSON report + dumps + raw backup → restart VM
```

**Eliminates:** guest-side PowerShell collection, `lib/Common.ps1`, guest data
staging, SSH-based evidence collection, runtime `elf2dmp`/PDB downloads, and
`analyze-dump.ps1`/`cdb.exe` (symbolized analysis becomes the developer's job
with their own tools — explicitly out of scope).

**What remains:** `src/data/` (host-side), the CrashMe driver (trigger),
`parse-dump-header.sh`, `collect-host-signals.sh`, a **new `.evtx` parser**, the
#3 backend abstraction, and a guestfs extraction script (`host-tools/` already
does the disk mount).

**The one real risk to flag:** a Linux `.evtx` parser (`python-evtx`) must
reproduce the crash-timeline fidelity of `Get-WinEvent` (System/1001,
Application/1001 LiveKernelEvent, System/6008). This needs a fidelity check
against known-good guest-collected output (`docs/sample-output/*.json`) before we
retire `collect-guest.ps1`. Recommend keeping guest-side collection available
behind a flag until the offline path is proven equivalent.

---

## Phased roadmap

1. **Phase 0 (done):** #4 doc, #5 raw-ELF preserve, #1 data classification.
2. **Phase 1:** #1 file restructure (`guest/` + `host/`), keep tests green.
3. **Phase 2:** #3 backend abstraction (`kvm` first to preserve current behavior, then `kubevirt`).
4. **Phase 3:** #6 capture sequence + `AutoReboot=0`; validate on a real crash; add `.evtx` parser alongside `collect-guest.ps1`.
5. **Phase 4:** #7 flip primary path to offline; retire guest-side collection once `.evtx` fidelity is confirmed.

## Validation the plan depends on (not available from this session)

- A live **KVM** test VM (`bsod-test`) to validate #6's capture sequence and the `.evtx` parser fidelity.
- A live **KubeVirt** cluster (KubeVirt ≥ v1.8.0 for pvpanic events) to validate the `kubevirt` backend and `virtctl memory-dump`.

## Open questions for hjoshi + amp-rh

- Land all phases in **PR #19**, or split #3/#7 into the already-planned follow-up PRs?
- Retire `analyze-dump.ps1`/`cdb` entirely, or keep it as an optional guest-side convenience?
- Is `python-evtx` an acceptable new host dependency (added to the container image)?
