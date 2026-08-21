# BSOD Detector

A Windows tool that detects Blue Screen of Death (BSOD) events and dumps all relevant diagnostic information for post-mortem analysis.

## Goal

When Windows hits a BSOD, capture and persist everything useful for root-cause analysis:

- The bug check (stop) code and its parameters
- Faulting driver / module, if identifiable
- Crash dump files (`MEMORY.DMP`, minidumps in `C:\Windows\Minidump\`)
- Relevant System and Application event log entries around the crash
- Basic system context (OS build, uptime, recent driver/update changes)

Detection is **implicit**: the collector catches any bug-check code that occurs,
not just a pre-defined set. The `src/data/trigger-methods.json` file defines the
19 codes we deliberately exercise in CI using the KeBugCheckEx test driver.

Keep it simple. Prefer a small, well-defined tool over a broad framework.

## Conventions

### Scripts as tooling

Deterministic operations live in scripts with clear stdin/stdout contracts.

- **Scripts produce facts; humans make decisions.** Data collection, parsing dump files, reading event logs, and formatting output belong in scripts. Interpreting a crash or deciding how to act on it is a human call.
- All executable tooling goes under `src/scripts/`. Each script does one thing and prints structured output (prefer JSON to stdout) so downstream steps can consume it.
- Every script is documented in [`src/scripts/README.md`](src/scripts/README.md): what it does, its inputs, and its output shape.
- **No hardcoded duplicated data.** Bug-check code tables, driver mappings, and log source names come from a single source-of-truth file that scripts read; never copy the same lookup into multiple scripts.

### Style

- Windows-first. Scripts are PowerShell (`.ps1`) unless there is a reason to use another language; note the requirement at the top of each script.
- Keep functions small and testable. Fail loudly with clear error messages.
- Never require interactive input in a script that may run unattended after a crash.

## Quick start

Run the full verification sweep (requires the test VM; see [`vm/README.md`](vm/README.md)):

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
./vm/sweep-crashme.sh
```

Run the unit test suite (no VM needed):

```bash
cd test && bash run-tests.sh
```

Or use the scripts individually in your own pipeline; see
[**docs/integration.md**](docs/integration.md) for CI/CD patterns, JSON
contracts, the safety model, and agentic usage.

## Layout

```
apps/bsod-detector/
├── README.md              # This file
├── src/
│   ├── scripts/           # Guest-side PowerShell tooling (one job each)
│   │   └── README.md      # Script catalog: purpose, inputs, output shape
│   ├── data/              # Source-of-truth lookups (bug-check codes, log sources)
│   └── test-driver/       # KeBugCheckEx kernel driver (cross-compiled with mingw64)
├── test/                  # bats unit test suite (run-tests.sh)
├── docs/                  # Design notes and usage
│   ├── integration.md     # CI/CD and agentic integration guide
│   └── tool-selection.md
├── vm/                    # Test VM definition + management (libvirt/KVM)
│   └── README.md          # Golden VM, snapshots, and one-command test loop
└── .gitignore             # Ignores build artifacts, output, and secrets
```

Container image definition is at `image/container/bsod-detector/`.

## Notes

- BSOD dumps and event logs may contain host-identifying data. Do not commit captured dumps or logs to the repo; keep them under the ignored `output/` directory.
- When adding a new capture step, wire it into the main detector entry point and document it in `src/scripts/README.md` in the same change.
