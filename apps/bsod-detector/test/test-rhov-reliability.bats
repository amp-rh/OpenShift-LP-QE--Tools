#!/usr/bin/env bats

load test-helper

setup() {
  setup_temp
  HOST_DIR="$REPO_ROOT/src/scripts/host"
  RELIABILITY="$HOST_DIR/reliability.py"
  FIXTURES="$REPO_ROOT/test/fixtures"
}

teardown() {
  teardown_temp
}

@test "domstate unknown fails closed at the configured threshold" {
  run python3 "$RELIABILITY" decision --misses 2 --threshold 2 \
    --domstate unknown --vmi-phase Running --pod-present
  [ "$status" -ne 0 ]
  [ "$(jq -r .reason <<<"$output")" = "ambiguous-domstate-unknown" ]

  run python3 "$RELIABILITY" decision --misses 108 --threshold 2 \
    --domstate unknown --vmi-phase Running --pod-present
  [ "$status" -ne 0 ]
  [ "$(jq -r .decision <<<"$output")" = "fail" ]
}

@test "current pvpanic event corroborates an unavailable domain state" {
  run python3 "$RELIABILITY" decision --misses 2 --threshold 2 \
    --domstate unavailable --vmi-phase Running --pod-present --pvpanic
  [ "$status" -eq 0 ]
  [ "$(jq -r .decision <<<"$output")" = "capture" ]
}

@test "running domain without pvpanic fails closed as ambiguous" {
  run python3 "$RELIABILITY" decision --misses 2 --threshold 2 \
    --domstate running --vmi-phase Running --pod-present
  [ "$status" -ne 0 ]
  [ "$(jq -r .reason <<<"$output")" = "ambiguous-domstate-running" ]
}

@test "disk protocol requires progress followed by quiescence" {
  run bash -c "python3 '$RELIABILITY' progress-sequence --device vda --idle-samples 3 < '$FIXTURES/domstats-progress.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = "progress-then-quiescence" ]
}

@test "disk protocol rejects no-progress timeout and missing statistics" {
  run bash -c "python3 '$RELIABILITY' progress-sequence --device vda < '$FIXTURES/domstats-no-progress.json'"
  [ "$status" -ne 0 ]
  [ "$(jq -r .reason <<<"$output")" = "no-progress-timeout" ]

  run bash -c "python3 '$RELIABILITY' progress-sequence --device vda < '$FIXTURES/domstats-missing.json'"
  [ "$status" -ne 0 ]
  [ "$(jq -r .reason <<<"$output")" = "statistics-unavailable" ]
}

@test "preflight rejects non-Manual runStrategy without patching" {
  mkdir -p "$BATS_TMPDIR/mockbin" "$BATS_TMPDIR/evidence"
  cp "$FIXTURES/vm-always.json" "$BATS_TMPDIR/vm.json"
  cat > "$BATS_TMPDIR/mockbin/oc" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'get vm' ]]; then cat "$VM_FIXTURE"; exit 0; fi
echo "unexpected oc call: $*" >&2
exit 90
EOF
  cat > "$BATS_TMPDIR/mockbin/virtctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$BATS_TMPDIR/mockbin/findmnt" <<'EOF'
#!/usr/bin/env bash
echo 'xfs /durable-evidence'
EOF
  chmod +x "$BATS_TMPDIR/mockbin/oc" "$BATS_TMPDIR/mockbin/virtctl" "$BATS_TMPDIR/mockbin/findmnt"

  run env PATH="$BATS_TMPDIR/mockbin:$PATH" VM_FIXTURE="$BATS_TMPDIR/vm.json" \
    bash "$HOST_DIR/preflight-rhov.sh" --ns fixture-ns --vm fixture-vm \
      --out "$BATS_TMPDIR/evidence" --metadata "$BATS_TMPDIR/metadata.json" \
      --snap-class fixture-class \
      --recovery-image registry.example.test/recovery@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  [ "$status" -ne 0 ]
  [[ "$output" == *"required 'Manual'"* ]]
  [[ "$output" == *"will not patch it"* ]]
  [ ! -e "$BATS_TMPDIR/metadata.json" ]
}

@test "preflight records validated RBAC snapshot guest and disk metadata" {
  mkdir -p "$BATS_TMPDIR/mockbin" "$BATS_TMPDIR/evidence"
  export OC_LOG="$BATS_TMPDIR/preflight-oc.log"
  cat > "$BATS_TMPDIR/mockbin/oc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_LOG"
if [[ "$1 $2" == 'get vm' ]]; then cat "$FIXTURE_DIR/vm-manual.json"; exit 0; fi
if [[ "$1 $2" == 'get vmi' ]]; then cat "$FIXTURE_DIR/vmi-running.json"; exit 0; fi
if [[ "$1 $2" == 'get pod' ]]; then cat "$FIXTURE_DIR/pods-running.json"; exit 0; fi
if [[ "$1 $2" == 'get pvc' ]]; then cat "$FIXTURE_DIR/pvc-rootdisk.json"; exit 0; fi
if [[ "$1 $2" == 'get storageclass' ]]; then cat "$FIXTURE_DIR/storageclass.json"; exit 0; fi
if [[ "$1 $2" == 'get volumesnapshotclass' ]]; then cat "$FIXTURE_DIR/volumesnapshotclass.json"; exit 0; fi
if [[ "$1" == 'api-resources' ]]; then echo volumesnapshots.snapshot.storage.k8s.io; exit 0; fi
if [[ "$1 $2" == 'auth can-i' ]]; then echo yes; exit 0; fi
if [[ "$1" == 'exec' ]]; then echo 'file disk vda /dev/fixture'; exit 0; fi
echo "unexpected oc call: $*" >&2
exit 90
EOF
  cat > "$BATS_TMPDIR/mockbin/virtctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$BATS_TMPDIR/mockbin/findmnt" <<'EOF'
#!/usr/bin/env bash
echo 'xfs /durable-evidence'
EOF
  cat > "$BATS_TMPDIR/mockbin/guest-agent" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  psfile) echo '{"ok":true,"matchesRecommended":true,"current":{"AutoReboot":0},"pageFile":{"adequate":true}}' ;;
  exec) echo '{"windows":true,"dumpParent":true,"minidumpParent":true,"notMyFault":true}' ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$BATS_TMPDIR/mockbin/oc" "$BATS_TMPDIR/mockbin/virtctl" \
    "$BATS_TMPDIR/mockbin/findmnt" "$BATS_TMPDIR/mockbin/guest-agent"

  run env PATH="$BATS_TMPDIR/mockbin:$PATH" OC_LOG="$OC_LOG" FIXTURE_DIR="$FIXTURES" \
    BSOD_GUEST_AGENT_BIN="$BATS_TMPDIR/mockbin/guest-agent" \
    bash "$HOST_DIR/preflight-rhov.sh" --ns fixture-ns --vm fixture-vm \
      --out "$BATS_TMPDIR/evidence" --metadata "$BATS_TMPDIR/metadata.json" \
      --snap-class fixture-snapshot-class --require-trigger \
      --recovery-image registry.example.test/recovery@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  [ "$status" -eq 0 ]
  [ "$(jq -r .guestPvc "$BATS_TMPDIR/metadata.json")" = fixture-rootdisk ]
  [ "$(jq -r .diskTarget "$BATS_TMPDIR/metadata.json")" = vda ]
  [ "$(jq -r .launcherPod "$BATS_TMPDIR/metadata.json")" = virt-launcher-fixture-vm-current ]
  grep -q 'auth can-i create volumesnapshots.snapshot.storage.k8s.io' "$OC_LOG"
}

@test "snapshot recovery survives launcher disappearance and streams durable artifacts" {
  mkdir -p "$BATS_TMPDIR/mockbin" "$BATS_TMPDIR/evidence"
  export OC_LOG="$BATS_TMPDIR/oc.log"
  cat > "$BATS_TMPDIR/mockbin/oc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_LOG"
case "$1" in
  apply) cat >/dev/null; exit 0 ;;
  get)
    case "$2" in
      volumesnapshot) printf true ;;
      pvc) printf Bound ;;
      pod) printf Running ;;
      *) exit 91 ;;
    esac
    ;;
  exec)
    all="$*"
    if [[ "$all" == *' ls /Windows/Minidump'* ]]; then printf 'fixture-mini.dmp\n'; exit 0; fi
    if [[ "$all" == *'download /Windows/MEMORY.DMP'* ]]; then
      python3 -c 'import sys; sys.stdout.buffer.write(b"PAGEDU64" + bytes(120))'; exit 0
    fi
    if [[ "$all" == *'download /Windows/Minidump/fixture-mini.dmp'* ]]; then
      python3 -c 'import sys; sys.stdout.buffer.write(b"MDMP" + bytes(120))'; exit 0
    fi
    if [[ "$all" == *'download /Windows/System32/winevt/Logs/System.evtx'* ]]; then
      python3 -c 'import sys; sys.stdout.buffer.write(b"ElfFile\x00fixture")'; exit 0
    fi
    if [[ "$all" == *'download /Windows/System32/winevt/Logs/Application.evtx'* ]]; then exit 1; fi
    exit 92
    ;;
  delete) exit 0 ;;
  *) exit 93 ;;
esac
EOF
  chmod +x "$BATS_TMPDIR/mockbin/oc"
  printf '\211PNG\r\n\032\nfixture' > "$BATS_TMPDIR/evidence/bsod-screenshot.png"
  printf '\177ELFfixture' > "$BATS_TMPDIR/evidence/vm-memory.elf"
  printf 'watcher fixture log\n' > "$BATS_TMPDIR/evidence/watcher.log"
  : > "$BATS_TMPDIR/evidence/stage-errors.jsonl"

  run env PATH="$BATS_TMPDIR/mockbin:$PATH" OC_LOG="$OC_LOG" \
    bash "$HOST_DIR/recover-natural-crash.sh" \
      --metadata "$FIXTURES/recovery-metadata.json" --out "$BATS_TMPDIR/evidence"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TMPDIR/evidence/MEMORY.DMP" ]
  [ -s "$BATS_TMPDIR/evidence/Minidump/fixture-mini.dmp" ]
  [ -s "$BATS_TMPDIR/evidence/EventLogs/System.evtx" ]
  [ -s "$BATS_TMPDIR/evidence/checksums.sha256" ]
  grep -q 'MEMORY.DMP' "$BATS_TMPDIR/evidence/checksums.sha256"
  [ "$(jq -r .ok "$BATS_TMPDIR/evidence/recovery-summary.json")" = true ]
  ! grep -q 'deleted-launcher-pod' "$OC_LOG"
  ! grep -Eq '/tmp/qemu-memory|/out/' "$OC_LOG"
  pod_delete="$(grep -n '^delete pod ' "$OC_LOG" | head -1 | cut -d: -f1)"
  pvc_delete="$(grep -n '^delete pvc ' "$OC_LOG" | head -1 | cut -d: -f1)"
  snapshot_delete="$(grep -n '^delete volumesnapshot ' "$OC_LOG" | head -1 | cut -d: -f1)"
  [ "$pod_delete" -lt "$pvc_delete" ]
  [ "$pvc_delete" -lt "$snapshot_delete" ]
}

@test "image and wrappers preserve helper and mode contracts" {
  dockerfile="$(cd "$REPO_ROOT/../.." && pwd)/image/container/bsod-detector/Dockerfile"
  makefile="$(cd "$REPO_ROOT/../.." && pwd)/image/container/bsod-detector/Makefile"
  entrypoint="$(cd "$REPO_ROOT/../.." && pwd)/image/container/bsod-detector/entrypoint.sh"
  grep -q 'VIRTCTL_SHA256' "$dockerfile"
  grep -q 'COPY apps/bsod-detector/src/scripts/host/watch-crash.sh' "$dockerfile"
  grep -q "'../../..'" "$makefile"
  grep -q '/usr/local/bin/watch-crash.sh' "$entrypoint"
  ! grep -q 'WATCH_REBOOT_WAIT' "$entrypoint"
  grep -q 'MODE=extract' "$REPO_ROOT/host-tools/run.sh"
  ! grep -Eq '/tmp/(qemu-memory|guest-memory|screenshot)' \
    "$HOST_DIR/watch-crash.sh" "$HOST_DIR/recover-natural-crash.sh" "$HOST_DIR/backends/kubevirt.sh"
}
