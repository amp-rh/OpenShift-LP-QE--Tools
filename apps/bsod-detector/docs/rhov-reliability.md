# RHOV reliability contract

The automated watcher and snapshot-recovery pipeline supports OpenShift
Virtualization/KubeVirt only. The KVM scripts remain separate development tools;
they are not fallback paths for this pipeline. The behavior below is covered by
fixtures and command mocks. It has not been validated against a live cluster in
this repository change.

## Required preflight state

`preflight-rhov.sh` is read-only and fails before the watcher arms unless all of
these conditions hold:

- `oc`, `virtctl`, `jq`, `python3`, `sha256sum`, `findmnt`, and `timeout` exist.
- The named `VirtualMachine` has `spec.runStrategy: Manual`. The tool reports the
  mismatch and never patches it automatically.
- Exactly one running VMI and virt-launcher pod match the explicit namespace and
  VM name.
- Exactly one Block-mode guest PVC/system disk can be selected, or the operator
  supplies a previously verified `--disk-target`.
- The configured CSI `VolumeSnapshotClass`, source `StorageClass`, snapshot API,
  and required namespaced RBAC verbs are available.
- The recovery image is supplied by immutable digest. It must contain Bash,
  `guestfish`, and the packaged BSOD helpers.
- The evidence directory is writable and backed by durable storage. Overlay,
  tmpfs, and ramfs destinations are rejected. In a container, mount a PVC or
  other persistent volume at `/evidence`.
- QGA responds, CrashControl matches `src/data/crash-control.json`,
  `AutoReboot=0`, the page-file check does not fail, and the Windows dump paths
  exist. Intentional-crash preflight additionally checks the exact NotMyFault
  executable path.

`configure-dumps.ps1` accepts `-DataFile`; `guest-agent.py psfile` stages that
JSON companion explicitly. Guest process exit codes are returned to the caller,
so an unsuccessful diagnostic cannot be mistaken for a successful preflight.

## Detection and dump-completion rules

The watcher uses a small, fixture-tested state machine:

- Below the configured QGA miss threshold it continues observing.
- At the threshold, a current (watch-only) pvpanic event corroborates a crash.
- Otherwise, a still-running VMI, an existing launcher, and a pod-local domain
  state of `paused`, `crashed`, or `pmsuspended` corroborate a crash/freeze.
- Domain state `running` with a dead QGA is still ambiguous without pvpanic; it
  can also describe a guest-agent-only failure or control-plane impairment.
- `unknown` or unavailable domain state is ambiguous. The watcher writes a
  detection-stage error and exits nonzero at the threshold; it does not loop
  from miss 2 through miss 108.
- Missing VMI/launcher state is a control-plane failure, not crash evidence.

Before stopping the VMI, the watcher monitors `wr.bytes` for the selected disk
target. It records a baseline, requires a strictly increasing counter, and only
accepts completion after that progress is followed by the configured number of
unchanged samples. Missing statistics, counter regression, no progress, and
quiescence timeout are failures. In those cases the watcher preserves captured
diagnostics and does not stop the VM.

## Durable recovery and artifacts

Preflight writes `recovery-metadata.json` before stop. It contains the launcher,
domain, node, PVC, disk target, snapshot/storage classes, volume mode/size, and
digest-pinned recovery image. After `virtctl stop` confirms the VMI is absent or
terminal, recovery uses only the PVC/snapshot fields; disappearance of the old
launcher is expected.

The recovery pod mounts the snapshot read-only as a block device. `guestfish`
downloads each requested guest file to `/dev/stdout`, and `oc exec` streams it
directly to a temporary file in the durable evidence directory. The pod has no
`/out` volume and never stages dump or raw-memory files under launcher `/tmp`.
Its only scratch space is a bounded memory-backed `/tmp` used by libguestfs.
Cleanup deletes the recovery pod before its PVC and snapshot and is protected by
an exit trap.

| Artifact class | Validation before publication |
|---|---|
| Screenshot | command success, nonzero size, PNG or PPM signature; extension matches format |
| Raw VM memory | streamed directly from pod-local virsh, nonzero ELF signature |
| `MEMORY.DMP` / minidump | command success and `PAGEDU64` or `MDMP` signature |
| EVTX | command success and `ElfFile\0` signature |
| Logs/JSON | nonzero or parseable, as applicable |

Every published artifact has a byte count and SHA-256 in the generated summary.
Recovery also writes `checksums.sha256` before deleting cluster resources.
`stage-errors.jsonl` records stage-specific failures. Summary `ok` is derived:
it is true only when no stage errors or invalid artifacts exist and screenshot,
raw memory, a Windows dump, EVTX, and logs are all present. Missing files are not
listed as artifacts. `recovery-summary.json` and `evidence-summary.json` are
written atomically and the scripts return nonzero when their required predicate
is false.

## Safe fixture validation

These commands do not contact infrastructure:

```bash
python3 -m unittest -v apps/bsod-detector/test/test_reliability.py
bats apps/bsod-detector/test/test-rhov-reliability.bats
```

The recovery Bats test supplies an `oc` shim, snapshot/VMI fixtures, and binary
signature fixtures. It verifies recovery after launcher disappearance, durable
stream paths, EVTX export, cleanup order contracts, and truthful summaries.
