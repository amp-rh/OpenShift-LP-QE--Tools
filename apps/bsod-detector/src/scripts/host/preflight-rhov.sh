#!/usr/bin/env bash
# Fail-closed RHOV preflight. Cluster changes are limited to a short-lived
# recovery-image capability probe; VM lifecycle and configuration are untouched.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"
typeset configureScript="${BSOD_CONFIGURE_DUMPS:-${appDir}/src/scripts/guest/configure-dumps.ps1}"
typeset crashControlFile="${BSOD_CRASH_CONTROL_FILE:-${appDir}/src/data/crash-control.json}"
typeset ns=''; typeset vm=''; typeset outDir=''; typeset metadataFile=''; typeset runId=''
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset diskTarget=''; typeset memoryPvc="${BSOD_MEMORY_DUMP_PVC:-}"; typeset requireTrigger=0
typeset evidenceRoot="${BSOD_EVIDENCE_MOUNT:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_EVIDENCE_STORAGE_ID:-}"; typeset commandTimeout="${BSOD_COMMAND_TIMEOUT:-30}"
typeset probePod=''; typeset probeCreated=0; typeset temporaryDir=''
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
if [[ -n "${BSOD_GUEST_AGENT_BIN:-}" ]]; then guestAgent=("${BSOD_GUEST_AGENT_BIN}"); fi

function Die () { echo "preflight-rhov: ERROR: $*" >&2; exit 1; }
function RequireCommand () { command -v "$1" >/dev/null 2>&1 || Die "required local tool '$1' is not installed"; }
function ValidName () { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || Die "$2 '$1' is not a valid Kubernetes DNS label"; }
function RunTimed () {
  typeset seconds="${1:?}"; shift
  timeout --signal=TERM --kill-after=5 "${seconds}" "$@"
}
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
function Cleanup () {
  if ((probeCreated)); then
    RunTimed 20 oc --request-timeout=15s delete pod "${probePod}" -n "${ns}" --ignore-not-found --wait=true --timeout=15s >/dev/null 2>&1 || true
    probeCreated=0
  fi
  [[ -z "${temporaryDir}" ]] || rm -rf "${temporaryDir}"
  true
}
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

while (($#)); do
  case "$1" in
    --ns) ns="${2:?}"; shift 2 ;;
    --vm) vm="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --run-id) runId="${2:?}"; shift 2 ;;
    --evidence-mount) evidenceRoot="${2:?}"; shift 2 ;;
    --evidence-volume-kind) evidenceKind="${2:?}"; shift 2 ;;
    --evidence-storage-id) evidenceId="${2:?}"; shift 2 ;;
    --snap-class) snapClass="${2:?}"; shift 2 ;;
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;
    --memory-dump-pvc) memoryPvc="${2:?}"; shift 2 ;;
    --disk-target) diskTarget="${2:?}"; shift 2 ;;
    --require-trigger) requireTrigger=1; shift ;;
    -h|--help)
      echo 'usage: preflight-rhov.sh --ns NS --vm VM --out RUN_DIR --metadata FILE --run-id ID --evidence-mount MOUNT --evidence-volume-kind pvc|network|csi --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [--disk-target vda] [--require-trigger]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

[[ -n "${ns}" && -n "${vm}" && -n "${outDir}" && -n "${metadataFile}" && -n "${runId}" ]] || Die '--ns, --vm, --out, --metadata, and --run-id are required'
[[ "${runId}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$ ]] || Die "run ID '${runId}' is invalid"
[[ -n "${snapClass}" ]] || Die 'snapshot class is required'
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ ]] || Die 'recovery image must be digest-pinned'
[[ -n "${memoryPvc}" ]] || Die 'a dedicated KubeVirt memory-dump PVC is required'
[[ "${commandTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'BSOD_COMMAND_TIMEOUT must be a positive integer'
case "${evidenceKind}" in pvc|network|csi) ;; *) Die 'evidence volume kind must explicitly be pvc, network, or csi (hostPath, emptyDir, and local-node storage are forbidden)' ;; esac
[[ "${evidenceId}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]+$ ]] || Die 'evidence storage ID is required and must be stable'
ValidName "${ns}" namespace; ValidName "${vm}" VM; ValidName "${snapClass}" snapshot-class; ValidName "${memoryPvc}" memory-dump-PVC

for tool in oc virtctl jq python3 sha256sum findmnt timeout realpath sync; do RequireCommand "${tool}"; done
for helper in guest-agent.py reliability.py recover-natural-crash.sh collect-host-signals.sh parse-dump-header.sh extract-evtx.py; do
  [[ -r "${scriptDir}/${helper}" ]] || Die "required helper missing: ${scriptDir}/${helper}"
done
[[ -r "${configureScript}" && -r "${crashControlFile}" ]] || Die 'guest configuration inputs are missing'
RunTimed 10 python3 -c 'import Evtx.Evtx' || Die 'python-evtx is missing or cannot be imported'
RunTimed 10 virtctl memory-dump get --help >/dev/null || Die 'virtctl does not provide memory-dump get'
RunTimed 10 virtctl memory-dump download --help >/dev/null || Die 'virtctl does not provide memory-dump download'

[[ -d "${evidenceRoot}" && ! -L "${evidenceRoot}" ]] || Die "evidence mount must be an existing non-symlink directory: ${evidenceRoot}"
evidenceRoot="$(realpath -e "${evidenceRoot}")"
typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${evidenceRoot}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die "${evidenceRoot} is not a distinct mount point"
typeset mountTarget=''; mountTarget="$(jq -er '.filesystems[0].target' <<<"${mountJson}")"
typeset mountSource=''; mountSource="$(jq -er '.filesystems[0].source' <<<"${mountJson}")"
typeset mountFs=''; mountFs="$(jq -er '.filesystems[0].fstype' <<<"${mountJson}")"
typeset mountDevice=''; mountDevice="$(jq -er '.filesystems[0]["maj:min"]' <<<"${mountJson}")"
[[ "${mountTarget}" == "${evidenceRoot}" && "${mountTarget}" != / ]] || Die 'evidence root must be the exact target of a distinct non-root mount'
case "${mountFs}" in overlay|tmpfs|ramfs|rootfs) Die "ephemeral evidence filesystem is forbidden: ${mountFs}" ;; esac
typeset identityMarker="${evidenceRoot}/.bsod-storage-identity"
[[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${evidenceId}" ]] || Die "evidence mount must contain a pre-provisioned .bsod-storage-identity matching '${evidenceId}'"
if [[ "${evidenceKind}" == network ]]; then
  [[ "${mountFs}" =~ ^(nfs|nfs4|cifs|ceph|glusterfs|fuse\..+)$ ]] || Die "network evidence kind requires a network filesystem, got ${mountFs}"
else
  ValidName "${evidenceId}" evidence-PVC
  typeset evidencePvcJson=''; evidencePvcJson="$(Oc get pvc "${evidenceId}" -n "${ns}" -o json)" || Die "cannot read declared evidence PVC ${ns}/${evidenceId}"
  jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${evidencePvcJson}" >/dev/null || Die 'declared evidence PVC must be Bound and Filesystem mode'
fi
mkdir -p "${outDir}"; chmod 0700 "${outDir}"
outDir="$(realpath -e "${outDir}")"; metadataFile="$(realpath -m "${metadataFile}")"
[[ "${outDir}" == "${evidenceRoot}/"* && "$(dirname "${outDir}")" == "${evidenceRoot}" ]] || Die 'run output must be one unique direct child of the validated evidence mount'
[[ "$(basename "${outDir}")" == "${runId}" ]] || Die 'run output basename must equal the run ID'
[[ -z "$(find "${outDir}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || Die "run output is not empty: ${outDir}"
typeset probe=''; probe="$(mktemp "${outDir}/.write-probe.XXXXXX")"; printf 'durability-probe\n' > "${probe}"; sync "${probe}"; rm -f "${probe}"

temporaryDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-preflight.XXXXXX")"
typeset vmFile="${temporaryDir}/vm.json"; typeset vmiFile="${temporaryDir}/vmi.json"; typeset xmlFile="${temporaryDir}/domain.xml"
Oc get vm "${vm}" -n "${ns}" -o json > "${vmFile}" || Die "cannot read VirtualMachine ${ns}/${vm}"
[[ "$(jq -r '.spec.runStrategy // ""' "${vmFile}")" == Manual ]] || Die 'VM runStrategy must be Manual; preflight will not patch it'
Oc get vmi "${vm}" -n "${ns}" -o json > "${vmiFile}" || Die "running VMI ${ns}/${vm} is required"
[[ "$(jq -r '.status.phase // ""' "${vmiFile}")" == Running ]] || Die 'VMI phase must be Running'
typeset node=''; node="$(jq -r '.status.nodeName // ""' "${vmiFile}")"
typeset pod=''; pod="$(Oc get pod -n "${ns}" -l "kubevirt.io/domain=${vm}" -o json | jq -r '[.items[] | select(.status.phase=="Running") | .metadata.name] | if length==1 then .[0] else "" end')"
[[ -n "${pod}" ]] || Die 'exactly one running virt-launcher pod is required'
typeset dom="${ns}_${vm}"
Oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${xmlFile}" || Die 'cannot read libvirt domain XML for disk/PVC correlation'
typeset -a mapArgs=(--vmi-json "${vmiFile}" --domain-xml "${xmlFile}"); [[ -n "${diskTarget}" ]] && mapArgs+=(--target "${diskTarget}")
typeset mapping=''; mapping="$(RunTimed 15 python3 "${scriptDir}/reliability.py" map-disk "${mapArgs[@]}")" || Die 'selected libvirt target does not map uniquely to a VMI PVC/DataVolume'
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc <<<"${mapping}")"; diskTarget="$(jq -er .diskTarget <<<"${mapping}")"
typeset diskName=''; diskName="$(jq -er .diskName <<<"${mapping}")"; ValidName "${guestPvc}" guest-PVC

typeset pvcJson=''; pvcJson="$(Oc get pvc "${guestPvc}" -n "${ns}" -o json)" || Die "cannot read guest PVC ${guestPvc}"
typeset storageClass=''; storageClass="$(jq -r '.spec.storageClassName // ""' <<<"${pvcJson}")"
typeset volumeMode=''; volumeMode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvcJson}")"
typeset storageSize=''; storageSize="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvcJson}")"
[[ "${volumeMode}" == Block && -n "${storageClass}" && -n "${storageSize}" ]] || Die 'snapshot recovery requires a Block-mode guest PVC with storage class and requested size'
typeset memoryPvcJson=''; memoryPvcJson="$(Oc get pvc "${memoryPvc}" -n "${ns}" -o json)" || Die "cannot read memory-dump PVC ${memoryPvc}"
[[ "${memoryPvc}" != "${guestPvc}" ]] || Die 'memory-dump PVC must be distinct from the guest system disk'
jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${memoryPvcJson}" >/dev/null || Die 'memory-dump PVC must be Bound and Filesystem mode'
typeset provisioner=''; provisioner="$(Oc get storageclass "${storageClass}" -o json | jq -er .provisioner)"
typeset snapshotDriver=''; snapshotDriver="$(Oc get volumesnapshotclass "${snapClass}" -o json | jq -er .driver)"
[[ "${snapshotDriver}" == "${provisioner}" ]] || Die 'snapshot class driver does not match guest PVC provisioner'
Oc api-resources --api-group snapshot.storage.k8s.io -o name | grep -qx volumesnapshots.snapshot.storage.k8s.io || Die 'VolumeSnapshot API v1 is unavailable'

typeset -a permissions=(
  'get virtualmachines.kubevirt.io' 'update virtualmachines.kubevirt.io'
  'get virtualmachineinstances.kubevirt.io' 'update virtualmachines/stop.subresources.kubevirt.io'
  'update virtualmachines/start.subresources.kubevirt.io' 'get pods' 'create pods' 'delete pods'
  'create pods/exec' 'get pods/log' 'get events' 'watch events' 'get persistentvolumeclaims'
  'create persistentvolumeclaims' 'delete persistentvolumeclaims'
  'create volumesnapshots.snapshot.storage.k8s.io' 'get volumesnapshots.snapshot.storage.k8s.io'
  'delete volumesnapshots.snapshot.storage.k8s.io'
)
typeset permission=''
for permission in "${permissions[@]}"; do
  read -r verb resource <<<"${permission}"
  [[ "$(Oc auth can-i "${verb}" "${resource}" -n "${ns}")" == yes ]] || Die "RBAC denies '${verb} ${resource}'"
done

# Prove the digest-pinned recovery image contains its required tools before any
# watcher can arm and later stop the VMI.
probePod="bsod-probe-$(printf '%s' "${runId,,}" | tr -cd 'a-z0-9-' | cut -c1-35)-$$"
jq -n --arg name "${probePod}" --arg ns "${ns}" --arg image "${recoveryImage}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"probe",image:$image,command:["/bin/bash","-ceu","command -v guestfish; command -v bash; guestfish --version"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}' |
  Oc apply -f - >/dev/null || Die 'cannot create recovery-image capability probe'
probeCreated=1
typeset probePhase=''; typeset probeDeadline=$((SECONDS + 120))
while ((SECONDS < probeDeadline)); do
  probePhase="$(Oc get pod "${probePod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${probePhase}" == Succeeded ]] && break
  [[ "${probePhase}" == Failed ]] && Die 'recovery-image capability probe failed (bash/guestfish contract)'
  sleep 2
done
[[ "${probePhase}" == Succeeded ]] || Die 'recovery-image capability probe timed out'
Cleanup

export GA_NS="${ns}" GA_VM="${vm}" GA_POD="${pod}" GA_DOM="${dom}"
RunTimed 15 "${guestAgent[@]}" ping >/dev/null || Die 'qemu guest agent ping failed'
typeset cfg=''; cfg="$(RunTimed 120 "${guestAgent[@]}" psfile "${configureScript}" \
  --companion "${crashControlFile}" 'C:\Windows\Temp\crash-control.json' -- \
  -DataFile 'C:\Windows\Temp\crash-control.json' -VerifyOnly)" || Die 'guest crash-dump configuration verification failed'
jq -e '.ok == true and .matchesRecommended == true and .current.AutoReboot == 0 and .pageFile.adequate == true' <<<"${cfg}" >/dev/null || Die "guest CrashControl/pagefile prerequisites are not proven: ${cfg}"
typeset guestChecks=''; guestChecks="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows');minidumpParent=(Test-Path 'C:\Windows\Minidump');notMyFault=(Test-Path 'C:\Temp\nmf\notmyfaultc64.exe')}; \$r|ConvertTo-Json -Compress")" || Die 'guest diagnostic path verification failed'
jq -e '.windows == true and .dumpParent == true and .minidumpParent == true' <<<"${guestChecks}" >/dev/null || Die 'required guest dump paths are missing'
((requireTrigger == 0)) || jq -e '.notMyFault == true' <<<"${guestChecks}" >/dev/null || Die 'reviewed NotMyFault binary is missing'
typeset inventory=''; inventory="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$p=@('C:\Windows\MEMORY.DMP')+(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue|% FullName); \$r=@(\$p|? {Test-Path \$_}|% {\$i=Get-Item \$_; [ordered]@{path=\$i.FullName;size=\$i.Length;mtime=([DateTimeOffset]\$i.LastWriteTimeUtc).ToUnixTimeSeconds()}}); ConvertTo-Json -InputObject \$r -Compress")" || Die 'cannot inventory pre-existing guest dumps'
jq -e 'if type=="array" then all(.[]; (.path|type)=="string" and (.size|type)=="number" and (.mtime|type)=="number") elif . == null then true else false end' <<<"${inventory}" >/dev/null || Die 'guest dump inventory is invalid'
[[ "$(jq -r type <<<"${inventory}")" == array ]] || inventory='[]'

typeset armedEpoch=''; armedEpoch="$(date -u +%s)"
typeset temporary="${metadataFile}.tmp"
jq -n --arg runId "${runId}" --arg outputDir "${outDir}" --arg namespace "${ns}" --arg vm "${vm}" \
  --arg pod "${pod}" --arg domain "${dom}" --arg node "${node}" --arg guestPvc "${guestPvc}" \
  --arg diskName "${diskName}" --arg diskTarget "${diskTarget}" --arg memoryDumpPvc "${memoryPvc}" \
  --arg snapshotClass "${snapClass}" --arg storageClass "${storageClass}" --arg storageProvisioner "${provisioner}" \
  --arg storageSize "${storageSize}" --arg volumeMode "${volumeMode}" --arg recoveryImage "${recoveryImage}" \
  --arg mountTarget "${mountTarget}" --arg mountSource "${mountSource}" --arg mountFs "${mountFs}" \
  --arg mountDevice "${mountDevice}" --arg mountKind "${evidenceKind}" --arg mountId "${evidenceId}" \
  --argjson armedEpoch "${armedEpoch}" --argjson inventory "${inventory}" \
  '{schema:2,runId:$runId,outputDir:$outputDir,namespace:$namespace,vm:$vm,launcherPod:$pod,domain:$domain,node:$node,
    guestPvc:$guestPvc,diskName:$diskName,diskTarget:$diskTarget,memoryDumpPvc:$memoryDumpPvc,
    snapshotClass:$snapshotClass,storageClass:$storageClass,storageProvisioner:$storageProvisioner,
    storageSize:$storageSize,volumeMode:$volumeMode,recoveryImage:$recoveryImage,recoveryImageContract:"bash+guestfish-v1",
    armedEpoch:$armedEpoch,preCrashInventory:$inventory,
    evidenceMount:{target:$mountTarget,source:$mountSource,fsType:$mountFs,device:$mountDevice,kind:$mountKind,id:$mountId}}' > "${temporary}"
chmod 0600 "${temporary}"; mv -f "${temporary}" "${metadataFile}"
echo "preflight-rhov: OK: ${ns}/${vm}; run=${runId}; disk=${diskTarget}/${diskName}; PVC=${guestPvc}; evidence=${mountTarget} (${evidenceId})"
