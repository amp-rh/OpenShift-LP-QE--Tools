#!/usr/bin/env bash
# Intentional RHOV BSOD orchestration for an explicitly disposable test VM.
# This script orchestrates the full pipeline: preflight validation → crash injection → watcher → recovery
set -euxo pipefail; shopt -s inherit_errexit
umask 077

# Parse input: crash type (0x01-0x09 from NotMyFault), VM name, and namespace
typeset crashType="${1:-0x01}"; typeset vm="${BSOD_DET__VM__NAME:-}"; typeset ns="${BSOD_DET__NAMESPACE:-}"
# Storage configuration: evidence root (mounted PVC), volume kind, and storage identity
typeset evidenceRoot="${BSOD_DET__EVIDENCE__DIR:-/mnt/persistent-bsod-evidence}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-pvc}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-shared-bsod-evidence}"; typeset memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-win2022-vm-hjoshi1-memdump}"
# Kubernetes storage classes and container image for extraction pod
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-ocs-storagecluster-rbdplugin-snapclass}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-image-registry.openshift-image-registry.svc:5000/windows-bsod/bsod-recovery:latest@sha256:4f46353f8e63ef419b66b9828b4771fe0c2c692c6fe6e6a49b5d57153b6edb76}"
# Timeouts: how long to wait for watcher readiness and preflight validation
typeset readyTimeout="${BSOD_DET__READY__TIMEOUT:-300}"
typeset preflightTimeout="${BSOD_DET__PREFLIGHT__TIMEOUT:-300}"
# Directory structure: script location, app root, host scripts location
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"; typeset hostDir="${appDir}/src/scripts/host"
# Project root for cleanup of libguestfs cache files (file.0x*)
# guestfish writes cache files to CWD which is the git repo root (two levels above appDir)
typeset projectRoot=''; projectRoot="$(cd "${appDir}/../.." && pwd)"
typeset watcherPid=''; typeset runId=''; runId="$(date -u +%Y%m%dT%H%M%SZ)-intentional-$$-$RANDOM"
typeset outDir="${evidenceRoot}/${runId}"; typeset metadataFile="${outDir}/recovery-metadata.json"; typeset readyFile="${outDir}/watcher-ready"

function Die () { echo "trigger-bsod-intentional: ERROR: $*" >&2; exit 1; }
# Remove leftover cache files from libguestfs operations (file.0x* sections) from previous runs
function CleanupGuestfishCache () { find "${projectRoot}" -maxdepth 5 -name "file.0x*" -type f -delete 2>/dev/null || true; find /tmp -maxdepth 2 -name "file.0x*" -type f -delete 2>/dev/null || true; }
# Cleanup on exit: kill background watcher process and remove cache files
function Cleanup () {
  if [[ -n "${watcherPid}" ]]; then kill "${watcherPid}" 2>/dev/null || true; wait "${watcherPid}" 2>/dev/null || true; watcherPid=''; fi
  CleanupGuestfishCache
  true
}
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

[[ -n "${vm}" && -n "${ns}" ]] || Die 'BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE must explicitly identify the disposable RHOV test VM'
[[ -n "${evidenceRoot}" ]] || Die 'EVIDENCE_DIR must identify the validated persistent mount'
[[ "${readyTimeout}" =~ ^[1-9][0-9]*$ && "${preflightTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'watch/ready/preflight timeouts must be positive integers'
case "${crashType}" in 0x01|0x02|0x03|0x04|0x05|0x06|0x07|0x08|0x09) ;; *) Die "unsupported NotMyFault crash type '${crashType}'" ;; esac

# Phase 1: Cleanup - remove any cache artifacts from previous pipeline runs
echo "trigger-bsod-intentional: cleaning up any leftover guestfish cache files (file.0x*)..."
CleanupGuestfishCache

# Phase 2: Preflight validation - verify cluster state, VM existence, and mount points are valid
mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
timeout --signal=TERM --kill-after=5 1800 "${hostDir}/preflight-rhov.sh" --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}" \
  --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}" --require-trigger
# Extract launcher pod name and domain from preflight metadata for guest agent access
BSOD_DET__POD__NAME="$(jq -er .launcherPod "${metadataFile}")"; export BSOD_DET__POD__NAME
BSOD_DET__DOMAIN__NAME="$(jq -er .domain "${metadataFile}")"; export BSOD_DET__DOMAIN__NAME

# Phase 3: Guest cleanup - ensure no stale dumps from previous runs exist on the VM
# This prevents false positives from old dumps: we must verify empty state BEFORE injecting crash
typeset cleanupResult=''
cleanupResult="$(timeout --signal=TERM --kill-after=5 60 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
  "Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue; Remove-Item 'C:\Windows\Minidump\*.dmp' -Force -ErrorAction SilentlyContinue; [ordered]@{memory=(Test-Path 'C:\Windows\MEMORY.DMP');minidumpCount=@(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Compress")" || Die 'guest dump cleanup command failed or timed out'
jq -e '.memory == false and .minidumpCount == 0' <<<"${cleanupResult}" >/dev/null || Die "guest dump cleanup could not be proven: ${cleanupResult}"

# Phase 4: Start watcher in background - watches for crash occurrence and captures dumps/logs
bash "${hostDir}/watch-crash.sh" \
  --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}" --ready-file "${readyFile}" \
  --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}" --intentional &
watcherPid=$!
# Wait for watcher to signal readiness - means it's armed and watching for crash
typeset readyDeadline=$((SECONDS + readyTimeout))
while ((SECONDS < readyDeadline)); do
  if [[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]]; then break; fi
  kill -0 "${watcherPid}" 2>/dev/null || { wait "${watcherPid}" 2>/dev/null || true; watcherPid=''; Die 'watcher exited before publishing readiness'; }
  sleep 1
done
[[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]] || Die "watcher readiness timed out after ${readyTimeout}s"

# Phase 5: Inject crash - use NotMyFault to trigger intentional BSOD on guest VM
# This waits for QGA to confirm process creation and delivery before returning
timeout --signal=TERM --kill-after=5 90 python3 "${hostDir}/guest-agent.py" exec-crash \
  'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash "${crashType}" >/dev/null || Die 'intentional guest crash command exited nonzero or did not disconnect as expected'

# Phase 6: Wait for watcher completion - captures memory, logs, and extracted artifacts
typeset watcherStatus=0; wait "${watcherPid}" || watcherStatus=$?; watcherPid=''
((watcherStatus == 0)) || Die "watcher/recovery pipeline failed with status ${watcherStatus}; inspect ${outDir}"
# Verify that evidence summary exists and reports success (all artifacts extracted)
jq -e --arg run "${runId}" '.ok == true and .runId == $run' "${outDir}/evidence-summary.json" >/dev/null || Die 'current-run evidence summary is absent or reports failure'
echo "trigger-bsod-intentional: verified evidence package: ${outDir}"

true
