#!/usr/bin/env bash
# RHOV snapshot recovery.  All launcher/domain/PVC metadata is captured before
# VMI stop by preflight-rhov.sh.  This script never requires a launcher pod and
# streams artifacts from the recovery pod directly to durable local storage.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset metadataFile=''; typeset outDir=''
while (($#)); do
  case "$1" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help) echo 'usage: recover-natural-crash.sh --metadata PRE_STOP_METADATA.json --out DURABLE_DIR'; exit 0 ;;
    *) echo "recover-natural-crash: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || { echo 'recover-natural-crash: --metadata readable-file and --out are required' >&2; exit 2; }
mkdir -p "${outDir}"; chmod 0700 "${outDir}"

typeset ns=''; ns="$(jq -er .namespace "${metadataFile}")"
typeset vm=''; vm="$(jq -er .vm "${metadataFile}")"
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc "${metadataFile}")"
typeset snapClass=''; snapClass="$(jq -er .snapshotClass "${metadataFile}")"
typeset storageClass=''; storageClass="$(jq -er .storageClass "${metadataFile}")"
typeset storageSize=''; storageSize="$(jq -er .storageSize "${metadataFile}")"
typeset volumeMode=''; volumeMode="$(jq -er .volumeMode "${metadataFile}")"
typeset recoveryImage=''; recoveryImage="$(jq -er .recoveryImage "${metadataFile}")"
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ ]] || { echo 'recover-natural-crash: recovery image in metadata is not digest-pinned' >&2; exit 1; }

typeset stageErrors="${outDir}/stage-errors.jsonl"; touch "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset recoveryLog="${outDir}/recovery.log"; : > "${recoveryLog}"; chmod 0600 "${recoveryLog}"
typeset suffix=''; suffix="$(date -u +%Y%m%d%H%M%S)-$$"
typeset snapName="bsod-${suffix}"
typeset snapPvc="${snapName}-pvc"
typeset recoveryPod="${snapName}-extract"
typeset snapshotCreated=0; typeset pvcCreated=0; typeset podCreated=0

function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${recoveryLog}"; true; }
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
  true
}
function Cleanup () {
  typeset failed=0
  if ((podCreated)); then
    if ! oc delete pod "${recoveryPod}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${recoveryLog}" 2>&1; then
      RecordError cleanup "failed to delete recovery pod ${recoveryPod}"; failed=1
    else
      podCreated=0
    fi
  fi
  if ((pvcCreated)); then
    if ! oc delete pvc "${snapPvc}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${recoveryLog}" 2>&1; then
      RecordError cleanup "failed to delete recovery PVC ${snapPvc}"; failed=1
    else
      pvcCreated=0
    fi
  fi
  if ((snapshotCreated)); then
    if ! oc delete volumesnapshot "${snapName}" -n "${ns}" --ignore-not-found --wait=true --timeout=60s >>"${recoveryLog}" 2>&1; then
      RecordError cleanup "failed to delete VolumeSnapshot ${snapName}"; failed=1
    else
      snapshotCreated=0
    fi
  fi
  return "${failed}"
}
trap Cleanup EXIT INT TERM

function WaitJsonPath () {
  typeset resource="${1:?}"; typeset name="${2:?}"; typeset expression="${3:?}"; typeset expected="${4:?}"; typeset timeoutSeconds="${5:?}"
  typeset elapsed=0; typeset actual=''
  while ((elapsed < timeoutSeconds)); do
    actual="$(oc get "${resource}" "${name}" -n "${ns}" -o "jsonpath=${expression}" 2>/dev/null || true)"
    [[ "${actual}" == "${expected}" ]] && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  return 1
}

function StreamGuestFile () {
  typeset guestPath="${1:?}"; typeset localPath="${2:?}"; typeset artifactType="${3:?}"; typeset required="${4:-1}"
  typeset temporary="${localPath}.tmp"
  mkdir -p "$(dirname "${localPath}")"
  rm -f "${temporary}"
  if ! oc exec -n "${ns}" "${recoveryPod}" -- \
      guestfish --ro -a /dev/disk-pvc -i download "${guestPath}" /dev/stdout > "${temporary}" 2>>"${recoveryLog}"; then
    rm -f "${temporary}"
    if ((required)); then RecordError export "guestfish download failed: ${guestPath}"; else Log "optional artifact absent: ${guestPath}"; fi
    return 1
  fi
  if ! python3 "${scriptDir}/reliability.py" validate-artifact --type "${artifactType}" --path "${temporary}" >/dev/null; then
    rm -f "${temporary}"
    if ((required)); then RecordError validation "invalid ${artifactType} artifact: ${guestPath}"; else Log "optional artifact invalid: ${guestPath}"; fi
    return 1
  fi
  mv -f "${temporary}" "${localPath}"
  chmod 0600 "${localPath}"
  Log "exported ${guestPath} -> ${localPath#"${outDir}/"} sha256=$(sha256sum "${localPath}" | awk '{print $1}')"
}

Log "creating VolumeSnapshot ${ns}/${snapName} from pre-stop PVC ${guestPvc}"
jq -n \
  --arg name "${snapName}" --arg ns "${ns}" --arg vm "${vm}" --arg class "${snapClass}" --arg pvc "${guestPvc}" \
  '{apiVersion:"snapshot.storage.k8s.io/v1",kind:"VolumeSnapshot",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-recovery","target-vm":$vm}},spec:{volumeSnapshotClassName:$class,source:{persistentVolumeClaimName:$pvc}}}' |
  oc apply -f - >>"${recoveryLog}"
snapshotCreated=1
if ! WaitJsonPath volumesnapshot "${snapName}" '{.status.readyToUse}' true 180; then
  RecordError snapshot 'VolumeSnapshot did not become ready'; exit 1
fi

Log "creating recovery PVC ${ns}/${snapPvc} with source volume mode ${volumeMode}"
jq -n \
  --arg name "${snapPvc}" --arg ns "${ns}" --arg vm "${vm}" --arg sc "${storageClass}" \
  --arg size "${storageSize}" --arg mode "${volumeMode}" --arg snapshot "${snapName}" \
  '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-recovery","target-vm":$vm}},spec:{accessModes:["ReadWriteOnce"],volumeMode:$mode,storageClassName:$sc,resources:{requests:{storage:$size}},dataSource:{name:$snapshot,kind:"VolumeSnapshot",apiGroup:"snapshot.storage.k8s.io"}}}' |
  oc apply -f - >>"${recoveryLog}"
pvcCreated=1
if ! WaitJsonPath pvc "${snapPvc}" '{.status.phase}' Bound 300; then
  RecordError snapshot-pvc 'recovery PVC did not become Bound'; exit 1
fi

Log "starting digest-pinned read-only recovery pod ${ns}/${recoveryPod}"
jq -n \
  --arg name "${recoveryPod}" --arg ns "${ns}" --arg vm "${vm}" --arg image "${recoveryImage}" --arg pvc "${snapPvc}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-recovery","target-vm":$vm}},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"extractor",image:$image,command:["/bin/bash","-c","trap : TERM INT; sleep infinity & wait"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}},volumeDevices:[{name:"guest-disk",devicePath:"/dev/disk-pvc"}],volumeMounts:[{name:"scratch",mountPath:"/tmp"}],resources:{requests:{cpu:"100m",memory:"256Mi"},limits:{cpu:"2",memory:"4Gi"}}}],volumes:[{name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},{name:"scratch",emptyDir:{medium:"Memory",sizeLimit:"1Gi"}}]}}' |
  oc apply -f - >>"${recoveryLog}"
podCreated=1
if ! WaitJsonPath pod "${recoveryPod}" '{.status.phase}' Running 180; then
  RecordError recovery-pod 'recovery pod did not become Running'; exit 1
fi

typeset dumpOk=0; typeset evtxOk=0
if StreamGuestFile '/Windows/MEMORY.DMP' "${outDir}/MEMORY.DMP" dump; then dumpOk=1; fi

typeset minidumpList=''
minidumpList="$(oc exec -n "${ns}" "${recoveryPod}" -- guestfish --ro -a /dev/disk-pvc -i ls /Windows/Minidump 2>>"${recoveryLog}" || true)"
while IFS= read -r name; do
  [[ "${name}" =~ ^[A-Za-z0-9._-]+\.[dD][mM][pP]$ ]] || continue
  if StreamGuestFile "/Windows/Minidump/${name}" "${outDir}/Minidump/${name}" dump; then dumpOk=1; fi
done <<<"${minidumpList}"

if StreamGuestFile '/Windows/System32/winevt/Logs/System.evtx' "${outDir}/EventLogs/System.evtx" evtx; then evtxOk=1; fi
StreamGuestFile '/Windows/System32/winevt/Logs/Application.evtx' "${outDir}/EventLogs/Application.evtx" evtx 0 || true

((dumpOk)) || { RecordError export 'no valid MEMORY.DMP or minidump was exported'; exit 1; }
((evtxOk)) || { RecordError export 'System.evtx was not exported'; exit 1; }

if [[ -s "${outDir}/MEMORY.DMP" ]]; then
  bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" > "${outDir}/parse-dump-header.json" 2>>"${recoveryLog}" || RecordError dump-parse 'MEMORY.DMP header parsing failed'
elif [[ -d "${outDir}/Minidump" ]]; then
  bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" > "${outDir}/parse-dump-header.json" 2>>"${recoveryLog}" || RecordError dump-parse 'minidump header parsing failed'
fi
typeset -a evtxFiles=("${outDir}/EventLogs/System.evtx")
[[ -s "${outDir}/EventLogs/Application.evtx" ]] && evtxFiles+=("${outDir}/EventLogs/Application.evtx")
python3 "${scriptDir}/extract-evtx.py" --data-dir "${BSOD_DATA_DIR:-$(cd "${scriptDir}/../../data" && pwd)}" \
  "${evtxFiles[@]}" \
  > "${outDir}/events.json" 2>>"${recoveryLog}" || RecordError evtx-parse 'EVTX parsing failed'

# Persist an independent checksum list before deleting any recovery resource.
(
  cd "${outDir}"
  find . -type f ! -name '*.tmp' ! -name '*.log' ! -name 'stage-errors.jsonl' \
    ! -name '*-summary.json' ! -name 'checksums.sha256' -print0 |
    sort -z | xargs -0 sha256sum > checksums.sha256.tmp
  mv -f checksums.sha256.tmp checksums.sha256
  chmod 0600 checksums.sha256
)

# Delete the consuming pod before PVC/snapshot cleanup; the EXIT trap preserves
# this ordering on both success and failure.
typeset cleanupStatus=0; Cleanup || cleanupStatus=$?
typeset summaryStatus=0
python3 "${scriptDir}/reliability.py" write-summary \
  --out "${outDir}" --stage-errors "${stageErrors}" --mode rhov-snapshot-recovery \
  --vm "${vm}" --namespace "${ns}" --filename recovery-summary.json > /dev/null || summaryStatus=$?
if ((summaryStatus != 0)); then
  Log 'recovery summary reports missing, invalid, or failed stages'
fi
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
Log 'snapshot recovery exported and validated all required artifact classes'
true
