#!/usr/bin/env bash
# Intentional RHOV BSOD orchestration.  This script is destructive by design;
# it must only be used against an explicitly prepared disposable test VM.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset crashType="${1:-0x01}"
typeset vm="${GA_VM:-}"; typeset ns="${GA_NS:-}"
typeset outDir="${EVIDENCE_DIR:-./evidence}"
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"
typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset watchTimeout="${BSOD_WATCH_TIMEOUT:-1800}"
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"
typeset hostDir="${appDir}/src/scripts/host"
typeset watcherPid=''

function Die () { echo "trigger-bsod-intentional: ERROR: $*" >&2; exit 1; }
function Cleanup () { if [[ -n "${watcherPid}" ]]; then kill "${watcherPid}" 2>/dev/null || true; fi; true; }
trap Cleanup EXIT INT TERM

[[ -n "${vm}" && -n "${ns}" ]] || Die 'GA_VM and GA_NS must explicitly identify the disposable RHOV test VM'
[[ "${watchTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'BSOD_WATCH_TIMEOUT must be a positive integer number of seconds'
case "${crashType}" in
  0x01|0x02|0x03|0x04|0x05|0x06|0x07|0x08|0x09) ;;
  *) Die "unsupported NotMyFault crash type '${crashType}' (allowed: 0x01..0x09)" ;;
esac

mkdir -p "${outDir}"; chmod 0700 "${outDir}"
typeset metadataFile="${outDir}/intentional-preflight.json"
"${hostDir}/preflight-rhov.sh" \
  --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --require-trigger

GA_POD="$(jq -r .launcherPod "${metadataFile}")"; export GA_POD
GA_DOM="$(jq -r .domain "${metadataFile}")"; export GA_DOM

# Delete prior dumps only after every prerequisite is verified.  A guest
# non-zero status is propagated by guest-agent.py and aborts this script.
python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
  "Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue; Remove-Item 'C:\Windows\Minidump\*' -Force -ErrorAction SilentlyContinue; if (Test-Path 'C:\Windows\MEMORY.DMP') { throw 'MEMORY.DMP cleanup failed' }"

timeout "${watchTimeout}" bash "${hostDir}/watch-crash.sh" \
  --ns "${ns}" --vm "${vm}" --out "${outDir}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" &
watcherPid=$!
sleep 5
kill -0 "${watcherPid}" 2>/dev/null || Die 'watcher exited during pre-arm validation'

# Avoid cmd.exe and pass each argument directly to guest-exec.  exec-nowait
# returns once QGA confirms process creation, before the deliberate crash.
python3 "${hostDir}/guest-agent.py" exec-nowait \
  'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash "${crashType}" >/dev/null

set +e
wait "${watcherPid}"
typeset watcherStatus=$?
set -e
watcherPid=''
((watcherStatus == 0)) || Die "watcher/recovery pipeline failed with status ${watcherStatus}; inspect ${outDir}/evidence-summary.json and stage-errors.jsonl"
jq -e '.ok == true' "${outDir}/evidence-summary.json" >/dev/null || Die 'evidence summary is absent or reports failure'
echo "trigger-bsod-intentional: verified evidence package: ${outDir}"
true
