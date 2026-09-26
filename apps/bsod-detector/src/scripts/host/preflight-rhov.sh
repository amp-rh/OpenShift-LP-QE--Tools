#!/usr/bin/env bash
# Fail-closed RHOV preflight.  This script performs reads and guest diagnostics;
# it never patches the VM, grants RBAC, or creates cluster resources.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"
typeset configureScript="${BSOD_CONFIGURE_DUMPS:-${appDir}/src/scripts/guest/configure-dumps.ps1}"
typeset crashControlFile="${BSOD_CRASH_CONTROL_FILE:-${appDir}/src/data/crash-control.json}"
typeset ns=''; typeset vm=''; typeset outDir=''; typeset metadataFile=''
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"
typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset diskTarget=''; typeset requireTrigger=0
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
if [[ -n "${BSOD_GUEST_AGENT_BIN:-}" ]]; then guestAgent=("${BSOD_GUEST_AGENT_BIN}"); fi

function Die () { echo "preflight-rhov: ERROR: $*" >&2; exit 1; }
function RequireCommand () { command -v "$1" >/dev/null 2>&1 || Die "required local tool '$1' is not installed"; }
function ValidName () { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || Die "$2 '$1' is not a valid Kubernetes DNS label"; }

while (($#)); do
  case "$1" in
    --ns) ns="${2:?}"; shift 2 ;;
    --vm) vm="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --snap-class) snapClass="${2:?}"; shift 2 ;;
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;
    --disk-target) diskTarget="${2:?}"; shift 2 ;;
    --require-trigger) requireTrigger=1; shift ;;
    -h|--help)
      echo 'usage: preflight-rhov.sh --ns NS --vm VM --out DIR --metadata FILE --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST [--disk-target vda] [--require-trigger]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

[[ -n "${ns}" && -n "${vm}" && -n "${outDir}" && -n "${metadataFile}" ]] || Die '--ns, --vm, --out, and --metadata are required'
[[ -n "${snapClass}" ]] || Die 'snapshot class is required (--snap-class or BSOD_SNAPSHOT_CLASS)'
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ ]] || Die 'recovery image must be immutable and digest-pinned (--recovery-image IMAGE@sha256:DIGEST)'
ValidName "${ns}" namespace
ValidName "${vm}" VM
ValidName "${snapClass}" snapshot-class

for tool in oc virtctl jq python3 sha256sum findmnt timeout; do RequireCommand "${tool}"; done
for helper in guest-agent.py reliability.py recover-natural-crash.sh collect-host-signals.sh parse-dump-header.sh; do
  [[ -r "${scriptDir}/${helper}" ]] || Die "required helper missing: ${scriptDir}/${helper}"
done
[[ -r "${configureScript}" ]] || Die "configure-dumps.ps1 is missing: ${configureScript}"
[[ -r "${crashControlFile}" ]] || Die "crash-control.json is missing: ${crashControlFile}"

[[ ! -L "${outDir}" ]] || Die "evidence destination must not be a symbolic link: ${outDir}"
mkdir -p "${outDir}"
chmod 0700 "${outDir}"
typeset probe=''; probe="$(mktemp "${outDir}/.write-probe.XXXXXX")"
printf 'durability-probe\n' > "${probe}"
sync "${probe}"
rm -f "${probe}"
typeset mountInfo=''; mountInfo="$(findmnt -T "${outDir}" -n -o FSTYPE,SOURCE 2>/dev/null)" || Die "cannot identify filesystem backing evidence destination ${outDir}"
case " ${mountInfo} " in
  *' overlay '*|*' tmpfs '*|*' ramfs '*) Die "evidence destination is ephemeral (${mountInfo}); mount durable storage at ${outDir}" ;;
esac

typeset vmJson=''; vmJson="$(oc get vm "${vm}" -n "${ns}" -o json)" || Die "cannot read VirtualMachine ${ns}/${vm}; check login and RBAC"
typeset runStrategy=''; runStrategy="$(jq -r '.spec.runStrategy // ""' <<<"${vmJson}")"
[[ "${runStrategy}" == 'Manual' ]] || Die "VirtualMachine ${ns}/${vm} has spec.runStrategy='${runStrategy:-unset}', required 'Manual'; update it explicitly before arming (preflight will not patch it)"

typeset vmiJson=''; vmiJson="$(oc get vmi "${vm}" -n "${ns}" -o json)" || Die "running VMI ${ns}/${vm} is required for pre-crash diagnostics"
typeset vmiPhase=''; vmiPhase="$(jq -r '.status.phase // ""' <<<"${vmiJson}")"
[[ "${vmiPhase}" == 'Running' ]] || Die "VMI ${ns}/${vm} phase is '${vmiPhase:-unset}', required Running"
typeset node=''; node="$(jq -r '.status.nodeName // ""' <<<"${vmiJson}")"
typeset guestPvc=''; guestPvc="$(jq -r '[.spec.volumes[]? | .persistentVolumeClaim.claimName // .dataVolume.name // empty] | map(select(length>0)) | unique | if length == 1 then .[0] else "" end' <<<"${vmiJson}")"
[[ -n "${guestPvc}" ]] || Die 'exactly one guest PVC/DataVolume must be identifiable; unsupported multi-disk layout requires an explicit design update'
ValidName "${guestPvc}" guest-PVC

typeset pod=''; pod="$(oc get pod -n "${ns}" -l "kubevirt.io/domain=${vm}" -o json | jq -r '[.items[] | select(.status.phase=="Running") | .metadata.name] | if length==1 then .[0] else "" end')"
[[ -n "${pod}" ]] || Die "exactly one running virt-launcher pod is required for ${ns}/${vm}"
typeset dom="${ns}_${vm}"

typeset pvcJson=''; pvcJson="$(oc get pvc "${guestPvc}" -n "${ns}" -o json)" || Die "cannot read guest PVC ${ns}/${guestPvc}"
typeset storageClass=''; storageClass="$(jq -r '.spec.storageClassName // ""' <<<"${pvcJson}")"
typeset volumeMode=''; volumeMode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvcJson}")"
typeset storageSize=''; storageSize="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvcJson}")"
[[ -n "${storageClass}" && -n "${storageSize}" ]] || Die "PVC ${ns}/${guestPvc} lacks storageClassName or requested storage"
[[ "${volumeMode}" == 'Block' ]] || Die "guest PVC ${ns}/${guestPvc} uses volumeMode=${volumeMode}; RHOV recovery currently requires a Block-mode system disk"
typeset storageClassJson=''; storageClassJson="$(oc get storageclass "${storageClass}" -o json)" || Die "storage class '${storageClass}' is unavailable"
typeset snapshotClassJson=''; snapshotClassJson="$(oc get volumesnapshotclass "${snapClass}" -o json)" || Die "VolumeSnapshotClass '${snapClass}' is unavailable"
typeset provisioner=''; provisioner="$(jq -r '.provisioner // ""' <<<"${storageClassJson}")"
typeset snapshotDriver=''; snapshotDriver="$(jq -r '.driver // ""' <<<"${snapshotClassJson}")"
[[ -n "${provisioner}" && "${snapshotDriver}" == "${provisioner}" ]] || Die "snapshot driver '${snapshotDriver:-unset}' does not match storage provisioner '${provisioner:-unset}'"
oc api-resources --api-group snapshot.storage.k8s.io -o name | grep -qx 'volumesnapshots.snapshot.storage.k8s.io' || Die 'VolumeSnapshot API v1 capability is unavailable'

typeset -a permissions=(
  'get virtualmachines.kubevirt.io'
  'get virtualmachineinstances.kubevirt.io'
  'update virtualmachines/stop.subresources.kubevirt.io'
  'update virtualmachines/start.subresources.kubevirt.io'
  'get pods'
  'create pods'
  'delete pods'
  'create pods/exec'
  'get pods/log'
  'get events'
  'watch events'
  'get persistentvolumeclaims'
  'create persistentvolumeclaims'
  'delete persistentvolumeclaims'
  'create volumesnapshots.snapshot.storage.k8s.io'
  'get volumesnapshots.snapshot.storage.k8s.io'
  'delete volumesnapshots.snapshot.storage.k8s.io'
)
typeset permission=''
for permission in "${permissions[@]}"; do
  read -r verb resource <<<"${permission}"
  [[ "$(oc auth can-i "${verb}" "${resource}" -n "${ns}")" == 'yes' ]] || Die "RBAC denies '${verb} ${resource}' in namespace ${ns}"
done

typeset -a targets=()
mapfile -t targets < <(oc exec -n "${ns}" "${pod}" -- virsh domblklist "${dom}" --details | awk '$2=="disk" && $3!="-" {print $3}' | sort -u)
if [[ -n "${diskTarget}" ]]; then
  printf '%s\n' "${targets[@]}" | grep -qx "${diskTarget}" || Die "requested disk target '${diskTarget}' is not attached to ${dom}"
elif ((${#targets[@]} == 1)); then
  diskTarget="${targets[0]}"
else
  Die "cannot select the dump disk from targets '${targets[*]:-none}'; pass --disk-target after verifying the Windows system disk"
fi

export GA_NS="${ns}" GA_VM="${vm}" GA_POD="${pod}" GA_DOM="${dom}"
timeout 15 "${guestAgent[@]}" ping >/dev/null || Die 'qemu guest agent ping failed'
typeset cfg=''
cfg="$(timeout 120 "${guestAgent[@]}" psfile \
  "${configureScript}" \
  --companion "${crashControlFile}" 'C:\Windows\Temp\crash-control.json' -- \
  -DataFile 'C:\Windows\Temp\crash-control.json' -VerifyOnly)" || Die 'guest crash-dump configuration verification failed'
jq -e '.ok == true and .matchesRecommended == true and .current.AutoReboot == 0 and .pageFile.adequate != false' <<<"${cfg}" >/dev/null || Die "guest CrashControl/pagefile prerequisites are not satisfied: ${cfg}"

typeset guestChecks=''
guestChecks="$(timeout 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows');minidumpParent=(Test-Path 'C:\Windows\Minidump');notMyFault=(Test-Path 'C:\Temp\nmf\notmyfaultc64.exe')}; \$r|ConvertTo-Json -Compress")" || Die 'guest diagnostic path verification command failed'
jq -e '.windows == true and .dumpParent == true and .minidumpParent == true' <<<"${guestChecks}" >/dev/null || Die "required guest dump paths are missing: ${guestChecks}"
if ((requireTrigger)); then
  jq -e '.notMyFault == true' <<<"${guestChecks}" >/dev/null || Die 'intentional trigger prerequisite C:\Temp\nmf\notmyfaultc64.exe is missing; install the reviewed NotMyFault binary before arming'
fi

typeset temporary="${metadataFile}.tmp"
jq -n \
  --arg namespace "${ns}" --arg vm "${vm}" --arg pod "${pod}" --arg domain "${dom}" \
  --arg node "${node}" --arg guestPvc "${guestPvc}" --arg diskTarget "${diskTarget}" \
  --arg snapshotClass "${snapClass}" --arg storageClass "${storageClass}" \
  --arg storageProvisioner "${provisioner}" \
  --arg storageSize "${storageSize}" --arg volumeMode "${volumeMode}" \
  --arg recoveryImage "${recoveryImage}" --arg evidenceMount "${mountInfo}" \
  '{namespace:$namespace,vm:$vm,launcherPod:$pod,domain:$domain,node:$node,
    guestPvc:$guestPvc,diskTarget:$diskTarget,snapshotClass:$snapshotClass,
    storageClass:$storageClass,storageProvisioner:$storageProvisioner,storageSize:$storageSize,volumeMode:$volumeMode,
    recoveryImage:$recoveryImage,evidenceMount:$evidenceMount}' > "${temporary}"
chmod 0600 "${temporary}"
mv -f "${temporary}" "${metadataFile}"
echo "preflight-rhov: OK: ${ns}/${vm}; runStrategy=Manual; disk=${diskTarget}; PVC=${guestPvc}; evidence=${mountInfo}"
true
