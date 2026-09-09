#!/usr/bin/env bats
#
# stakeout.sh - preflight gating and verdict classification.
#
# Everything here runs with --dry-run plus --domain-xml/--node-cmdline fixtures,
# so the full decision tree is exercised with no cluster, no libvirt and no VM.

load test-helper

STAKEOUT="$REPO_ROOT/src/scripts/host/stakeout.sh"

setup() {
  SetupTemp
  # Unmitigated config: the TLB-flush crash is possible AND capturable.
  cat > "$BATS_TMPDIR/good.xml" <<'EOF'
<domain type='kvm'><name>win</name>
 <features><hyperv><tlbflush state='on'/><ipi state='on'/></hyperv></features>
 <devices><video><model type='qxl'/></video><panic model='pvpanic'/></devices>
</domain>
EOF
  # Mitigated config: the crash cannot occur; no framebuffer; no pvpanic.
  cat > "$BATS_TMPDIR/bad.xml" <<'EOF'
<domain type='kvm'><name>win</name>
 <features><hyperv><vapic state='on'/></hyperv></features>
 <devices><video><model type='virtio'/></video></devices>
</domain>
EOF
  echo 'BOOT_IMAGE=/vmlinuz ro split_lock_detect=warn' > "$BATS_TMPDIR/cmdline-on"
  echo 'BOOT_IMAGE=/vmlinuz ro quiet'                  > "$BATS_TMPDIR/cmdline-off"
}

teardown() { TeardownTemp; }

# $1 = xml fixture, $2 = cmdline fixture, $3 = scenario
Preflight() {
  run bash "$STAKEOUT" preflight --dry-run --provider kubevirt --ns n --vm v \
    --scenario "$3" --domain-xml "$BATS_TMPDIR/$1" --node-cmdline "$BATS_TMPDIR/$2" \
    --out "$BATS_TMPDIR/pf-$3-$1"
}

@test "stakeout.sh passes bash syntax check" {
  run bash -n "$STAKEOUT"
  [ "$status" -eq 0 ]
}

@test "preflight is ready when the unmitigated config is in place" {
  Preflight good.xml cmdline-on tlb-flush
  [ "$status" -eq 0 ]
  run jq -e '.ready == true and .blockers == 0' "$BATS_TMPDIR/pf-tlb-flush-good.xml/preflight.json"
  [ "$status" -eq 0 ]
}

@test "preflight BLOCKS the tlb-flush scenario when enlightenments are mitigated" {
  Preflight bad.xml cmdline-on tlb-flush
  [ "$status" -eq 1 ]
  run jq -e '[.checks[] | select(.id == "hyperv-enlightenments")][0].status == "fail"' \
    "$BATS_TMPDIR/pf-tlb-flush-bad.xml/preflight.json"
  [ "$status" -eq 0 ]
}

@test "preflight BLOCKS the tlb-flush scenario when split-lock detection is off" {
  Preflight good.xml cmdline-off tlb-flush
  [ "$status" -eq 1 ]
  run jq -e '[.checks[] | select(.id == "split-lock-detect")][0].status == "fail"' \
    "$BATS_TMPDIR/pf-tlb-flush-good.xml/preflight.json"
  [ "$status" -eq 0 ]
}

@test "scenario 'any' demotes the tlb-flush blockers to warnings" {
  Preflight bad.xml cmdline-off any
  [ "$status" -eq 0 ]
  run jq -e '.ready == true and .blockers == 0 and .warnings > 0' \
    "$BATS_TMPDIR/pf-any-bad.xml/preflight.json"
  [ "$status" -eq 0 ]
}

@test "preflight always emits a remedy for every non-passing check" {
  Preflight bad.xml cmdline-off tlb-flush
  run jq -e '[.checks[] | select(.status == "fail") | select(.remedy == null)] | length == 0' \
    "$BATS_TMPDIR/pf-tlb-flush-bad.xml/preflight.json"
  [ "$status" -eq 0 ]
}

@test "preflight detects pvpanic presence and absence" {
  Preflight good.xml cmdline-on any
  run jq -r '[.checks[] | select(.id == "pvpanic")][0].status' "$BATS_TMPDIR/pf-any-good.xml/preflight.json"
  [ "$output" = "pass" ]
  Preflight bad.xml cmdline-on any
  run jq -r '[.checks[] | select(.id == "pvpanic")][0].status' "$BATS_TMPDIR/pf-any-bad.xml/preflight.json"
  [ "$output" = "warn" ]
}

@test "preflight flags virtio video as unusable for crash-time screenshots" {
  Preflight bad.xml cmdline-on any
  run jq -r '[.checks[] | select(.id == "video-device")][0].status' "$BATS_TMPDIR/pf-any-bad.xml/preflight.json"
  [ "$output" = "warn" ]
}

@test "watch aborts before staking out when preflight has blockers" {
  run bash "$STAKEOUT" watch --dry-run --provider kubevirt --ns n --vm v --scenario tlb-flush \
    --domain-xml "$BATS_TMPDIR/bad.xml" --node-cmdline "$BATS_TMPDIR/cmdline-off" \
    --out "$BATS_TMPDIR/w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT"* ]]
  [ ! -f "$BATS_TMPDIR/w/stakeout-summary.json" ]
}

@test "--skip-preflight overrides the abort" {
  run bash "$STAKEOUT" watch --dry-run --skip-preflight --provider kubevirt --ns n --vm v \
    --out "$BATS_TMPDIR/w2"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TMPDIR/w2/stakeout-summary.json" ]
}

# $1 = evidence-summary.json body, $2 = expected verdict.
# Asserted inline rather than through `run`: test-helper.bash enables xtrace, so
# `run <shell function>` would fold the trace into $output.
AssertVerdict() {
  typeset d="$BATS_TMPDIR/v$RANDOM"
  mkdir -p "$d"
  echo "$1" > "$d/evidence-summary.json"
  bash "$STAKEOUT" escalate --dry-run --provider kvm --vm t --out "$d" >/dev/null 2>&1
  typeset got
  got="$(jq -r .verdict "$d/stakeout-summary.json")"
  [ "$got" = "$2" ] || { echo "expected verdict '$2', got '$got'" >&2; return 1; }
}

@test "verdict: hard freeze with a split-lock signal is the strongest TLB-flush evidence" {
  AssertVerdict '{"crashDetected":true,"guestRebooted":false,"hardFreeze":true,"splitLockDetected":true}' \
    hard-freeze-splitlock
}

@test "verdict: hard freeze without a split-lock signal is unattributed" {
  AssertVerdict '{"crashDetected":true,"guestRebooted":false,"hardFreeze":true,"splitLockDetected":false}' \
    hard-freeze-unattributed
}

@test "verdict: reboot with a recovered dump" {
  AssertVerdict '{"crashDetected":true,"guestRebooted":true,"hardFreeze":false,"bugCheck":"HYPERVISOR_ERROR"}' \
    bugcheck-captured
}

@test "verdict: reboot with no dump (three-tier fallback territory)" {
  AssertVerdict '{"crashDetected":true,"guestRebooted":true,"hardFreeze":false,"bugCheck":null}' \
    crash-no-dump
}

@test "verdict: no crash is a valid recorded outcome, not a failure" {
  AssertVerdict '{"crashDetected":false}' no-crash
}

@test "escalation runs on hard freeze and records a method" {
  typeset d="$BATS_TMPDIR/esc"; mkdir -p "$d"
  echo '{"crashDetected":true,"hardFreeze":true}' > "$d/evidence-summary.json"
  run bash "$STAKEOUT" escalate --dry-run --provider kubevirt --ns n --vm v --out "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HARD FREEZE"* ]]
  run jq -e '.hostRecovery.method != null' "$d/stakeout-summary.json"
  [ "$status" -eq 0 ]
}

@test "BSOD_DET__HYP_PROV selects the backend" {
  export BSOD_DET__HYP_PROV=kvm
  bash "$STAKEOUT" preflight --dry-run --vm t \
    --domain-xml "$BATS_TMPDIR/good.xml" --node-cmdline "$BATS_TMPDIR/cmdline-on" \
    --out "$BATS_TMPDIR/prov" >/dev/null 2>&1
  unset BSOD_DET__HYP_PROV
  run jq -r '.provider' "$BATS_TMPDIR/prov/preflight.json"
  [ "$output" = "kvm" ]
}

@test "kvm backend uses the bare VM name as the domain, kubevirt uses <ns>_<vm>" {
  bash "$STAKEOUT" preflight --dry-run --provider kvm --vm t \
    --domain-xml "$BATS_TMPDIR/good.xml" --node-cmdline "$BATS_TMPDIR/cmdline-on" \
    --out "$BATS_TMPDIR/d1" >/dev/null 2>&1
  run jq -r '.domain' "$BATS_TMPDIR/d1/preflight.json"
  [ "$output" = "t" ]
  bash "$STAKEOUT" preflight --dry-run --provider kubevirt --ns n --vm t \
    --domain-xml "$BATS_TMPDIR/good.xml" --node-cmdline "$BATS_TMPDIR/cmdline-on" \
    --out "$BATS_TMPDIR/d2" >/dev/null 2>&1
  run jq -r '.domain' "$BATS_TMPDIR/d2/preflight.json"
  [ "$output" = "n_t" ]
}

@test "unknown subcommand and unknown flag both exit 2" {
  run bash "$STAKEOUT" bogus --dry-run
  [ "$status" -eq 2 ]
  run bash "$STAKEOUT" preflight --nonsense
  [ "$status" -eq 2 ]
}

@test "--domain-xml with a missing file fails loudly rather than silently skipping" {
  run bash "$STAKEOUT" preflight --dry-run --provider kvm --vm t \
    --domain-xml "$BATS_TMPDIR/nope.xml" --out "$BATS_TMPDIR/miss"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such file"* ]]
}
