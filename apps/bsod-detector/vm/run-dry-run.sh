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
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
typeset here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repo; repo="$(cd "$here/.." && pwd)"
VM_NAME="${VM_NAME:-bsod-test}"
typeset gssh="$here/guest-ssh.sh"
SNAPSHOT="${SNAPSHOT:-crashme-installed}"

typeset code="0x19"
typeset revert=1
typeset out="$repo/output/dryrun-$(date +%Y%m%d-%H%M%S)"
typeset guestScripts='C:/bsod-detector/scripts'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --code)       code="$2"; shift 2 ;;
    --no-revert)  revert=0; shift ;;
    --out)        out="$2"; shift 2 ;;
    --snapshot)   SNAPSHOT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "run-dry-run: unknown arg: $1" >&2; exit 2 ;;
  esac
done

function Log () { echo "[dry-run] $*" >&2; true; }

function LookupParams () {
  python3 -c "
import json, sys
tm = json.load(open('$repo/src/data/trigger-methods.json'))['codes']
code = sys.argv[1].upper().replace('0X', '0x')
if not code.startswith('0x'):
    code = '0x' + code
code = '0x' + code[2:].zfill(8)
if code not in tm:
    print(f'ERROR: {code} not in trigger-methods.json', file=sys.stderr)
    sys.exit(1)
print(' '.join(tm[code]['parameters']))
" "$1"
  true
}

function GuestBootTime () {
  "$gssh" -c '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")' 2>/dev/null | tr -d '\r' | tr -d '[:space:]'
  true
}

function WaitForSsh () {
  for _ in $(seq 1 25); do
    "$gssh" -c '"up"' 2>/dev/null | grep -q up && return 0
    sleep 8
  done
  return 1
}

typeset params; params=$(LookupParams "$code")
typeset codeNorm; codeNorm=$(python3 -c "c='$code'.upper(); print('0x'+c[2:].zfill(8) if c.startswith('0x') or c.startswith('0X') else '0x'+c.zfill(8))")
Log "code=$codeNorm params=$params"

if [[ "$revert" == 1 ]]; then
  Log "reverting $VM_NAME to $SNAPSHOT"
  virsh snapshot-revert "$VM_NAME" "$SNAPSHOT"
fi

if [[ "$(virsh -q domstate "$VM_NAME")" != "running" ]]; then
  Log "starting $VM_NAME"
  virsh start "$VM_NAME" >/dev/null
fi

Log "waiting for guest SSH"
WaitForSsh || { echo "guest never came up" >&2; exit 1; }

typeset before; before="$(GuestBootTime)"
Log "pre-crash boot time: $before"

Log "triggering BSOD: $codeNorm $params"
"$gssh" -c "C:\\Tools\\crashme-ctl.exe $code $params" 2>&1 || true

Log "waiting for auto-reboot"
sleep 25
typeset rebooted=0
for _ in $(seq 1 30); do
  typeset now; now="$(GuestBootTime)"
  if [[ -n "$now" && "$now" != "$before" ]]; then rebooted=1; Log "rebooted: $now"; break; fi
  sleep 10
done
[[ "$rebooted" == 1 ]] || { echo "guest did not reboot; crash may have failed" >&2; exit 1; }

Log "collecting evidence -> $out"
mkdir -p "$out"
typeset guestOut='C:/bsod-detector/output/dryrun-current'
"$gssh" -c "Remove-Item -Recurse -Force $guestOut -EA SilentlyContinue; & $guestScripts/collect-guest.ps1 -OutputDir ${guestOut//\//\\}" \
  2>/dev/null | grep -avE '^#< CLIXML|<Objs ' > "$out/collect-guest.json" || true

typeset ip; ip="$(virsh -q domifaddr "$VM_NAME" | awk 'NR==1{print $4}' | cut -d/ -f1)"
typeset -a sshOpts=(-i "$repo/.ssh/bsod-test" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
scp -r "${sshOpts[@]}" "Administrator@$ip:${guestOut}/*" "$out/" 2>/dev/null || true

Log "done. Report + artifacts in: $out"
python3 - "$out/collect-guest.json" <<'PY' 2>/dev/null || cat "$out/collect-guest.json"
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
