#!/usr/bin/env bash
#
# watch-crash.sh -- watch a KubeVirt Windows VM for a NATURAL BSOD/freeze and
# auto-capture evidence. NO trigger is used: this is for crashes that happen on
# their own (e.g. the Intel split-lock #AC during the Hyper-V enlightened
# TLB-flush hypercall -> HYPERVISOR_ERROR 0x00020001), so NotMyFault / the 0xEF
# trigger are NOT needed.
#
# It polls the qemu-guest-agent. When the guest stops answering while the domain
# is still alive (domstate running/paused/crashed/pmsuspended -- pvpanic can move a
# bugcheck out of 'running') -- the classic BSOD/hang signature -- it immediately:
#   1. bursts `virsh screenshot` from the virt-launcher pod to catch the blue screen,
#   2. captures HOST-side signals (worker-node kernel log + domain XML) and runs
#      collect-host-signals.sh -- this is the ONLY place a TLB-flush/HYPERVISOR_ERROR
#      is visible; it never appears in the guest dump,
#   3. waits for the guest to reboot; if it does, runs collect-guest.ps1, pulls the
#      minidump, and cross-checks it offline with parse-dump-header.sh; if it stays
#      frozen (common for HYPERVISOR_ERROR), it records that and stops.
#
# Everything lands in one evidence directory, tied together by evidence-summary.json
# (crashDetected, guestRebooted/hardFreeze, bugCheck, splitLockDetected). Uses the
# qemu-guest-agent (no SSH).
#
# Requires: oc, python3, jq, and (same dir) guest-agent.py, collect-host-signals.sh,
#           parse-dump-header.sh. The toolkit must already be staged in the guest
#           (stage-toolkit.ps1) for the collect-guest step.
#
# --ns/--vm are OPTIONAL: with a single VMI on the cluster they are auto-detected;
# pass them only to disambiguate. Nothing is tied to a particular VM.
#
# Usage:
#   export KUBECONFIG=<cluster kubeconfig>
#   ./watch-crash.sh [--ns NS] [--vm NAME] [--out DIR]
#                    [--interval 5] [--miss 3] [--node <worker>] [--reboot-wait 300]
#
set -euo pipefail

NS=""                # namespace; auto-detected from the VMI when not given
VM=""                # VM name; auto-detected if there is exactly one VMI (in $NS if set)
OUT=""
INTERVAL=5            # seconds between health polls
MISS=3               # consecutive missed pings (while domain 'running') => crash
NODE=""              # worker node for the kernel log; auto-detected if empty
REBOOT_WAIT=300      # seconds to wait for the guest agent to return after a crash
BURST=25             # screenshot frames to grab across the blue-screen window
SS_MIN=8000          # screenshot size band (bytes): floor excludes ~3KB DPMS-black frames
SS_MAX=400000        # ceiling excludes ~874KB desktop/lock frames; blue screen sits ~36KB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2;;
    --vm) VM="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --miss) MISS="$2"; shift 2;;
    --node) NODE="$2"; shift 2;;
    --reboot-wait) REBOOT_WAIT="$2"; shift 2;;
    --burst) BURST="$2"; shift 2;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$OUT" ] || OUT="./output/natural-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# Resolve the target from the cluster so nothing is tied to one VM. Explicit
# --ns/--vm always win; only the missing pieces are looked up. Lists "<ns> <vm>"
# rows scoped to --ns if given, else cluster-wide, then optionally filtered by --vm.
if [ -z "$VM" ] || [ -z "$NS" ]; then
  _scope=(-A); [ -n "$NS" ] && _scope=(-n "$NS")
  mapfile -t _rows < <(oc get vmi "${_scope[@]}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d')
  [ -n "$VM" ] && mapfile -t _rows < <(printf '%s\n' "${_rows[@]}" | awk -v v="$VM" '$2==v')
  case "${#_rows[@]}" in
    1) read -r NS VM <<<"${_rows[0]}"; echo "auto-detected target: ns=$NS vm=$VM" >&2;;
    0) echo "ERROR: no matching VMI found; pass --ns <ns> --vm <name>" >&2; exit 1;;
    *) echo "ERROR: ambiguous target; pass --ns and/or --vm. Candidates:" >&2
       printf '  %s\n' "${_rows[@]}" >&2; exit 1;;
  esac
fi

POD="$(oc get pod -n "$NS" -o name 2>/dev/null | grep "virt-launcher-$VM-" | head -n1 | cut -d/ -f2 || true)"
[ -n "$POD" ] || { echo "ERROR: no virt-launcher pod for $VM in $NS" >&2; exit 1; }
DOM="${NS}_${VM}"
export GA_NS="$NS" GA_POD="$POD" GA_DOM="$DOM"

log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
ga(){ python3 "$SCRIPT_DIR/guest-agent.py" "$@"; }
ping_ok(){ ga ping >/dev/null 2>&1; }
domstate(){ oc exec -n "$NS" "$POD" -- virsh domstate "$DOM" 2>/dev/null | tr -d '[:space:]'; }

capture_screens(){          # $1 = destination dir
  local dst="$1"; mkdir -p "$dst"
  oc exec -n "$NS" "$POD" -- bash -c "
    mkdir -p /tmp/wsnap; rm -f /tmp/wsnap/*
    for i in \$(seq -w 1 $BURST); do
      virsh screenshot $DOM /tmp/wsnap/s_\$i.ppm >/dev/null 2>&1 || true
      sleep 1
    done" >/dev/null 2>&1 || true
  oc cp "$NS/$POD:/tmp/wsnap" "$dst" >/dev/null 2>&1 || true
  # BSOD frames are a solid colour + text => they compress SMALL (~36KB) while the
  # desktop/lock screen is ~874KB and a DPMS-asleep display is a ~3KB solid black.
  # Pick the SMALLEST frame INSIDE the [SS_MIN,SS_MAX] band: that isolates the blue
  # screen from both the black (too small) and the desktop (too big) frames.
  local best="" bestsz=$((SS_MAX + 1))
  shopt -s nullglob
  for f in "$dst"/wsnap/*.ppm; do
    local sz; sz=$(stat -c%s "$f")
    if [ "$sz" -ge "$SS_MIN" ] && [ "$sz" -le "$SS_MAX" ] && [ "$sz" -lt "$bestsz" ]; then bestsz=$sz; best="$f"; fi
  done
  if [ -n "$best" ]; then
    cp "$best" "$dst/bsod-screenshot.png"
    log "likely blue screen: $(basename "$best") (${bestsz}B) -> bsod-screenshot.png"
  else
    log "no frame in the ${SS_MIN}-${SS_MAX}B band; guest display may have been black (DPMS) or no blue screen captured."
  fi
}

capture_host_signals(){     # host kernel log (split-lock #AC) + domain XML
  [ -n "$NODE" ] || NODE="$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)"
  oc exec -n "$NS" "$POD" -- virsh dumpxml "$DOM" > "$OUT/dom.xml" 2>/dev/null || true
  if [ -n "$NODE" ]; then
    log "reading kernel log from node $NODE ..."
    timeout 90 oc debug "node/$NODE" -- chroot /host dmesg > "$OUT/kern.log" 2>/dev/null || true
  fi
  if [ -s "$OUT/kern.log" ] || [ -s "$OUT/dom.xml" ]; then
    # only pass a source flag when that file was actually captured
    local args=(--vm "$DOM")
    [ -s "$OUT/kern.log" ] && args+=(--log-file "$OUT/kern.log")
    [ -s "$OUT/dom.xml" ]  && args+=(--domain-xml "$OUT/dom.xml")
    bash "$SCRIPT_DIR/collect-host-signals.sh" "${args[@]}" \
      > "$OUT/host-signals.json" 2>/dev/null || true
    log "host-signals.json written (splitLockDetected: $(jq -r .splitLockDetected "$OUT/host-signals.json" 2>/dev/null))"
  else
    log "no kernel log or domain XML captured; skipping host-signals (TLB-flush/#AC evidence lives ONLY here)."
  fi
}

REBOOTED=false        # set by collect_after_reboot; consumed by the summary
BUGCHECK=""

collect_after_reboot(){
  log "waiting up to ${REBOOT_WAIT}s for the guest agent to return ..."
  local t=0
  while [ "$t" -lt "$REBOOT_WAIT" ]; do
    if ping_ok; then log "guest agent back after ~${t}s"; break; fi
    sleep 5; t=$((t+5))
  done
  if ! ping_ok; then
    log "guest did NOT reboot within ${REBOOT_WAIT}s -- likely HARD FREEZE (typical for HYPERVISOR_ERROR)."
    log "guest dump is not retrievable from a frozen guest; rely on host-signals.json above."
    return 0
  fi
  REBOOTED=true
  log "running collect-guest.ps1 ..."
  ga exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\bsod-detector\src\scripts\collect-guest.ps1' \
    2>/dev/null | sed -n '/^{/,$p' > "$OUT/collect-guest.json" || true
  # pull the newest minidump and cross-check offline
  local dmp
  dmp="$(ga exec powershell.exe -NoProfile -Command "(Get-ChildItem C:\\Windows\\Minidump\\*.dmp | Sort-Object LastWriteTime -Desc | Select-Object -First 1).Name" 2>/dev/null | tr -d '\r' | grep -i '\.dmp' || true)"
  if [ -n "$dmp" ]; then
    mkdir -p "$OUT/Minidump"
    ga get "C:\\Windows\\Minidump\\$dmp" "$OUT/Minidump/$dmp" >/dev/null 2>&1 || true
    if [ -f "$OUT/Minidump/$dmp" ]; then
      bash "$SCRIPT_DIR/parse-dump-header.sh" "$OUT/Minidump/$dmp" > "$OUT/parse-dump-header.json" 2>/dev/null || true
      BUGCHECK="$(jq -r '.dumps[0].bugCheckName // empty' "$OUT/parse-dump-header.json" 2>/dev/null)"
    fi
    log "minidump pulled: $dmp ; bugcheck: ${BUGCHECK:-unknown}"
  else
    log "no minidump found (a HYPERVISOR_ERROR often writes none)."
  fi
}

write_summary(){        # $1 = domstate seen at detection
  local splitlock="null"
  [ -s "$OUT/host-signals.json" ] && splitlock="$(jq -c '.splitLockDetected // null' "$OUT/host-signals.json" 2>/dev/null || echo null)"
  jq -n \
    --arg vm "$VM" --arg ns "$NS" --arg dom "$DOM" \
    --arg detectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg domstate "$1" --arg bugcheck "${BUGCHECK:-}" \
    --argjson rebooted "$REBOOTED" --argjson splitLockDetected "$splitlock" \
    '{ok:true, mode:"natural", vm:$vm, namespace:$ns, domain:$dom,
      crashDetected:true, detectedAt:$detectedAt, domStateAtCrash:$domstate,
      guestRebooted:$rebooted, hardFreeze:($rebooted|not),
      bugCheck:(if $bugcheck=="" then null else $bugcheck end),
      splitLockDetected:$splitLockDetected,
      artifacts:{screenshot:"bsod-screenshot.png", hostSignals:"host-signals.json",
                 domainXml:"dom.xml", kernelLog:"kern.log",
                 guestCollect:"collect-guest.json", dumpHeader:"parse-dump-header.json"}}' \
    > "$OUT/evidence-summary.json" 2>/dev/null || true
  log "evidence-summary.json written."
}

log "watching $VM (pod=$POD, dom=$DOM); poll ${INTERVAL}s, crash after ${MISS} missed pings. Ctrl-C to stop."
misses=0
until ping_ok; do log "waiting for guest agent to be reachable ..."; sleep "$INTERVAL"; done
log "guest agent healthy; watching for a natural crash ..."

# Keep the display awake so pre-crash/repaint frames aren't all-black (DPMS). Best-effort.
ga exec powercfg /change monitor-timeout-ac 0 >/dev/null 2>&1 || true

# A natural bugcheck may leave the domain 'running' (pure hang) OR, if the VM has a
# pvpanic device, transition it to paused/crashed/pmsuspended. All of those, with a
# dead agent, mean "crashed" -- only a clean 'shutoff' does not.
is_crash_state(){ case "$1" in running|paused|crashed|pmsuspended) return 0;; *) return 1;; esac; }

while true; do
  if ping_ok; then
    misses=0
  else
    misses=$((misses+1))
    st="$(domstate || echo unknown)"
    log "missed ping $misses/$MISS (domstate=$st)"
    if [ "$misses" -ge "$MISS" ] && is_crash_state "$st"; then
      log "*** CRASH/FREEZE DETECTED (agent dead, domstate=$st) ***"
      capture_screens "$OUT"        # catch the blue screen NOW
      capture_host_signals          # host split-lock #AC + hyperv features
      collect_after_reboot          # guest dump if it reboots; else note freeze
      write_summary "$st"           # one JSON tying it all together
      log "evidence package: $OUT"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done
