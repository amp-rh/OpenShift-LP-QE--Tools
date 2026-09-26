#!/usr/bin/env bash
# RHOV snapshot recovery. Metadata, storage identity, provenance, and image
# contract are all established before the watcher is permitted to stop the VMI.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset metadataFile=''; typeset outDir=''; typeset commandTimeout="${BSOD_COMMAND_TIMEOUT:-30}"
typeset extractEvtxBin="${BSOD_EXTRACT_EVTX_BIN:-${scriptDir}/extract-evtx.py}"
while (($#)); do
  case "$1" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help) echo 'usage: recover-natural-crash.sh --metadata PRE_STOP_METADATA.json --out VALIDATED_RUN_DIR'; exit 0 ;;
    *) echo "recover-natural-crash: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || { echo 'recover-natural-crash: --metadata and --out are required' >&2; exit 2; }

function Die () { echo "recover-natural-crash: ERROR: $*" >&2; exit 1; }
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
for tool in oc jq python3 sha256sum findmnt timeout realpath; do command -v "${tool}" >/dev/null 2>&1 || Die "required tool missing: ${tool}"; done

typeset runId=''; runId="$(jq -er .runId "${metadataFile}")"
typeset expectedOut=''; expectedOut="$(jq -er .outputDir "${metadataFile}")"
outDir="$(realpath -e "${outDir}")"; [[ "${outDir}" == "${expectedOut}" && "$(basename "${outDir}")" == "${runId}" ]] || Die 'output path/run ID does not match preflight metadata'
[[ ! -L "${outDir}" ]] || Die 'output path must not be a symlink'
typeset expectedTarget=''; expectedTarget="$(jq -er .evidenceMount.target "${metadataFile}")"
typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${expectedTarget}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die 'validated evidence mount is no longer mounted'
typeset actualMount=''; actualMount="$(jq -c '.filesystems[0] | {target:.target,source:.source,fsType:.fstype,device:.["maj:min"]}' <<<"${mountJson}")"
typeset expectedMount=''; expectedMount="$(jq -c '.evidenceMount | {target,source,fsType,device}' "${metadataFile}")"
[[ "${actualMount}" == "${expectedMount}" ]] || Die "evidence mount identity changed: expected ${expectedMount}, got ${actualMount}"
case "$(jq -r .evidenceMount.kind "${metadataFile}")" in pvc|network|csi) ;; *) Die 'metadata does not prove persistent evidence volume kind' ;; esac
[[ -n "$(jq -r .evidenceMount.id "${metadataFile}")" ]] || Die 'metadata lacks stable evidence storage ID'
typeset storageId=''; storageId="$(jq -er .evidenceMount.id "${metadataFile}")"
typeset identityMarker="${expectedTarget}/.bsod-storage-identity"
[[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${storageId}" ]] || Die 'evidence storage identity marker is missing or changed'

# Unique run directories may already contain watcher-owned captures, but never
# recovery-owned artifacts. Refuse instead of overwriting possible stale data.
typeset stale=''
stale="$(find "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name EventLogs -o -name parse-dump-header.json -o -name events.json -o -name recovery-summary.json -o -name checksums.sha256 \) -print -quit)"
[[ -z "${stale}" ]] || Die "pre-existing recovery artifact rejected: ${stale}"

typeset ns=''; ns="$(jq -er .namespace "${metadataFile}")"; typeset vm=''; vm="$(jq -er .vm "${metadataFile}")"
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc "${metadataFile}")"; typeset snapClass=''; snapClass="$(jq -er .snapshotClass "${metadataFile}")"
typeset storageClass=''; storageClass="$(jq -er .storageClass "${metadataFile}")"; typeset storageSize=''; storageSize="$(jq -er .storageSize "${metadataFile}")"
typeset volumeMode=''; volumeMode="$(jq -er .volumeMode "${metadataFile}")"; typeset recoveryImage=''; recoveryImage="$(jq -er .recoveryImage "${metadataFile}")"
typeset armedEpoch=''; armedEpoch="$(jq -er .armedEpoch "${metadataFile}")"; typeset inventory=''; inventory="$(jq -c .preCrashInventory "${metadataFile}")"
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ && "$(jq -r .recoveryImageContract "${metadataFile}")" == bash+guestfish-v1 ]] || Die 'recovery image contract was not proven by preflight'

typeset stageErrors="${outDir}/stage-errors.jsonl"; touch "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset recoveryLog="${outDir}/recovery.log"; : > "${recoveryLog}"; chmod 0600 "${recoveryLog}"
typeset suffix=''; suffix="$(date -u +%Y%m%d%H%M%S)-$$"; typeset snapName="bsod-${suffix}"; typeset snapPvc="${snapName}-pvc"; typeset recoveryPod="${snapName}-extract"
typeset snapshotCreated=0; typeset pvcCreated=0; typeset podCreated=0; typeset cleanupDone=0

function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${recoveryLog}"; true; }
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
function Cleanup () {
  ((cleanupDone == 0)) || return 0
  cleanupDone=1; typeset failed=0
  if ((podCreated)); then RunTimed 70 oc --request-timeout=65s delete pod "${recoveryPod}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${recoveryLog}" 2>&1 || { RecordError cleanup "failed to delete recovery pod ${recoveryPod}"; failed=1; }; podCreated=0; fi
  if ((pvcCreated)); then RunTimed 70 oc --request-timeout=65s delete pvc "${snapPvc}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${recoveryLog}" 2>&1 || { RecordError cleanup "failed to delete recovery PVC ${snapPvc}"; failed=1; }; pvcCreated=0; fi
  if ((snapshotCreated)); then RunTimed 70 oc --request-timeout=65s delete volumesnapshot "${snapName}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${recoveryLog}" 2>&1 || { RecordError cleanup "failed to delete VolumeSnapshot ${snapName}"; failed=1; }; snapshotCreated=0; fi
  return "${failed}"
}
function OnSignal () { typeset status="${1:?}"; RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

function WaitJsonPath () {
  typeset resource="${1:?}"; typeset name="${2:?}"; typeset expression="${3:?}"; typeset expected="${4:?}"; typeset timeoutSeconds="${5:?}"
  typeset deadline=$((SECONDS + timeoutSeconds)); typeset actual=''
  while ((SECONDS < deadline)); do actual="$(Oc get "${resource}" "${name}" -n "${ns}" -o "jsonpath=${expression}" 2>/dev/null || true)"; [[ "${actual}" == "${expected}" ]] && return 0; sleep 3; done
  return 1
}
function Guestfish () { Oc exec -n "${ns}" "${recoveryPod}" -- guestfish --ro -a /dev/disk-pvc -i "$@"; }
function GuestStat () {
  typeset guestPath="${1:?}"; typeset raw=''; raw="$(Guestfish stat "${guestPath}" 2>>"${recoveryLog}")" || return 1
  typeset size=''; size="$(awk '$1=="size:" {print $2}' <<<"${raw}")"; typeset mtime=''; mtime="$(awk '$1=="mtime:" {print $2}' <<<"${raw}")"
  [[ "${size}" =~ ^[0-9]+$ && "${mtime}" =~ ^[0-9]+$ ]] || return 1
  jq -cn --arg path "${guestPath}" --argjson size "${size}" --argjson mtime "${mtime}" '{path:$path,size:$size,mtime:$mtime}'
}
function ProveFreshDump () {
  typeset guestPath="${1:?}"; typeset stat=''; stat="$(GuestStat "${guestPath}")" || return 1
  typeset size=''; size="$(jq -r .size <<<"${stat}")"; typeset mtime=''; mtime="$(jq -r .mtime <<<"${stat}")"
  ((mtime >= armedEpoch)) || return 1
  jq -e --arg path "${guestPath}" --argjson size "${size}" --argjson mtime "${mtime}" \
    'all(.[]; ((.path|split("\\\\")|last|ascii_downcase) != ($path|split("/")|last|ascii_downcase)) or .size != $size or .mtime != $mtime)' <<<"${inventory}" >/dev/null
}
function StreamGuestFile () {
  typeset guestPath="${1:?}"; typeset localPath="${2:?}"; typeset artifactType="${3:?}"; typeset required="${4:-1}"; typeset requireFresh="${5:-0}"
  typeset temporary="${localPath}.tmp"; mkdir -p "$(dirname "${localPath}")"; rm -f "${temporary}"
  if ((requireFresh)) && ! ProveFreshDump "${guestPath}"; then
    if ((required)); then RecordError provenance "dump is stale, pre-existing, or lacks a post-arm timestamp: ${guestPath}"; fi
    return 1
  fi
  if ! Guestfish download "${guestPath}" /dev/stdout > "${temporary}" 2>>"${recoveryLog}"; then
    rm -f "${temporary}"
    if ((required)); then RecordError export "guestfish download failed: ${guestPath}"; else Log "optional artifact absent: ${guestPath}"; fi
    return 1
  fi
  if ! RunTimed 60 python3 "${scriptDir}/reliability.py" validate-artifact --type "${artifactType}" --path "${temporary}" >/dev/null; then
    rm -f "${temporary}"
    if ((required)); then RecordError validation "invalid ${artifactType} artifact: ${guestPath}"; else Log "optional artifact invalid: ${guestPath}"; fi
    return 1
  fi
  mv -f "${temporary}" "${localPath}"; chmod 0600 "${localPath}"; Log "exported ${guestPath} -> ${localPath#"${outDir}/"}"
}

Log "creating VolumeSnapshot ${ns}/${snapName} from mapped system-disk PVC ${guestPvc}"
jq -n --arg name "${snapName}" --arg ns "${ns}" --arg vm "${vm}" --arg class "${snapClass}" --arg pvc "${guestPvc}" \
  '{apiVersion:"snapshot.storage.k8s.io/v1",kind:"VolumeSnapshot",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-recovery","target-vm":$vm}},spec:{volumeSnapshotClassName:$class,source:{persistentVolumeClaimName:$pvc}}}' | Oc apply -f - >>"${recoveryLog}"
snapshotCreated=1; WaitJsonPath volumesnapshot "${snapName}" '{.status.readyToUse}' true 180 || { RecordError snapshot 'VolumeSnapshot readiness timed out'; exit 1; }
jq -n --arg name "${snapPvc}" --arg ns "${ns}" --arg vm "${vm}" --arg sc "${storageClass}" --arg size "${storageSize}" --arg mode "${volumeMode}" --arg snapshot "${snapName}" \
  '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-recovery","target-vm":$vm}},spec:{accessModes:["ReadWriteOnce"],volumeMode:$mode,storageClassName:$sc,resources:{requests:{storage:$size}},dataSource:{name:$snapshot,kind:"VolumeSnapshot",apiGroup:"snapshot.storage.k8s.io"}}}' | Oc apply -f - >>"${recoveryLog}"
pvcCreated=1; WaitJsonPath pvc "${snapPvc}" '{.status.phase}' Bound 300 || { RecordError snapshot-pvc 'recovery PVC binding timed out'; exit 1; }
jq -n --arg name "${recoveryPod}" --arg ns "${ns}" --arg vm "${vm}" --arg image "${recoveryImage}" --arg pvc "${snapPvc}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-recovery","target-vm":$vm}},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"extractor",image:$image,command:["/bin/bash","-ceu","trap : TERM INT; sleep infinity & wait"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}},volumeDevices:[{name:"guest-disk",devicePath:"/dev/disk-pvc"}],volumeMounts:[{name:"scratch",mountPath:"/tmp"}]}],volumes:[{name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},{name:"scratch",emptyDir:{medium:"Memory",sizeLimit:"1Gi"}}]}}' | Oc apply -f - >>"${recoveryLog}"
podCreated=1; WaitJsonPath pod "${recoveryPod}" '{.status.phase}' Running 180 || { RecordError recovery-pod 'recovery pod startup timed out'; exit 1; }
Oc exec -n "${ns}" "${recoveryPod}" -- /bin/bash -ceu 'command -v guestfish >/dev/null; test -r /dev/disk-pvc; guestfish --version >/dev/null' >>"${recoveryLog}" 2>&1 || { RecordError recovery-pod 'guestfish or read-only block device is unavailable'; exit 1; }

typeset dumpOk=0; typeset evtxOk=0
if StreamGuestFile '/Windows/MEMORY.DMP' "${outDir}/MEMORY.DMP" dump 0 1; then dumpOk=1; fi
typeset minidumpList=''; minidumpList="$(Guestfish ls /Windows/Minidump 2>>"${recoveryLog}" || true)"
while IFS= read -r name; do
  [[ "${name}" =~ ^[A-Za-z0-9._-]+\.[dD][mM][pP]$ ]] || continue
  if StreamGuestFile "/Windows/Minidump/${name}" "${outDir}/Minidump/${name}" dump 0 1; then dumpOk=1; fi
done <<<"${minidumpList}"
StreamGuestFile '/Windows/System32/winevt/Logs/System.evtx' "${outDir}/EventLogs/System.evtx" evtx && evtxOk=1
StreamGuestFile '/Windows/System32/winevt/Logs/Application.evtx' "${outDir}/EventLogs/Application.evtx" evtx 0 || true
((dumpOk)) || { RecordError export 'no fresh structurally valid MEMORY.DMP or minidump was exported'; exit 1; }
((evtxOk)) || { RecordError export 'System.evtx was not exported'; exit 1; }

typeset parseStatus=0
if [[ -s "${outDir}/MEMORY.DMP" ]]; then RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" > "${outDir}/parse-dump-header.json" 2>>"${recoveryLog}" || parseStatus=$?
else RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" > "${outDir}/parse-dump-header.json" 2>>"${recoveryLog}" || parseStatus=$?; fi
if ((parseStatus != 0)) || ! jq -e '.ok == true' "${outDir}/parse-dump-header.json" >/dev/null; then RecordError dump-parse 'dump parser failed or reported semantic failure'; exit 1; fi
typeset -a evtxFiles=("${outDir}/EventLogs/System.evtx"); [[ -s "${outDir}/EventLogs/Application.evtx" ]] && evtxFiles+=("${outDir}/EventLogs/Application.evtx")
RunTimed 120 "${extractEvtxBin}" --data-dir "${BSOD_DATA_DIR:-$(cd "${scriptDir}/../../data" && pwd)}" "${evtxFiles[@]}" > "${outDir}/events.json" 2>>"${recoveryLog}" || { RecordError evtx-parse 'EVTX parser failed'; exit 1; }
jq -e '.ok == true' "${outDir}/events.json" >/dev/null || { RecordError evtx-parse 'EVTX parser reported semantic failure'; exit 1; }

(
  cd "${outDir}"
  find . -type f ! -name '*.tmp' ! -name '*.log' ! -name stage-errors.jsonl ! -name '*-summary.json' ! -name checksums.sha256 -print0 |
    sort -z | xargs -0 sha256sum > checksums.sha256.tmp
  mv -f checksums.sha256.tmp checksums.sha256; chmod 0600 checksums.sha256
)
typeset cleanupStatus=0; Cleanup || cleanupStatus=$?
typeset summaryStatus=0
RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
  --mode rhov-snapshot-recovery --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename recovery-summary.json >/dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
Log 'snapshot recovery exported and validated all recovery-owned artifact classes'
