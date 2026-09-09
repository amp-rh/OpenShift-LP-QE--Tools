# Data — source-of-truth lookups

Shared lookup tables. Scripts **read** these; they never inline or duplicate the
values. If a table is wrong, fix it here once and every consumer picks it up.

## Files

### `bugcheck-codes.json`
Bug-check (stop) code -> name + description. Keyed by canonical `0x`-prefixed
8-digit hex string.
- **Consumers:** dump parser, collector, any reporting step.
- Curated subset (test-harness codes + common real-world crashes). Extend as needed.

### `crash-control.json`
Crash-dump registry configuration under `CrashControl`, dump-type semantics, and
page-file requirements.
- **Consumers:** `configure-dumps.ps1` applies `recommended.values`; the
  collector verifies live settings match before trusting a dump exists.

### `trigger-methods.json`
How each bug-check code is triggered in the test harness: method, parameters,
and verification status. All 19 codes use the KeBugCheckEx driver
(`src/scripts/host/crash-injector/test-driver/crashme.sys`).
- **Consumers:** `src/scripts/host/crash-injector/sweep-crashme.sh` reads trigger parameters. Any reporting
  step can check `verified` status.

### `event-sources.json`
Crash-relevant event log `log` / `source` / `eventId` entries with meaning.
Covers traditional BugCheck events (System/1001), dirty shutdowns (6008),
boot markers (6009, 12, 13), Kernel-Power (41), WER buckets (Application/1001
including LiveKernelEvent), WHEA (18), and Kernel-LiveDump (System/1).
- **Consumers:** the guest collector to build the crash timeline and for
  fallback detection (LiveKernelEvent, dirty shutdown).

### `host-signals.json`
Linux/KVM **host-side** crash-correlation signals invisible from inside the
guest: kernel-log grep patterns (e.g. Intel split-lock `#AC` traps) and the
Hyper-V enlightenment features (`tlbflush`, `ipi`, ...) to read from the libvirt
domain XML.
- **Consumers:** `src/scripts/host/collect-host-signals.sh` reads both `kernelLogSignals` and
  `hypervEnlightenments`. Each signal's `relatedBugCheck` must resolve in
  `bugcheck-codes.json`.

### `chaos-triggers.json`

Organic (non-KeBugCheckEx) fault injection trigger definitions for chaos
testing. Each trigger defines a host-side or guest-side scenario that may
produce a real BSOD through actual failure conditions.
- **Consumers:** `src/scripts/host/crash-injector/sweep-chaos.sh` reads trigger parameters, method type,
  snapshot name, guest workload, expected codes, and timeout.
- 24 triggers across 5 tiers: host-side fault injection (NMI, balloon,
  device hot-remove, network toggle, vCPU hot-remove), Driver Verifier
  stress (low resources, special pool, DDI compliance, deadlock detection),
  block I/O throttle/error injection and guest resource exhaustion,
  Hyper-V enlightenment permutation, and hardware-level faults
  (MCE injection, MSR corruption, ACPI S3, pause/resume desync).

### `blkdebug-read-errors.conf`

QEMU blkdebug configuration for injecting EIO on read operations. Used
with the `blkdebug-config` chaos trigger (requires manual domain XML
setup with `qemu:commandline` namespace).
- **Consumers:** manual QEMU configuration for advanced chaos testing.

## Staging: host-side vs guest-side

Not every table needs to live on the guest. The directory layout **enforces** the
classification rather than just documenting it, which keeps the guest footprint
minimal (and matters for the offline-collection direction, where the guest should
carry no tool data at all):

```
data/
├── bugcheck-codes.json   # shared: both sides need it
├── guest/                # staged on the guest
│   ├── crash-control.json
│   └── event-sources.json
└── host/                 # never staged on the guest
    ├── trigger-methods.json
    ├── chaos-triggers.json
    ├── host-signals.json
    └── blkdebug-read-errors.conf
```

| File | Location | Staged on guest? | Rationale |
|---|---|---|---|
| `crash-control.json` | `guest/` | **Yes** | `configure-dumps.ps1` applies it inside the guest |
| `event-sources.json` | `guest/` | **Yes** | the guest collector builds the crash timeline from it |
| `bugcheck-codes.json` | *(root)* | **Yes** | the guest collector resolves code -> name; also used host-side (parser, host-signals cross-ref), so it belongs to neither side exclusively |
| `trigger-methods.json` | `host/` | **No** | host-only: `sweep-crashme.sh` reads it |
| `chaos-triggers.json` | `host/` | **No** | host-only: `sweep-chaos.sh` reads it |
| `host-signals.json` | `host/` | **No** | host-only: `collect-host-signals.sh` reads it |
| `blkdebug-read-errors.conf` | `host/` | **No** | host-only: QEMU configuration |

Only `guest/` plus `bugcheck-codes.json` need to be present in the guest. If
guest-side collection is ever replaced by offline (`guestfs`) extraction, even
those move host-side and the guest carries no data at all.

PowerShell callers are unaffected by the split: `Get-BsodData 'crash-control.json'`
resolves the name against the root, `guest/`, then `host/`.

## Validation

Keep JSON valid and cross-references intact:

```bash
for f in src/data/*.json; do python3 -c "import json;json.load(open('$f'))" \
  && echo "OK  $f" || echo "BAD $f"; done

# every trigger-methods code should exist in bugcheck-codes.json
python3 - <<'EOF'
import json
tm=json.load(open('src/data/host/trigger-methods.json'))['codes']
bc=set(json.load(open('src/data/bugcheck-codes.json'))['codes'])
bad=[k for k in tm if k not in bc]
print("MISSING:",bad) if bad else print("all trigger-methods codes resolve")
EOF

# every host-signals relatedBugCheck should exist in bugcheck-codes.json
python3 - <<'EOF'
import json
hs=json.load(open('src/data/host/host-signals.json'))['kernelLogSignals']
bc=set(json.load(open('src/data/bugcheck-codes.json'))['codes'])
bad=[s['id']+':'+s['relatedBugCheck'] for s in hs if s.get('relatedBugCheck') and s['relatedBugCheck'] not in bc]
print("MISSING:",bad) if bad else print("all host-signals relatedBugCheck values resolve")
EOF
```
