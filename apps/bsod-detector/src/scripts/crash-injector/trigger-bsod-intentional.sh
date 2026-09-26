#!/usr/bin/env bash
# Intentional RHOV BSOD orchestration for an explicitly disposable test VM.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset crashType="${1:-0x01}"; typeset vm="${GA_VM:-}"; typeset ns="${GA_NS:-}"
typeset evidenceRoot="${EVIDENCE_DIR:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_EVIDENCE_STORAGE_ID:-}"; typeset memoryPvc="${BSOD_MEMORY_DUMP_PVC:-}"
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset watchTimeout="${BSOD_WATCH_TIMEOUT:-1800}"; typeset readyTimeout="${BSOD_READY_TIMEOUT:-300}"
typeset preflightTimeout="${BSOD_PREFLIGHT_TIMEOUT:-300}"
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"; typeset hostDir="${appDir}/src/scripts/host"
typeset watcherPid=''; typeset runId=''; runId="$(date -u +%Y%m%dT%H%M%SZ)-intentional-$$-$RANDOM"
typeset outDir="${evidenceRoot}/${runId}"; typeset metadataFile="${outDir}/recovery-metadata.json"; typeset readyFile="${outDir}/watcher-ready"

function Die () { echo "trigger-bsod-intentional: ERROR: $*" >&2; exit 1; }
function Cleanup () { if [[ -n "${watcherPid}" ]]; then kill "${watcherPid}" 2>/dev/null || true; wait "${watcherPid}" 2>/dev/null || true; watcherPid=''; fi; true; }
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

[[ -n "${vm}" && -n "${ns}" ]] || Die 'GA_VM and GA_NS must explicitly identify the disposable RHOV test VM'
[[ -n "${evidenceRoot}" ]] || Die 'EVIDENCE_DIR must identify the validated persistent mount'
[[ "${watchTimeout}" =~ ^[1-9][0-9]*$ && "${readyTimeout}" =~ ^[1-9][0-9]*$ && "${preflightTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'watch/ready/preflight timeouts must be positive integers'
case "${crashType}" in 0x01|0x02|0x03|0x04|0x05|0x06|0x07|0x08|0x09) ;; *) Die "unsupported NotMyFault crash type '${crashType}'" ;; esac

mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
timeout --signal=TERM --kill-after=5 "${preflightTimeout}" "${hostDir}/preflight-rhov.sh" --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}" \
  --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}" --require-trigger
GA_POD="$(jq -er .launcherPod "${metadataFile}")"; export GA_POD
GA_DOM="$(jq -er .domain "${metadataFile}")"; export GA_DOM

# Fail if either dump location cannot be proven empty. Silently ignoring removal
# failures would permit stale evidence to satisfy this run.
typeset cleanupResult=''
cleanupResult="$(timeout --signal=TERM --kill-after=5 60 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
  "Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue; Remove-Item 'C:\Windows\Minidump\*.dmp' -Force -ErrorAction SilentlyContinue; [ordered]@{memory=(Test-Path 'C:\Windows\MEMORY.DMP');minidumpCount=@(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Compress")" || Die 'guest dump cleanup command failed or timed out'
jq -e '.memory == false and .minidumpCount == 0' <<<"${cleanupResult}" >/dev/null || Die "guest dump cleanup could not be proven: ${cleanupResult}"

timeout --signal=TERM --kill-after=10 "${watchTimeout}" bash "${hostDir}/watch-crash.sh" \
  --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}" --ready-file "${readyFile}" \
  --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}" --intentional &
watcherPid=$!
typeset readyDeadline=$((SECONDS + readyTimeout))
while ((SECONDS < readyDeadline)); do
  if [[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]]; then break; fi
  kill -0 "${watcherPid}" 2>/dev/null || { wait "${watcherPid}" 2>/dev/null || true; watcherPid=''; Die 'watcher exited before publishing readiness'; }
  sleep 1
done
[[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]] || Die "watcher readiness timed out after ${readyTimeout}s"

# exec-crash succeeds only after QGA confirms process creation and transport then
# disappears. An immediate guest exit is returned verbatim and aborts this run.
timeout --signal=TERM --kill-after=5 90 python3 "${hostDir}/guest-agent.py" exec-crash \
  'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash "${crashType}" >/dev/null || Die 'intentional guest crash command exited nonzero or did not disconnect as expected'

typeset watcherStatus=0; wait "${watcherPid}" || watcherStatus=$?; watcherPid=''
((watcherStatus == 0)) || Die "watcher/recovery pipeline failed with status ${watcherStatus}; inspect ${outDir}"
jq -e --arg run "${runId}" '.ok == true and .runId == $run' "${outDir}/evidence-summary.json" >/dev/null || Die 'current-run evidence summary is absent or reports failure'
echo "trigger-bsod-intentional: verified evidence package: ${outDir}"
