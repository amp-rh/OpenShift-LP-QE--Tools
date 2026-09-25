#!/usr/bin/env bash
#
# recover-natural-crash.sh -- evidence recovery for a hard-frozen or crashed
# KubeVirt Windows VM when the guest agent is dead and the VM cannot reboot.
#
# Use this AFTER watch-crash.sh detects a crash but the guest agent does NOT
# return (hardFreeze:true in evidence-summary.json). It runs two recovery paths:
#
#   PATH 1 — virsh dump --memory-only (immediate, while QEMU process is alive)
#             Captures a QEMU/ELF memory snapshot via oc exec into the
#             virt-launcher pod. NOT a Windows crash dump; analyze with volatility3.
#
#   PATH 2 — ODF VolumeSnapshot → libguestfs pod (preferred for Windows dumps)
#             Takes a CSI snapshot of the guest PVC (non-destructive, VM stays running).
#             Mounts the snapshot in a recovery pod with virt-tools and extracts
#             MEMORY.DMP + Minidump\*.dmp offline. This produces real Windows dumps
#             analyzable with WinDbg/parse-dump-header.sh.
#
# Runs both paths by default. Use --path1-only or --path2-only to limit.
#
# Usage:
#   recover-natural-crash.sh --ns <namespace> --vm <vmname> --out <dir>
#                            [--path1-only] [--path2-only]
#                            [--snap-class <volumesnapshotclass>]
#                            [--pvc <guest-pvc-name>]
#                            [--recovery-image <image>]
#
# Output:
#   <out>/qemu-memory.dump      PATH 1: raw QEMU/ELF memory image
#   <out>/MEMORY.DMP            PATH 2: Windows kernel crash dump (if present)
#   <out>/Minidump/*.dmp        PATH 2: Windows minidumps (if present)
#   <out>/parse-dump-header.json  parsed bug check code from Windows dumps
#   <out>/recovery-summary.json   master recovery report
#
####
set -euo pipefail
shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null

typeset scriptDir; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
typeset ns=""
typeset vm=""
typeset outDir=""
typeset path1Only=0
typeset path2Only=0
typeset snapClass="ocs-storagecluster-rbdplugin-snapclass"
typeset guestPvc=""
typeset recoveryImage="registry.access.redhat.com/ubi9/ubi:latest"
typeset snapName=""
typeset snapPvc=""

# Logging
function log()     { echo "[$(date -u +%H:%M:%S)] $*"; }
function log_ok()  { echo "[$(date -u +%H:%M:%S)] ✓ $*"; }
function log_warn(){ echo "[$(date -u +%H:%M:%S)] WARN: $*" >&2; }
function die()     { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ns)             ns="$2";            shift 2 ;;
    --vm)             vm="$2";            shift 2 ;;
    --out)            outDir="$2";        shift 2 ;;
    --path1-only)     path1Only=1;        shift ;;
    --path2-only)     path2Only=1;        shift ;;
    --snap-class)     snapClass="$2";     shift 2 ;;
    --pvc)            guestPvc="$2";      shift 2 ;;
    --recovery-image) recoveryImage="$2"; shift 2 ;;
    -h|--help) sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$ns" ]] || die "--ns is required"
[[ -n "$vm" ]] || die "--vm is required"
[[ -n "$outDir" ]] || outDir="./evidence/recovery-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$outDir"

typeset dom="${ns}_${vm}"
typeset pod=""
typeset warnings=()
typeset path1Ok=false
typeset path2Ok=false
typeset dumpsFound=()

# ─── Resolve virt-launcher pod ───────────────────────────────────────────────
log "Resolving virt-launcher pod for $vm in $ns..."
pod="$(oc get pod -n "$ns" -o name 2>/dev/null \
       | grep "virt-launcher-${vm}-" | head -1 | cut -d/ -f2)"
[[ -n "$pod" ]] || die "No virt-launcher pod found for $vm in $ns"
log_ok "Pod: $pod"

# ─── Resolve guest PVC name ──────────────────────────────────────────────────
if [[ -z "$guestPvc" ]]; then
  log "Resolving guest PVC from VMI spec..."
  guestPvc="$(oc get vmi "$vm" -n "$ns" \
    -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null)"
  # Fallback: DataVolume (same name as the PVC)
  if [[ -z "$guestPvc" ]]; then
    guestPvc="$(oc get vmi "$vm" -n "$ns" \
      -o jsonpath='{.spec.volumes[*].dataVolume.name}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '^$' | head -1)"
  fi
  [[ -n "$guestPvc" ]] || die "Cannot resolve guest PVC — pass --pvc <name>"
fi
log_ok "Guest PVC: $guestPvc"

# ─── PATH 1: virsh dump --memory-only ────────────────────────────────────────
run_path1() {
  log ""
  log "═══ PATH 1: virsh dump --memory-only (QEMU/ELF memory image) ═══"
  log "  Capturing live guest RAM via virt-launcher pod (may briefly pause VM)..."

  typeset dumpFile="${outDir}/qemu-memory.dump"

  # Run virsh dump inside the virt-launcher pod — copies result to pod /tmp
  if oc exec -n "$ns" "$pod" -- \
       virsh dump --memory-only --format elf "$dom" /tmp/qemu-memory.dump \
       >/dev/null 2>&1; then
    # Copy from pod to host
    oc cp "${ns}/${pod}:/tmp/qemu-memory.dump" "$dumpFile" 2>/dev/null
    if [[ -f "$dumpFile" && -s "$dumpFile" ]]; then
      typeset sz; sz="$(du -sh "$dumpFile" | cut -f1)"
      log_ok "QEMU/ELF memory dump: $dumpFile ($sz)"
      log "  ⚠ This is NOT a Windows crash dump."
      log "  Analyze with: volatility3 -f $dumpFile windows.pslist"
      path1Ok=true
      dumpsFound+=("qemu-memory.dump")
    else
      log_warn "virsh dump ran but output file is empty or missing"
      warnings+=("PATH1: virsh dump produced empty output")
    fi
  else
    log_warn "virsh dump failed — QEMU process may have exited or VM is fully dead"
    warnings+=("PATH1: virsh dump --memory-only failed")
  fi

  # Cleanup pod tmp file
  oc exec -n "$ns" "$pod" -- rm -f /tmp/qemu-memory.dump >/dev/null 2>&1 || true
}

# ─── PATH 2: ODF VolumeSnapshot → libguestfs recovery pod ───────────────────
run_path2() {
  log ""
  log "═══ PATH 2: ODF VolumeSnapshot → libguestfs dump extraction ═══"

  snapName="bsod-recovery-${vm}-$(date +%Y%m%d%H%M%S)"
  snapPvc="${snapName}-pvc"
  typeset recoveryPod="${snapName}-pod"

  # ── 2a: Create VolumeSnapshot ───────────────────────────────────────────
  log "  [2a] Creating VolumeSnapshot: $snapName (source: $guestPvc)..."
  oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${snapName}
  namespace: ${ns}
  labels:
    app: bsod-recovery
    target-vm: ${vm}
spec:
  volumeSnapshotClassName: ${snapClass}
  source:
    persistentVolumeClaimName: ${guestPvc}
EOF

  # Wait for snapshot to be ready (up to 3 min)
  log "  Waiting for snapshot to be ready..."
  typeset t=0
  while [[ $t -lt 180 ]]; do
    typeset ready; ready="$(oc get volumesnapshot "$snapName" -n "$ns" \
      -o jsonpath='{.status.readyToUse}' 2>/dev/null)"
    if [[ "$ready" == "true" ]]; then
      log_ok "Snapshot ready: $snapName"
      break
    fi
    sleep 10; t=$((t+10))
    log "  Waiting for snapshot... (${t}s)"
  done
  [[ "$ready" == "true" ]] || { log_warn "Snapshot not ready after 180s"; warnings+=("PATH2: snapshot not ready"); return; }

  # Get snapshot size for PVC
  typeset snapSize; snapSize="$(oc get pvc "$guestPvc" -n "$ns" \
    -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "128Gi")"

  # ── 2b: Create PVC from snapshot ────────────────────────────────────────
  log "  [2b] Creating recovery PVC from snapshot ($snapSize)..."
  oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${snapPvc}
  namespace: ${ns}
  labels:
    app: bsod-recovery
    target-vm: ${vm}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd-virtualization
  resources:
    requests:
      storage: ${snapSize}
  dataSource:
    name: ${snapName}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

  # Wait for PVC to bind
  log "  Waiting for recovery PVC to bind..."
  t=0
  while [[ $t -lt 120 ]]; do
    typeset phase; phase="$(oc get pvc "$snapPvc" -n "$ns" \
      -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [[ "$phase" == "Bound" ]]; then
      log_ok "Recovery PVC bound: $snapPvc"
      break
    fi
    sleep 10; t=$((t+10))
  done
  [[ "$phase" == "Bound" ]] || { log_warn "Recovery PVC not bound"; warnings+=("PATH2: recovery PVC not bound"); return; }

  # ── 2c: Run libguestfs recovery pod ─────────────────────────────────────
  log "  [2c] Launching libguestfs recovery pod..."
  oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${recoveryPod}
  namespace: ${ns}
  labels:
    app: bsod-recovery
    target-vm: ${vm}
spec:
  restartPolicy: Never
  containers:
  - name: extractor
    image: quay.io/rhsysdeseng/libguestfs-tools:latest
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -euo pipefail
      echo "=== libguestfs dump extractor ==="
      DISK=\$(ls /dev/vd? /dev/sda /dev/xvda 2>/dev/null | head -1 || true)
      if [[ -z "\$DISK" ]]; then
        echo "ERROR: no disk device found"
        ls /dev/
        exit 1
      fi
      echo "Using disk: \$DISK"

      mkdir -p /out/Minidump

      echo "--- Extracting MEMORY.DMP ---"
      virt-copy-out -a "\$DISK" "/Windows/MEMORY.DMP" /out/ 2>/dev/null \
        && echo "MEMORY.DMP extracted" \
        || echo "MEMORY.DMP not found (may not have been written)"

      echo "--- Extracting Minidump ---"
      virt-copy-out -a "\$DISK" "/Windows/Minidump" /out/ 2>/dev/null \
        && echo "Minidump extracted" \
        || echo "Minidump directory empty or not found"

      echo "--- Extracted files ---"
      find /out -type f | xargs ls -lh 2>/dev/null || true
      echo "=== DONE ==="
    volumeMounts:
    - name: guest-disk
      mountPath: /mnt/guest
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: 2000m
        memory: 2Gi
  volumes:
  - name: guest-disk
    persistentVolumeClaim:
      claimName: ${snapPvc}
      readOnly: true
EOF

  # Wait for recovery pod to complete (up to 15 min)
  log "  Waiting for recovery pod to complete (up to 15 min)..."
  t=0
  while [[ $t -lt 900 ]]; do
    typeset podPhase; podPhase="$(oc get pod "$recoveryPod" -n "$ns" \
      -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [[ "$podPhase" == "Succeeded" || "$podPhase" == "Failed" ]]; then
      break
    fi
    sleep 15; t=$((t+15))
    log "  Recovery pod phase: $podPhase (${t}s elapsed)"
  done

  log "  Recovery pod logs:"
  oc logs "$recoveryPod" -n "$ns" 2>/dev/null | tee -a /dev/stderr || true

  if [[ "$podPhase" != "Succeeded" ]]; then
    log_warn "Recovery pod did not succeed (phase: $podPhase)"
    warnings+=("PATH2: recovery pod phase=$podPhase")
  else
    # ── 2d: Copy extracted dumps from pod to host ────────────────────────
    log "  [2d] Copying extracted dumps from recovery pod..."
    oc cp "${ns}/${recoveryPod}:/out/MEMORY.DMP" \
       "${outDir}/MEMORY.DMP" 2>/dev/null && \
       log_ok "MEMORY.DMP copied" || log_warn "MEMORY.DMP not found in recovery pod"

    oc cp "${ns}/${recoveryPod}:/out/Minidump" \
       "${outDir}/Minidump" 2>/dev/null && \
       log_ok "Minidump directory copied" || log_warn "Minidump not found in recovery pod"

    # Collect found dumps
    while IFS= read -r f; do
      dumpsFound+=("$(basename "$f")")
    done < <(find "$outDir" -name "*.dmp" -o -name "*.DMP" 2>/dev/null)

    if [[ ${#dumpsFound[@]} -gt 0 ]]; then
      path2Ok=true
    else
      log_warn "No dump files found in recovery pod output"
      warnings+=("PATH2: no .dmp files extracted from snapshot")
    fi
  fi

  # ── 2e: Parse extracted Windows dumps ───────────────────────────────────
  if [[ "$path2Ok" == "true" ]]; then
    log "  [2e] Parsing Windows dump headers offline..."
    if [[ -f "${outDir}/MEMORY.DMP" ]]; then
      bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" \
        > "${outDir}/parse-dump-header.json" 2>/dev/null || true
    elif [[ -d "${outDir}/Minidump" ]]; then
      bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" \
        > "${outDir}/parse-dump-header.json" 2>/dev/null || true
    fi
    [[ -f "${outDir}/parse-dump-header.json" ]] && \
      log_ok "Dump header parsed: $(jq -r '.dumps[0].bugCheckName // "unknown"' "${outDir}/parse-dump-header.json" 2>/dev/null)"
  fi
}

# ─── Cleanup: remove snapshot + recovery PVC + pod ───────────────────────────
cleanup_path2() {
  log ""
  log "Cleaning up recovery resources..."
  [[ -n "$snapPvc" ]]     && oc delete pvc "$snapPvc" -n "$ns" --ignore-not-found >/dev/null 2>&1 && log_ok "Deleted PVC: $snapPvc" || true
  [[ -n "$snapName" ]]    && oc delete volumesnapshot "$snapName" -n "$ns" --ignore-not-found >/dev/null 2>&1 && log_ok "Deleted snapshot: $snapName" || true
  # Pod named after snapName
  typeset rPod="${snapName}-pod"
  oc delete pod "$rPod" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
}

# ─── Collect host signals ─────────────────────────────────────────────────────
run_host_signals() {
  log ""
  log "Collecting host kernel signals (kern.log + dom.xml)..."
  typeset node; node="$(oc get vmi "$vm" -n "$ns" \
    -o jsonpath='{.status.nodeName}' 2>/dev/null || true)"

  # Domain XML
  oc exec -n "$ns" "$pod" -- virsh dumpxml "$dom" \
    > "${outDir}/dom.xml" 2>/dev/null || true

  # Kernel log from worker node
  if [[ -n "$node" ]]; then
    log "  Reading kernel log from node $node..."
    timeout 90 oc debug "node/${node}" -- chroot /host dmesg \
      > "${outDir}/kern.log" 2>/dev/null || true
  fi

  if [[ -f "${scriptDir}/collect-host-signals.sh" ]]; then
    typeset -a hsArgs=(--vm "$dom")
    [[ -s "${outDir}/kern.log" ]] && hsArgs+=(--log-file "${outDir}/kern.log")
    [[ -s "${outDir}/dom.xml"  ]] && hsArgs+=(--domain-xml "${outDir}/dom.xml")
    bash "${scriptDir}/collect-host-signals.sh" "${hsArgs[@]}" \
      > "${outDir}/host-signals.json" 2>/dev/null || true
    log_ok "host-signals.json written"
  fi
}

# ─── Write recovery-summary.json ─────────────────────────────────────────────
write_summary() {
  typeset bugCheck=""
  [[ -f "${outDir}/parse-dump-header.json" ]] && \
    bugCheck="$(jq -r '.dumps[0].bugCheckName // ""' "${outDir}/parse-dump-header.json" 2>/dev/null || true)"

  typeset splitLock="null"
  [[ -f "${outDir}/host-signals.json" ]] && \
    splitLock="$(jq -c '.splitLockDetected // null' "${outDir}/host-signals.json" 2>/dev/null || echo null)"

  jq -n \
    --arg vm "$vm" --arg ns "$ns" --arg dom "$dom" \
    --arg recoveredAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg bugCheck "$bugCheck" \
    --argjson path1Ok "$path1Ok" --argjson path2Ok "$path2Ok" \
    --argjson splitLockDetected "$splitLock" \
    --argjson warns "$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
    '{ok:true, mode:"hard-freeze-recovery",
      vm:$vm, namespace:$ns, domain:$dom,
      recoveredAt:$recoveredAt,
      hardFreeze:true, guestRebooted:false,
      bugCheck:(if $bugCheck=="" then null else $bugCheck end),
      splitLockDetected:$splitLockDetected,
      recovery:{
        path1_virsh_dump: $path1Ok,
        path2_odf_snapshot: $path2Ok
      },
      warnings:$warns}' \
    > "${outDir}/recovery-summary.json" 2>/dev/null || true

  log_ok "recovery-summary.json written"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
log "╔══════════════════════════════════════════════════════════════════╗"
log "║       BSOD Evidence Recovery — Hard Freeze / Unresponsive VM    ║"
log "╚══════════════════════════════════════════════════════════════════╝"
log "  VM        : $vm"
log "  Namespace : $ns"
log "  Guest PVC : $guestPvc"
log "  Snap class: $snapClass"
log "  Output    : $outDir"
log ""

run_host_signals

[[ $path2Only -eq 0 ]] && run_path1
[[ $path1Only -eq 0 ]] && { run_path2; cleanup_path2; }

write_summary

log ""
log "═══════════════════════════════════════════════════════════════════"
log "Recovery complete. Results:"
log "  PATH 1 (virsh dump / ELF) : $path1Ok"
log "  PATH 2 (ODF snapshot / Windows dump): $path2Ok"
[[ -n "$bugCheck" ]] && log "  Bug check: $bugCheck" || true
log ""
log "Evidence directory: $outDir"
find "$outDir" -type f | sort | while read -r f; do
  log "  $(ls -lh "$f" | awk '{print $5, $9}')"
done
log ""
log "Next steps:"
log "  • Windows dump: bash src/scripts/host/parse-dump-header.sh --dir $outDir/Minidump"
log "  • ELF dump:     volatility3 -f $outDir/qemu-memory.dump windows.pslist"
log "  • Summary:      cat $outDir/recovery-summary.json | jq '.'"
log "═══════════════════════════════════════════════════════════════════"
