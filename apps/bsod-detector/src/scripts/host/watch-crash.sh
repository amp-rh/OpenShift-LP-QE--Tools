#!/usr/bin/env bash
#
# watch-crash.sh -- watch a KubeVirt/RHOV Windows VM for a NATURAL BSOD/freeze and
# auto-capture evidence without writing anything to the OCP node that hosts the
# virt-launcher pod.
#
# Crash detection uses two complementary signals:
#   1. QGA ping timeout  -- fast, catches any QGA death (works on all KubeVirt versions)
#   2. pvpanic K8s event -- authoritative, emitted by KubeVirt >= v1.8.0 when the
#      pvpanic device fires inside the guest (requires pvpanic in the VM spec)
# Either signal alone is sufficient; both together eliminate false negatives.
#
# On crash detection the script immediately:
#   1. Takes a BSOD screenshot via `virtctl screenshot` (writes locally, not to node).
#   2. Captures VM RAM via `virsh dump --memory-only --format raw` piped via oc exec stdout to local evidence (no node writes).
#   3. Captures host-side signals (worker-node dmesg + domain XML) for split-lock
#      #AC analysis -- the ONLY place a HYPERVISOR_ERROR is visible.
#   4. Waits for I/O quiescence (disk write bytes stop increasing) -- indicates
#      Windows has finished writing MEMORY.DMP/Minidump before the VM is stopped.
#   5. Stops the VM via `virtctl stop`.
#   6. Triggers offline dump extraction via ODF VolumeSnapshot -> libguestfs pod
#      (recover-natural-crash.sh --path2-only).
#   7. Parses dump headers offline (parse-dump-header.sh) and writes evidence-summary.json.
#   8. Restarts the VM via `virtctl start` (ready for next test iteration).
#
# AutoReboot=0 MUST be set in the guest CrashControl registry (configure-dumps.ps1
# default). This lets Windows complete writing MEMORY.DMP before the I/O quiescence
# detection fires and the VM is stopped. Without it, an automatic reboot races with
# the dump write and can produce a truncated dump.
#
# runStrategy: Manual MUST be set in the KubeVirt VM spec so KubeVirt itself does
# not restart the VMI when it stops. Without it, KubeVirt may restart the VM before
# the dump has been extracted from the PVC.
#
# Requires: oc, virtctl, python3, jq, and (same dir) guest-agent.py,
#           collect-host-signals.sh, parse-dump-header.sh, recover-natural-crash.sh.
#
# --ns/--vm are OPTIONAL: with a single VMI on the cluster they are auto-detected.
#
# Usage:
#   export KUBECONFIG=<path>
#   watch-crash.sh [--ns <ns>] [--vm <name>] [--out <dir>]
#                  [--interval <secs>] [--miss <count>] [--node <worker>]
#                  [--quiesce-wait <secs>] [--no-restart]
#
####
set -euxo pipefail
shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null

typeset ns=""
typeset vm=""
typeset outDir=""
typeset interval=5
typeset miss=2
typeset node=""
typeset quiesceWait=900   # max seconds to wait for I/O quiescence (dump write)
typeset noRestart=0       # set 1 via --no-restart to skip virtctl start after collection

typeset scriptDir=''
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)            ns="$2";          shift 2;;
    --vm)            vm="$2";          shift 2;;
    --out)           outDir="$2";      shift 2;;
    --interval)      interval="$2";    shift 2;;
    --miss)          miss="$2";        shift 2;;
    --node)          node="$2";        shift 2;;
    --quiesce-wait)  quiesceWait="$2"; shift 2;;
    --no-restart)    noRestart=1;      shift;;
    # legacy compat
    --reboot-wait)   shift 2;;
    --burst)         shift 2;;
    -h|--help) sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "${outDir}" ] || outDir="./output/natural-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${outDir}"

# ── Resolve target VM from cluster ────────────────────────────────────────────
if [ -z "${vm}" ] || [ -z "${ns}" ]; then
  typeset -a scope=(-A); [ -n "${ns}" ] && scope=(-n "${ns}")
  typeset -a rows=()
  mapfile -t rows < <(oc get vmi "${scope[@]}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
    2>/dev/null | sed '/^$/d')
  [ -n "${vm}" ] && mapfile -t rows < <(printf '%s\n' "${rows[@]}" | awk -v v="${vm}" '$2==v')
  case "${#rows[@]}" in
    1) read -r ns vm <<<"${rows[0]}"; echo "auto-detected target: ns=${ns} vm=${vm}" >&2;;
    0) echo "ERROR: no matching VMI found; pass --ns <ns> --vm <name>" >&2; exit 1;;
    *) echo "ERROR: ambiguous; pass --ns and/or --vm. Candidates:" >&2
       printf '  %s\n' "${rows[@]}" >&2; exit 1;;
  esac
fi

# Resolve virt-launcher pod (needed only for virsh domstats + dumpxml — not for
# screenshots or memory dumps which use virtctl and write nothing to the node).
typeset pod=''
pod="$(oc get pod -n "${ns}" -o name 2>/dev/null \
       | sed -n "/virt-launcher-${vm}-/p" | head -1 | cut -d/ -f2)"
[ -n "${pod}" ] || { echo "ERROR: no virt-launcher pod for ${vm} in ${ns}" >&2; exit 1; }
typeset dom="${ns}_${vm}"
export GA_NS="${ns}" GA_POD="${pod}" GA_DOM="${dom}"

# ── Helper functions ───────────────────────────────────────────────────────────
function log ()     { echo "[$(date -u +%H:%M:%S)] $*"; true; }
function ga ()      { python3 "${scriptDir}/guest-agent.py" "$@"; }
# ping_ok — QGA liveness check; 10s bash-level timeout prevents blocking on dead socket.
function ping_ok () { timeout 10 python3 "${scriptDir}/guest-agent.py" ping >/dev/null 2>&1; }
# domstate — domain state via virsh (exec into pod; no file writes on node).
function domstate () { oc exec -n "${ns}" "${pod}" -- virsh domstate "${dom}" 2>/dev/null | tr -d '[:space:]'; }
# is_crash_state — running/paused/crashed/pmsuspended all indicate a crash; shutoff does not.
function is_crash_state () { case "$1" in running|paused|crashed|pmsuspended) return 0;; *) return 1;; esac; }

# ── capture_screenshot — single BSOD frame via virtctl (no writes to OCP node) ──
# virtctl screenshot writes the PNG directly to stdout/local file, bypassing the
# virt-launcher pod entirely. No oc exec, no /tmp writes on the node.
function capture_screenshot () {
  log "capturing BSOD screenshot ..."
  # Try virtctl screenshot first (no oc exec, no writes to OCP node)
  if command -v virtctl >/dev/null 2>&1; then
    if virtctl screenshot "${vm}" -n "${ns}" \
        > "${outDir}/bsod-screenshot.png" 2>/dev/null && \
        [ -s "${outDir}/bsod-screenshot.png" ]; then
      log "bsod-screenshot.png via virtctl ($(du -sh "${outDir}/bsod-screenshot.png" | cut -f1))"
      return 0
    fi
    log "virtctl screenshot unavailable — falling back to virsh screenshot via pod"
  fi
  # Fallback: virsh screenshot burst via oc exec (writes to pod /tmp only, not node FS)
  # We pipe stdout directly — no files written to the OCP node's filesystem.
  typeset dst="${outDir}/wsnap"; mkdir -p "${dst}"
  typeset best='' bestSz=0
  for i in $(seq -w 1 5); do
    oc exec -n "${ns}" "${pod}" -- \
      virsh screenshot "${dom}" /dev/stdout 2>/dev/null \
      > "${dst}/s_${i}.ppm" || true
    sleep 1
  done
  # Select BSOD frame by size band (8KB-400KB = blue screen)
  typeset ssMin=8000 ssMax=400000
  for f in "${dst}"/s_*.ppm; do
    [[ -f "${f}" ]] || continue
    typeset sz; sz=$(stat -c%s "${f}" 2>/dev/null || echo 0)
    if [[ $sz -ge $ssMin && $sz -le $ssMax && $sz -gt $bestSz ]]; then
      bestSz=$sz; best="${f}"
    fi
  done
  if [[ -n "${best}" ]]; then
    cp "${best}" "${outDir}/bsod-screenshot.png"
    log "bsod-screenshot.png via virsh (${bestSz}B)"
  else
    log "no BSOD frame captured in size band ${ssMin}-${ssMax}B"
  fi
  true
}

# ── capture_vm_memory — VM RAM dump via virsh dump piped to stdout ────────────
# Immediately captures the frozen VM's RAM as a raw backup artifact.
# Uses virsh dump --memory-only --format raw inside the virt-launcher pod,
# piping /dev/stdout directly to the local evidence directory.
# Nothing is written to the OCP node filesystem — data flows via oc exec stdout.
# Raw format is delivered as-is; developer handles elf2dmp conversion offline
# with their own matching PDB version (Finding 5 of architectural review).
function capture_vm_memory () {
  typeset dumpFile="${outDir}/vm-memory.raw"
  log "capturing VM RAM via virsh dump (raw) → stdout → ${dumpFile} ..."
  oc exec -n "${ns}" "${pod}" -- \
    virsh dump --memory-only --format raw "${dom}" /dev/stdout 2>/dev/null \
    > "${dumpFile}" || true
  if [[ -s "${dumpFile}" ]]; then
    log "VM RAM captured: ${dumpFile} ($(du -sh "${dumpFile}" | cut -f1))"
    log "Analyze with: elf2dmp vm-memory.raw vm-memory.dmp (use matching PDBs offline)"
  else
    log "virsh dump failed or returned empty — raw memory backup not captured"
    rm -f "${dumpFile}"
  fi
  true
}

# ── capture_host_signals — kernel log + domain XML (no node file writes) ──
function capture_host_signals () {
  [ -n "${node}" ] || node="$(oc get vmi "${vm}" -n "${ns}" \
    -o jsonpath='{.status.nodeName}' 2>/dev/null || true)"
  # dumpxml via oc exec stdout — no file written on the node
  oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" \
    > "${outDir}/dom.xml" 2>/dev/null || true
  if [ -n "${node}" ]; then
    log "reading kernel log from node ${node} ..."
    timeout 90 oc debug "node/${node}" -- chroot /host dmesg \
      > "${outDir}/kern.log" 2>/dev/null || true
  fi
  if [ -s "${outDir}/kern.log" ] || [ -s "${outDir}/dom.xml" ]; then
    typeset -a args=(--vm "${dom}")
    [ -s "${outDir}/kern.log" ] && args+=(--log-file "${outDir}/kern.log")
    [ -s "${outDir}/dom.xml"  ] && args+=(--domain-xml "${outDir}/dom.xml")
    bash "${scriptDir}/collect-host-signals.sh" "${args[@]}" \
      > "${outDir}/host-signals.json" 2>/dev/null || true
    log "host-signals.json written (splitLockDetected: \
$(jq -r .splitLockDetected "${outDir}/host-signals.json" 2>/dev/null))"
  else
    log "no kernel log or domain XML captured — split-lock evidence only lives here."
  fi
  true
}

# ── wait_dump_complete — I/O quiescence detection ────────────────────────────
# Windows writes MEMORY.DMP as a sequential stream before the system halts.
# When disk write bytes stop increasing for IDLE_SECS, the dump is complete.
# This is the correct signal to stop the VM and extract the dump offline.
function wait_dump_complete () {
  typeset idle_threshold=30   # seconds of no write activity = dump done
  typeset poll_interval=10
  typeset t=0
  typeset idle=0
  typeset prev_writes=-1

  log "waiting for I/O quiescence (MEMORY.DMP write completion, max ${quiesceWait}s) ..."
  while [[ $t -lt $quiesceWait ]]; do
    typeset cur_writes
    cur_writes="$(oc exec -n "${ns}" "${pod}" -- \
      virsh domstats --block "${dom}" 2>/dev/null \
      | awk -F= '/\.wr\.bytes=/{sum+=$2} END{print int(sum)}' || echo -1)"

    if [[ "${cur_writes}" == "${prev_writes}" && "${cur_writes}" != "-1" ]]; then
      idle=$((idle + poll_interval))
      log "  I/O idle ${idle}s (writes=${cur_writes}) ..."
      if [[ $idle -ge $idle_threshold ]]; then
        log "I/O quiescent for ${idle}s — MEMORY.DMP write complete"
        return 0
      fi
    else
      idle=0
      log "  disk writes active: ${cur_writes} bytes (${t}s elapsed) ..."
    fi

    prev_writes="${cur_writes}"
    sleep "${poll_interval}"
    t=$((t + poll_interval))
  done
  log "WARN: I/O quiescence timeout (${quiesceWait}s) — proceeding with VM stop"
  true
}

# ── collect_offline — stop VM + extract dumps offline via ODF snapshot ────────
# This is the PRIMARY collection path (Item 7 of architectural review).
# IMPORTANT: resolve the guest PVC name BEFORE stopping the VM, because the
# virt-launcher pod disappears after virtctl stop and recover-natural-crash.sh
# needs it for ODF snapshot. Pass --pvc explicitly to bypass pod resolution.
function collect_offline () {
  # 0. Resolve guest PVC name NOW while VMI is still accessible.
  typeset guestPvc=''
  guestPvc="$(oc get vmi "${vm}" -n "${ns}" \
    -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null || true)"
  if [[ -z "${guestPvc}" ]]; then
    guestPvc="$(oc get vmi "${vm}" -n "${ns}" \
      -o jsonpath='{.spec.volumes[*].dataVolume.name}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '^$' | head -1)"
  fi
  log "Guest PVC resolved before VM stop: ${guestPvc:-unknown}"

  # 1. Stop the VM so the disk is consistent for offline extraction.
  log "stopping VM via virtctl stop ..."
  virtctl stop "${vm}" -n "${ns}" 2>/dev/null || \
    oc exec -n "${ns}" "${pod}" -- virsh destroy "${dom}" 2>/dev/null || true
  # Wait for VMI to go offline (max 90s)
  typeset t=0
  typeset vmiPhase="Running"
  while [[ $t -lt 90 && "${vmiPhase}" == "Running" ]]; do
    sleep 5; t=$((t+5))
    vmiPhase="$(oc get vmi "${vm}" -n "${ns}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo Stopped)"
  done
  log "VMI phase after stop: ${vmiPhase}"

  # 2. Offline dump extraction via ODF VolumeSnapshot → libguestfs
  log "extracting MEMORY.DMP + Minidump offline via ODF snapshot ..."
  if [ -f "${scriptDir}/recover-natural-crash.sh" ]; then
    typeset -a recoverArgs=(--ns "${ns}" --vm "${vm}" --out "${outDir}" --path2-only)
    [[ -n "${guestPvc}" ]] && recoverArgs+=(--pvc "${guestPvc}")
    bash "${scriptDir}/recover-natural-crash.sh" \
      "${recoverArgs[@]}" 2>&1 | while IFS= read -r line; do log "${line}"; done || true
    bugCheck="$(jq -r '.dumps[0].bugCheckName // empty' \
      "${outDir}/parse-dump-header.json" 2>/dev/null)" || true
  else
    log "recover-natural-crash.sh not found — skipping offline extraction"
  fi

  # 3. Restart the VM for the next test iteration (unless --no-restart)
  if [[ "${noRestart}" -eq 0 ]]; then
    log "restarting VM via virtctl start ..."
    virtctl start "${vm}" -n "${ns}" 2>/dev/null || true
    log "VM restart requested — may take a few minutes to be ready"
  fi
  true
}

typeset rebooted=false
typeset bugCheck=""

# ── write_summary ─────────────────────────────────────────────────────────────
function write_summary () {
  typeset splitLock="null"
  [ -s "${outDir}/host-signals.json" ] && \
    splitLock="$(jq -c '.splitLockDetected // null' "${outDir}/host-signals.json" 2>/dev/null || echo null)"
  jq -n \
    --arg vm "${vm}" --arg ns "${ns}" --arg dom "${dom}" \
    --arg detectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg domstate "$1" --arg bugcheck "${bugCheck:-}" \
    --argjson rebooted "${rebooted}" --argjson splitLockDetected "${splitLock}" \
    '{ok:true, mode:"natural", vm:$vm, namespace:$ns, domain:$dom,
      crashDetected:true, detectedAt:$detectedAt, domStateAtCrash:$domstate,
      guestRebooted:$rebooted, hardFreeze:($rebooted|not),
      bugCheck:(if $bugcheck=="" then null else $bugcheck end),
      splitLockDetected:$splitLockDetected,
      artifacts:{
        screenshot:"bsod-screenshot.png",
        vmMemoryRaw:"vm-memory.raw",
        hostSignals:"host-signals.json",
        domainXml:"dom.xml",
        kernelLog:"kern.log",
        dumpHeader:"parse-dump-header.json"}}' \
    > "${outDir}/evidence-summary.json" 2>/dev/null || true
  log "evidence-summary.json written."
  true
}

# ── Main watch loop ───────────────────────────────────────────────────────────
log "watching ${vm} (pod=${pod}, dom=${dom}); poll ${interval}s, crash after ${miss} missed pings."
log "Ctrl-C to stop."
typeset misses=0
until ping_ok; do log "waiting for guest agent to be reachable ..."; sleep "${interval}"; done
log "guest agent healthy; watching for a natural crash ..."

# Keep the display awake so pre-crash frames aren't all-black (DPMS). Best-effort.
timeout 15 ga exec powercfg /change monitor-timeout-ac 0 >/dev/null 2>&1 || true

# Also watch for pvpanic K8s events in the background (KubeVirt >= v1.8.0).
# pvpanic fires immediately when the guest kernel panics — before QGA times out.
# The event triggers the same crash-response path as the QGA miss counter.
typeset PVPANIC_TRIGGERED=0
(
  oc get events -n "${ns}" -w \
    --field-selector "reason=Panicked" 2>/dev/null | \
  while IFS= read -r line; do
    if echo "${line}" | grep -q "${vm}"; then
      echo "PVPANIC" > /tmp/pvpanic_signal_${vm}
    fi
  done
) &
PVPANIC_PID=$!

typeset st=''
while true; do
  # Check for pvpanic event signal
  if [[ -f "/tmp/pvpanic_signal_${vm}" ]]; then
    rm -f "/tmp/pvpanic_signal_${vm}"
    st="$(domstate || echo crashed)"
    log "*** PVPANIC EVENT DETECTED (domstate=${st}) — crash confirmed ***"
    PVPANIC_TRIGGERED=1
    kill "${PVPANIC_PID}" 2>/dev/null || true
    # Execute full crash response
    capture_screenshot
    capture_vm_memory
    capture_host_signals
    wait_dump_complete
    collect_offline
    write_summary "${st}"
    log "evidence package: ${outDir}"
    exit 0
  fi

  # Standard QGA ping-based detection
  if ping_ok; then
    misses=0
  else
    misses=$((misses+1))
    st="$(domstate || echo unknown)"
    log "missed ping ${misses}/${miss} (domstate=${st})"
    if [ "${misses}" -ge "${miss}" ] && is_crash_state "${st}"; then
      log "*** CRASH/FREEZE DETECTED (agent dead, domstate=${st}) ***"
      kill "${PVPANIC_PID}" 2>/dev/null || true
      capture_screenshot
      capture_vm_memory
      capture_host_signals
      wait_dump_complete
      collect_offline
      write_summary "${st}"
      log "evidence package: ${outDir}"
      exit 0
    fi
  fi
  sleep "${interval}"
done
true
