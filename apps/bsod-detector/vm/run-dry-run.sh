#!/usr/bin/env bash
# run-dry-run.sh - end-to-end BSOD test loop against the local bsod-test guest.
#
# Runs on the HOST. Orchestrates one full cycle:
#   1. (optional) revert the guest to the crashme-installed snapshot
#   2. start the guest and wait for SSH
#   3. trigger a BSOD via the CrashMe driver with a specified code
#   4. wait for the auto-reboot
#   5. collect post-mortem evidence and copy artifacts back to the host
#
# All guest interaction goes through vm/guest-ssh.sh (SSH key auth). Never
# point this at anything but a disposable/snapshotted test VM.
#
# Usage:
#   vm/run-dry-run.sh [--code <hex>] [--no-revert] [--out <dir>]
#
# Defaults: code=0x19 (BAD_POOL_HEADER), revert=yes,
#           out=<repo>/output/dryrun-<timestamp>
set -euxo pipefail
shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VM_NAME="${VM_NAME:-bsod-test}"
GSSH="$HERE/guest-ssh.sh"
SNAPSHOT="${SNAPSHOT:-crashme-installed}"

CODE="0x19"
REVERT=1
OUT="$REPO/output/dryrun-$(date +%Y%m%d-%H%M%S)"
GUEST_SCRIPTS='C:/bsod-detector/scripts'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --code)       CODE="$2"; shift 2 ;;
    --no-revert)  REVERT=0; shift ;;
    --out)        OUT="$2"; shift 2 ;;
    --snapshot)   SNAPSHOT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "run-dry-run: unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[dry-run] $*" >&2; }

lookup_params() {
  python3 -c "
import json, sys
tm = json.load(open('$REPO/src/data/trigger-methods.json'))['codes']
code = sys.argv[1].upper()
if not code.startswith('0x'):
    code = '0x' + code
code = '0x' + code[2:].zfill(8)
if code not in tm:
    print(f'ERROR: {code} not in trigger-methods.json', file=sys.stderr)
    sys.exit(1)
print(' '.join(tm[code]['parameters']))
" "$1"
}

guest_boot_time() {
  "$GSSH" -c '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")' 2>/dev/null | tr -d '\r' | tr -d '[:space:]'
}
wait_for_ssh() {
  for _ in $(seq 1 25); do
    "$GSSH" -c '"up"' 2>/dev/null | grep -q up && return 0
    sleep 8
  done
  return 1
}

PARAMS=$(lookup_params "$CODE")
CODE_NORM=$(python3 -c "c='$CODE'.upper(); print('0x'+c[2:].zfill(8) if c.startswith('0x') or c.startswith('0X') else '0x'+c.zfill(8))")
log "code=$CODE_NORM params=$PARAMS"

if [[ "$REVERT" == 1 ]]; then
  log "reverting $VM_NAME to $SNAPSHOT"
  virsh snapshot-revert "$VM_NAME" "$SNAPSHOT"
fi

if [[ "$(virsh -q domstate "$VM_NAME")" != "running" ]]; then
  log "starting $VM_NAME"
  virsh start "$VM_NAME" >/dev/null
fi

log "waiting for guest SSH"
wait_for_ssh || { echo "guest never came up" >&2; exit 1; }

BEFORE="$(guest_boot_time)"
log "pre-crash boot time: $BEFORE"

log "triggering BSOD: $CODE_NORM $PARAMS"
"$GSSH" -c "C:\\Tools\\crashme-ctl.exe $CODE $PARAMS" 2>&1 || true

log "waiting for auto-reboot"
sleep 25
REBOOTED=0
for _ in $(seq 1 30); do
  NOW="$(guest_boot_time)"
  if [[ -n "$NOW" && "$NOW" != "$BEFORE" ]]; then REBOOTED=1; log "rebooted: $NOW"; break; fi
  sleep 10
done
[[ "$REBOOTED" == 1 ]] || { echo "guest did not reboot; crash may have failed" >&2; exit 1; }

log "collecting evidence -> $OUT"
mkdir -p "$OUT"
GUEST_OUT='C:/bsod-detector/output/dryrun-current'
"$GSSH" -c "Remove-Item -Recurse -Force $GUEST_OUT -EA SilentlyContinue; & $GUEST_SCRIPTS/collect-guest.ps1 -OutputDir ${GUEST_OUT//\//\\}" \
  2>/dev/null | grep -avE '^#< CLIXML|<Objs ' > "$OUT/collect-guest.json" || true

IP="$(virsh -q domifaddr "$VM_NAME" | awk 'NR==1{print $4}' | cut -d/ -f1)"
SSHOPTS=(-i "$REPO/.ssh/bsod-test" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
scp -r "${SSHOPTS[@]}" "Administrator@$IP:${GUEST_OUT}/*" "$OUT/" 2>/dev/null || true

log "done. Report + artifacts in: $OUT"
python3 - "$OUT/collect-guest.json" <<'PY' 2>/dev/null || cat "$OUT/collect-guest.json"
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("crash", {})
code = c.get("bugCheckCode")
name = c.get("bugCheckName")
print(f"bugCheck : {code} ({name})")
print("params   :", ", ".join(c.get("parameters", [])) or "(none)")
print("dumps    :", ", ".join(c.get("dumpFiles", [])) or "(none)")
print("warnings :", "; ".join(d.get("warnings", [])) or "(none)")
expected = sys.argv[2] if len(sys.argv) > 2 else None
if expected and code != expected:
    print(f"FAIL: expected {expected}, got {code}")
    sys.exit(1)
elif code:
    print("PASS")
PY
