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
(`src/scripts/crash-injector/test-driver/crashme.sys`).
- **Consumers:** `src/scripts/crash-injector/sweep-crashme.sh` reads trigger parameters. Any reporting
  step can check `verified` status.

### `event-sources.json`
Crash-relevant event log `log` / `source` / `eventId` entries with meaning.
- **Consumers:** the guest collector to build the crash timeline.

### `host-signals.json`
Linux/KVM **host-side** crash-correlation signals invisible from inside the
guest: kernel-log grep patterns (e.g. Intel split-lock `#AC` traps) and the
Hyper-V enlightenment features (`tlbflush`, `ipi`, ...) to read from the libvirt
domain XML.
- **Consumers:** `src/scripts/collect-host-signals.sh` reads both `kernelLogSignals` and
  `hypervEnlightenments`. Each signal's `relatedBugCheck` must resolve in
  `bugcheck-codes.json`.

## Validation

Keep JSON valid and cross-references intact:

```bash
for f in src/data/*.json; do python3 -c "import json;json.load(open('$f'))" \
  && echo "OK  $f" || echo "BAD $f"; done

# every trigger-methods code should exist in bugcheck-codes.json
python3 - <<'EOF'
import json
tm=json.load(open('src/data/trigger-methods.json'))['codes']
bc=set(json.load(open('src/data/bugcheck-codes.json'))['codes'])
bad=[k for k in tm if k not in bc]
print("MISSING:",bad) if bad else print("all trigger-methods codes resolve")
EOF
```
