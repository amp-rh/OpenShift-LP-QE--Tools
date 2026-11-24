#!/usr/bin/env bash
# Fail-closed RHOV preflight validation before crash injection and watcher
# Verifies: cluster permissions, VM/VMI state, storage configuration, recovery image capability
# Produces metadata.json consumed by watch-crash.sh and extract--guest-os--crash-info.sh
# Side effects: temporary probe pod; missing evidence and memory-dump PVCs are created. In the guest it
# uploads and runs the read-only validate-crash-settings.ps1 with crash-control.json (C:\Windows\Temp);
# with --require-trigger the validator also stages the latest NotMyFault. No VM lifecycle, registry,
# page file, agent installation or reboot changes (runStrategy must be Manual).
# Phases run in this order and Die names the failing one: args, tools, config, local-inputs,
# evidence-storage, run-output, vm, storage, rbac, recovery-image, guest, metadata.
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset srcDir=''; srcDir="$(dirname -- "${BASH_SOURCE[0]}")"
typeset scrName="${BASH_SOURCE[0]##*/}"
typeset appDir="${srcDir}/../../.."
# All configuration: environment defaults overridden by the flags in flagArr; paths are canonicalized in place once validated.
# BSOD_DET__VALIDATE__CRASH_SETTINGS overrides the read-only guest validator path.
# BSOD_DET__CONFIGURE__DUMPS is a deprecated alias kept for existing callers; it must name a copy of
# validate-crash-settings.ps1 (any other file name is refused before anything runs, and the output
# must come from that validator). There is no fallback to the former configuration script.
typeset -A cfgArr=(
    [ns]='' [vm]='' [outDir]='' [metadataFile]='' [runId]='' [diskTarget]='' [isTriggerRequired]=0
    [snapClass]="${BSOD_DET__SNAPSHOT__CLASS:-}" [recoveryImage]="${BSOD_DET__RECOVERY__IMAGE:-}"
    [memoryPvc]="${BSOD_DET__MEMORY__DUMP_PVC:-}" [evidenceRoot]="${BSOD_DET__EVIDENCE__MOUNT:-}"
    [evidenceKind]="${BSOD_EVIDENCE_VOLUME_KIND:-}" [evidenceId]="${BSOD_DET__EVIDENCE__STORAGE_ID:-}"
    [evidenceSize]="${BSOD_DET__EVIDENCE__STORAGE_SIZE:-200Gi}" [guestAgentBin]="${BSOD_DET__GUEST_AGENT__BIN:-}"
    [validatorScript]="${BSOD_DET__VALIDATE__CRASH_SETTINGS:-${BSOD_DET__CONFIGURE__DUMPS:-${appDir}/src/scripts/guest/validate-crash-settings.ps1}}"
    [crashControlFile]="${BSOD_DET__CRASH_CONTROL__FILE:-${appDir}/src/data/crash-control.json}"
    [guestCtlFile]='C:\Windows\Temp\crash-control.json'
)
typeset -A flagArr=(
    [--ns]=ns [--vm]=vm [--out]=outDir [--metadata]=metadataFile [--run-id]=runId
    [--evidence-mount]=evidenceRoot [--evidence-volume-kind]=evidenceKind [--evidence-storage-id]=evidenceId
    [--snap-class]=snapClass [--recovery-image]=recoveryImage [--memory-dump-pvc]=memoryPvc [--disk-target]=diskTarget
)
# Validated facts for the metadata document, keyed by metadata field name; every value is a string.
typeset -A metaArr=()
typeset phase=args probePod='' temporaryDir='' evidenceMount='' mountJson='' mountFs='' key='' item='' verb='' resource=''
typeset -i isProbeCreated=0 isTestMode=0 isEvidencePvcRequired=0 isPingOk=0 i=0 waitSec=120 pingTries=5

function Die () {
    : "preflight-rhov: ERROR: [${phase}] $*"
    false
}
function ValidName () {
    typeset value="${1:?}"; (($#)) && shift
    typeset label="${1:?}"; (($#)) && shift
    [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || Die "${label} '${value}' is not a valid Kubernetes DNS label"
    true
}
# RunTimed — tools without built-in timeout flags (python3, virtctl, findmnt).
# For oc API calls, use oc --request-timeout directly.
function RunTimed () {
    typeset seconds="${1:?}"; (($#)) && shift
    timeout --signal=TERM --kill-after=5 "${seconds}" "$@"
}
function Cleanup () {
    ((isProbeCreated == 0)) || oc --request-timeout=20s delete pod "${probePod}" -n "${cfgArr[ns]}" --ignore-not-found --wait=true --timeout=15s 1> /dev/null || true
    isProbeCreated=0
    [ -z "${temporaryDir}" ] || rm -rf "${temporaryDir}"
    true
}
# Polls .status.phase of a resource in namespace cfgArr[ns] for up to waitSec seconds; the named state variable moves
# Waiting -> Done (wanted phase reached) | Failed (failure phase reached) | TimedOut (deadline passed).
# Polling stays in the calling shell (no command substitution), so the INT/TERM traps also end it.
function AwaitPhase () {
    typeset -n stateRef="${1:?}"; (($#)) && shift
    typeset kind="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    typeset donePhase="${1:?}"; (($#)) && shift
    typeset failPhase="${1?}"; (($#)) && shift
    typeset -i interval="${1:?}"; (($#)) && shift
    typeset current='' deadline=$((SECONDS + waitSec))
    stateRef=Waiting
    while [[ "${stateRef}" == Waiting ]]; do
        if ((SECONDS >= deadline)); then stateRef=TimedOut; break; fi
        current="$(oc --request-timeout=30s get "${kind}" "${name}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' || true)"
        if [[ "${current}" == "${donePhase}" ]]; then stateRef=Done
        elif [[ -n "${failPhase}" && "${current}" == "${failPhase}" ]]; then stateRef=Failed
        else : "waiting for ${kind} ${name} (current phase: ${current})"; sleep "${interval}"
        fi
    done
    true
}
# In namespace cfgArr[ns], only a PVC reported NotFound is created (Filesystem, ReadWriteOnce, given storage class and size)
# and must bind within waitSec seconds; other read errors fail. The PVC must then be Bound and in Filesystem volume mode.
function EnsurePVC () {
    typeset label="${1:?}"; (($#)) && shift
    typeset pvc="${1:?}"; (($#)) && shift
    typeset storageClass="${1:?}"; (($#)) && shift
    typeset size="${1:?}"; (($#)) && shift
    typeset pvcJson='' bindState=''
    pvcJson="$(oc --request-timeout=30s get pvc "${pvc}" -n "${cfgArr[ns]}" -o json --ignore-not-found)" || Die "cannot read ${label} PVC ${cfgArr[ns]}/${pvc}"
    [[ -n "${pvcJson}" ]] || {
        jq -n --arg name "${pvc}" --arg ns "${cfgArr[ns]}" --arg sc "${storageClass}" --arg size "${size}" \
          '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns},spec:{accessModes:["ReadWriteOnce"],storageClassName:$sc,resources:{requests:{storage:$size}},volumeMode:"Filesystem"}}' |
          oc --request-timeout=30s apply -f - 1> /dev/null || Die "failed to create ${label} PVC ${pvc}"
        AwaitPhase bindState pvc "${pvc}" Bound '' 5
        [[ "${bindState}" == Done ]] || Die "${label} PVC ${pvc} failed to bind within ${waitSec} seconds"
        pvcJson="$(oc --request-timeout=30s get pvc "${pvc}" -n "${cfgArr[ns]}" -o json)" || Die "cannot read ${label} PVC ${cfgArr[ns]}/${pvc}"
    }
    jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${pvcJson}" 1> /dev/null || Die "${label} PVC must be Bound and Filesystem mode"
    true
}
trap Cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($#)); do
    case "${1}" in
      (--require-trigger) cfgArr[isTriggerRequired]=1; shift;;
      (-h|--help)
        echo "usage: ${scrName} --ns NS --vm VM --out RUN_DIR --metadata FILE --run-id ID --evidence-mount MOUNT --evidence-volume-kind pvc|network|csi --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE --memory-dump-pvc PVC [--disk-target vda] [--require-trigger]"
        exit 0
        ;;
      (*)
        [[ -n "${1}" && -n "${flagArr[${1}]:-}" ]] || Die "unknown argument: ${1}"  # -n first: an empty subscript is an error
        cfgArr[${flagArr[${1}]}]="${2:?}"; shift 2
        ;;
    esac
done

phase=tools
for item in oc virtctl jq python3 sha256sum findmnt timeout realpath sync; do command -v "${item}" 1> /dev/null || Die "required local tool '${item}' is not installed"; done

phase=config
for key in ns vm outDir metadataFile runId; do
    [[ -n "${cfgArr[${key}]}" ]] || Die '--ns, --vm, --out, --metadata, and --run-id are required'
done
# Checked in order: <cfgArr key> <ERE the value must match; '.' means non-empty> <failure message>.
typeset -a cfgRuleArr=(
    runId           '^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$'    "run ID '${cfgArr[runId]}' is invalid"
    snapClass       .                                      'snapshot class is required'
    recoveryImage   .                                      'recovery image is required (--recovery-image)'
    memoryPvc       .                                      'a dedicated KubeVirt memory-dump PVC is required'
    evidenceKind    '^(pvc|network|csi)$'                  'evidence volume kind must explicitly be pvc, network, or csi'
    evidenceId      '^[A-Za-z0-9][A-Za-z0-9._:/-]+$'       'evidence storage ID is required and must be stable'
    validatorScript '(^|/)validate-crash-settings\.ps1$'   "refusing to run ${cfgArr[validatorScript]}: the guest validator must be validate-crash-settings.ps1"
)
for ((i = 0; i < ${#cfgRuleArr[@]}; i += 3)); do
    [[ "${cfgArr[${cfgRuleArr[i]}]}" =~ ${cfgRuleArr[i + 1]} ]] || Die "${cfgRuleArr[i + 2]}"
done
for item in ns:namespace vm:VM snapClass:snapshot-class memoryPvc:memory-dump-PVC; do ValidName "${cfgArr[${item%%:*}]}" "${item#*:}"; done
[[ -n "${BSOD_DET__CONFIGURE__DUMPS:-}" && -z "${BSOD_DET__VALIDATE__CRASH_SETTINGS:-}" ]] && : 'preflight-rhov: WARN: BSOD_DET__CONFIGURE__DUMPS is deprecated; set BSOD_DET__VALIDATE__CRASH_SETTINGS instead'
typeset -a guestAgentArr=(python3 "${srcDir}/guest-agent.py")
[[ -z "${cfgArr[guestAgentBin]}" ]] || guestAgentArr=("${cfgArr[guestAgentBin]}")

phase=local-inputs
[[ -d "${srcDir}" && -r "${srcDir}" && -x "${srcDir}" ]] || Die "host scripts directory not accessible: ${srcDir}"
# Explicit required helpers — find alone only proves existing files are readable, not that each
# pipeline helper is present. The scan appends every other non-.bak .sh/.py helper in host/.
typeset -a helperArr=(
    guest-agent.py reliability.py extract--guest-os--crash-info.sh
    collect-host-signals.sh parse-dump-header.sh watch-crash.sh preflight-rhov.sh
)
mapfile -t -O "${#helperArr[@]}" helperArr < <(find "${srcDir}" -maxdepth 1 -type f ! -name '*.bak' \( -name '*.sh' -o -name '*.py' \) -printf '%f\n')
for item in "${helperArr[@]}"; do
    [[ -r "${srcDir}/${item}" ]] || Die "required helper missing: ${srcDir}/${item}"
done
[[ -r "${cfgArr[validatorScript]}" && -r "${cfgArr[crashControlFile]}" ]] || Die 'guest validation inputs are missing'
for item in get download; do
    RunTimed 10 virtctl memory-dump "${item}" --help 1> /dev/null || Die "virtctl does not provide memory-dump ${item}"
done

phase=evidence-storage
[[ -d "${cfgArr[evidenceRoot]}" && ! -L "${cfgArr[evidenceRoot]}" ]] || Die "evidence mount must be an existing non-symlink directory: ${cfgArr[evidenceRoot]}"
cfgArr[evidenceRoot]="$(realpath -e "${cfgArr[evidenceRoot]}")"
typeset identityMarker="${cfgArr[evidenceRoot]}/.bsod-storage-identity"
if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${cfgArr[evidenceId]}" ]]; then
    : 'preflight-rhov: evidence storage validated (identity marker present, test mode)'
    isTestMode=1
fi
# The mount record is kept as jq-validated JSON; it becomes the metadata evidenceMount object.
if ((isTestMode)); then
    evidenceMount="$(jq -cn --arg target "${cfgArr[evidenceRoot]}" '{target:$target,source:"test-volume",fsType:"ext4",device:"test-device"}')"
else
    mountJson="$(RunTimed 10 findmnt -J -M "${cfgArr[evidenceRoot]}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die "${cfgArr[evidenceRoot]} is not a distinct mount point"
    evidenceMount="$(jq -ce '.filesystems[0] | {target,source,fsType:.fstype,device:.["maj:min"]} | select(all(.[]; type == "string"))' <<<"${mountJson}")" || Die 'findmnt returned an incomplete mount record'
    jq -e --arg root "${cfgArr[evidenceRoot]}" '.target == $root and .target != "/"' <<<"${evidenceMount}" 1> /dev/null || Die 'evidence root must be the exact target of a distinct non-root mount'
    mountFs="$(jq -r .fsType <<<"${evidenceMount}")"
    case "${mountFs}" in (overlay|tmpfs|ramfs|rootfs) Die "ephemeral evidence filesystem is forbidden: ${mountFs}";; esac
    [[ "${cfgArr[evidenceKind]}" != network || "${mountFs}" =~ ^(nfs|nfs4|cifs|ceph|glusterfs|fuse\..+)$ ]] || Die "network evidence kind requires a network filesystem, got ${mountFs}"
fi
# Fast-fail on bad evidence PVC name before contacting cluster further. Its existence check and
# auto-creation happen later, once storageClass is known from the guest disk.
[[ "${isTestMode}" -eq 0 || "${cfgArr[evidenceKind]}" != network ]] && isEvidencePvcRequired=1
((isEvidencePvcRequired == 0)) || ValidName "${cfgArr[evidenceId]}" evidence-PVC

phase=run-output
mkdir -p "${cfgArr[outDir]}"; chmod 0700 "${cfgArr[outDir]}"
cfgArr[outDir]="$(realpath -e "${cfgArr[outDir]}")"; cfgArr[metadataFile]="$(realpath -m "${cfgArr[metadataFile]}")"
[[ "${cfgArr[outDir]}" == "${cfgArr[evidenceRoot]}/"* && "$(dirname "${cfgArr[outDir]}")" == "${cfgArr[evidenceRoot]}" ]] || Die 'run output must be one unique direct child of the validated evidence mount'
[[ "$(basename "${cfgArr[outDir]}")" == "${cfgArr[runId]}" ]] || Die 'run output basename must equal the run ID'
[[ -z "$(find "${cfgArr[outDir]}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || Die "run output is not empty: ${cfgArr[outDir]}"
typeset probe=''; probe="$(mktemp "${cfgArr[outDir]}/.write-probe.XXXXXX")"; printf 'durability-probe\n' > "${probe}"; sync "${probe}"; rm -f "${probe}"

phase=vm
temporaryDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-preflight.XXXXXX")"
typeset vmFile="${temporaryDir}/vm.json" vmiFile="${temporaryDir}/vmi.json" xmlFile="${temporaryDir}/domain.xml"
# runStrategy must be Manual — preflight must not patch it.
oc --request-timeout=30s get vm "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o json > "${vmFile}" || Die "cannot read VirtualMachine ${cfgArr[ns]}/${cfgArr[vm]}"
jq -e '.spec.runStrategy == "Manual"' "${vmFile}" 1> /dev/null || Die 'VM runStrategy must be Manual; preflight will not patch it'
oc --request-timeout=30s get vmi "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o json > "${vmiFile}" || Die "running VMI ${cfgArr[ns]}/${cfgArr[vm]} is required"
jq -e '.status.phase == "Running"' "${vmiFile}" 1> /dev/null || Die 'VMI phase must be Running'
metaArr[node]="$(jq -r '.status.nodeName // ""' "${vmiFile}")"
metaArr[launcherPod]="$(oc --request-timeout=30s get pod -n "${cfgArr[ns]}" -l "kubevirt.io/vm=${cfgArr[vm]}" -o json |
  jq -er '[.items[] | select(.status.phase == "Running") | .metadata.name] | select(length == 1) | .[0]')" || Die 'exactly one running virt-launcher pod is required'
metaArr[domain]="${cfgArr[ns]}_${cfgArr[vm]}"
oc --request-timeout=30s exec -n "${cfgArr[ns]}" "${metaArr[launcherPod]}" -- virsh dumpxml "${metaArr[domain]}" > "${xmlFile}" || Die 'cannot read libvirt domain XML for disk/PVC correlation'
typeset -a mapArgArr=(--vmi-json "${vmiFile}" --domain-xml "${xmlFile}"); [[ -z "${cfgArr[diskTarget]}" ]] || mapArgArr+=(--target "${cfgArr[diskTarget]}")
typeset mapping=''; mapping="$(RunTimed 15 python3 "${srcDir}/reliability.py" map-disk "${mapArgArr[@]}")" || Die 'selected libvirt target does not map uniquely to a VMI PVC/DataVolume'
for key in guestPvc diskTarget diskName; do
    metaArr[${key}]="$(jq -er --arg key "${key}" '.[$key] | strings' <<<"${mapping}")" || Die "disk mapping has no ${key}"
done
ValidName "${metaArr[guestPvc]}" guest-PVC
typeset pvcJson=''; pvcJson="$(oc --request-timeout=30s get pvc "${metaArr[guestPvc]}" -n "${cfgArr[ns]}" -o json)" || Die "cannot read guest PVC ${metaArr[guestPvc]}"
jq -e '.spec | .volumeMode == "Block" and ([.storageClassName, .resources.requests.storage] | all(type == "string" and length > 0))' <<<"${pvcJson}" 1> /dev/null || Die 'snapshot recovery requires a Block-mode guest PVC with storage class and requested size'
metaArr[storageClass]="$(jq -r .spec.storageClassName <<<"${pvcJson}")"
metaArr[storageSize]="$(jq -r .spec.resources.requests.storage <<<"${pvcJson}")"
metaArr[volumeMode]="$(jq -r .spec.volumeMode <<<"${pvcJson}")"

phase=storage
# Evidence PVC sized to hold multiple run evidence dirs; memory-dump PVC sized like the guest disk.
((isEvidencePvcRequired == 0)) || EnsurePVC evidence "${cfgArr[evidenceId]}" "${metaArr[storageClass]}" "${cfgArr[evidenceSize]}"
# Checked before EnsurePVC so the guest system disk can never become the target of a PVC apply.
[[ "${cfgArr[memoryPvc]}" != "${metaArr[guestPvc]}" ]] || Die 'memory-dump PVC must be distinct from the guest system disk'
EnsurePVC memory-dump "${cfgArr[memoryPvc]}" "${metaArr[storageClass]}" "${metaArr[storageSize]}"
# Snapshot class driver must match PVC provisioner — mismatches produce silent failures at snapshot time.
metaArr[storageProvisioner]="$(oc --request-timeout=30s get storageclass "${metaArr[storageClass]}" -o json | jq -er .provisioner)" || Die "cannot read the provisioner of storage class ${metaArr[storageClass]}"
typeset snapshotDriver=''; snapshotDriver="$(oc --request-timeout=30s get volumesnapshotclass "${cfgArr[snapClass]}" -o json | jq -er .driver)" || Die "cannot read the driver of snapshot class ${cfgArr[snapClass]}"
[[ "${snapshotDriver}" == "${metaArr[storageProvisioner]}" ]] || Die 'snapshot class driver does not match guest PVC provisioner'
oc --request-timeout=30s api-resources --api-group snapshot.storage.k8s.io -o name | grep -x volumesnapshots.snapshot.storage.k8s.io 1> /dev/null || Die 'VolumeSnapshot API v1 is unavailable'

phase=rbac
typeset -a permArr=(
  'get virtualmachines.kubevirt.io' 'update virtualmachines.kubevirt.io'
  'get virtualmachineinstances.kubevirt.io' 'update virtualmachines/stop.subresources.kubevirt.io'
  'update virtualmachines/start.subresources.kubevirt.io' 'get pods' 'create pods' 'delete pods'
  'create pods/exec' 'get pods/log' 'get events' 'watch events' 'get persistentvolumeclaims'
  'create persistentvolumeclaims' 'delete persistentvolumeclaims'
  'create volumesnapshots.snapshot.storage.k8s.io' 'get volumesnapshots.snapshot.storage.k8s.io'
  'delete volumesnapshots.snapshot.storage.k8s.io'
)
for item in "${permArr[@]}"; do
    read -r verb resource <<<"${item}"
    [[ "$(oc --request-timeout=30s auth can-i "${verb}" "${resource}" -n "${cfgArr[ns]}")" == yes ]] || Die "RBAC denies '${verb} ${resource}'"
done

phase=recovery-image
# Probe pod verifies the recovery image has bash + guestfish before watcher is armed. It is marked for
# cleanup before the apply, so a pod created by an apply that still reports failure is deleted too.
probePod="bsod-probe-$(printf '%s' "${cfgArr[runId],,}" | tr -cd 'a-z0-9-' | cut -c1-35)-$$"
isProbeCreated=1
jq -n --arg name "${probePod}" --arg ns "${cfgArr[ns]}" --arg image "${cfgArr[recoveryImage]}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"probe",image:$image,command:["/bin/bash","-ceu","command -v guestfish; command -v bash; guestfish --version"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}' |
  oc --request-timeout=30s apply -f - 1> /dev/null || Die 'cannot create recovery-image capability probe'
typeset probeState=''; AwaitPhase probeState pod "${probePod}" Succeeded Failed 2
case "${probeState}" in
  (Done) ;;
  (Failed) Die 'recovery-image capability probe failed (bash/guestfish contract)';;
  (*) Die 'recovery-image capability probe timed out';;
esac
Cleanup

phase=guest
export BSOD_DET__NAMESPACE="${cfgArr[ns]}" BSOD_DET__VM__NAME="${cfgArr[vm]}" BSOD_DET__POD__NAME="${metaArr[launcherPod]}" BSOD_DET__DOMAIN__NAME="${metaArr[domain]}"
# The QEMU guest agent is installed and checked in the golden image (golden-image-pre-reboot.ps1
# installs it, golden-image-post-reboot.ps1 refuses to seal without it). There is no bootstrap:
# installing the agent needs a responding agent, so an unresponsive agent is a golden-image problem.
for ((i = 1; i <= pingTries; i++)); do
    RunTimed 15 "${guestAgentArr[@]}" ping 1> /dev/null && { isPingOk=1; break; }
    : "qemu guest agent ping attempt ${i} failed; retrying..."
    sleep 3
done
((isPingOk)) || Die "qemu guest agent did not answer ${pingTries} pings: the VM must run a golden image with the QEMU-GA service installed and running (golden-image-pre-reboot.ps1 installs it, golden-image-post-reboot.ps1 checks it); start the service or rebuild the image"

# Read-only validation: the guest's crash settings must already match crash-control.json (the
# golden image configures them; nothing is changed or rebooted here). With --require-trigger the
# validator also stages the latest NotMyFault and reports its source and SHA-256.
typeset -a validatorArgArr=(-dataFile "${cfgArr[guestCtlFile]}"); ((cfgArr[isTriggerRequired] == 0)) || validatorArgArr+=(-stageNotMyFault)
typeset validation=''; validation="$(RunTimed 300 "${guestAgentArr[@]}" psfile "${cfgArr[validatorScript]}" \
  --companion "${cfgArr[crashControlFile]}" "${cfgArr[guestCtlFile]}" -- \
  "${validatorArgArr[@]}")" || Die "guest crash-setting validation failed: ${validation}"
# Accepted only as exactly one validate-crash-settings.ps1 JSON result that matches the golden image.
jq -se 'length == 1' <<<"${validation}" 1> /dev/null || Die "guest crash-setting validator did not return exactly one JSON document: ${validation}"
jq -e '.script == "validate-crash-settings.ps1" and .action == "validated" and .ok == true and
  .matchesRecommended == true and .current.AutoReboot == 0 and .pageFile.adequate == true' <<<"${validation}" 1> /dev/null || \
  Die "guest crash settings do not match the golden image (nothing was changed; rebuild or fix the golden image): $(jq -c '{mismatches,pageFile}' <<<"${validation}" || printf '%s' "${validation}")"
typeset notMyFault='null'
if ((cfgArr[isTriggerRequired])); then
    # Staged from the official HTTPS host with both SHA-256 values, which are recorded lower-case.
    notMyFault="$(jq -ce '.notMyFault | select(.status == "staged" and (.sha256 | test("^[0-9A-Fa-f]{64}$")) and
      (.archiveSHA256 | test("^[0-9A-Fa-f]{64}$")) and (.resolvedSource | startswith("https://download.sysinternals.com/")) and
      .stagedPath == "C:\\Temp\\nmf\\notmyfaultc64.exe") | .sha256 |= ascii_downcase | .archiveSHA256 |= ascii_downcase' <<<"${validation}")" || \
      Die "the latest NotMyFault was not staged: $(jq -c .notMyFault <<<"${validation}")"
fi

typeset guestChecks=''; guestChecks="$(RunTimed 60 "${guestAgentArr[@]}" exec powershell.exe -NoProfile -Command \
  "\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows')}; \$r|ConvertTo-Json -Compress")" || Die 'guest diagnostic path verification failed'
jq -e '.windows == true and .dumpParent == true' <<<"${guestChecks}" 1> /dev/null || Die 'required guest dump paths are missing'

# Pre-crash inventory: records an existing MEMORY.DMP so post-crash comparison can identify a new one.
typeset inventory=''; inventory="$(RunTimed 60 "${guestAgentArr[@]}" exec powershell.exe -NoProfile -Command \
  "\$p=@('C:\Windows\MEMORY.DMP'); \$r=@(\$p|? {Test-Path \$_}|% {\$i=Get-Item \$_; [ordered]@{path=\$i.FullName;size=\$i.Length;mtime=([DateTimeOffset]\$i.LastWriteTimeUtc).ToUnixTimeSeconds()}}); ConvertTo-Json -InputObject \$r -Compress")" || Die 'cannot inventory pre-existing guest dumps'
# Exactly one JSON document: null (no dump) is recorded as []; otherwise an array of {path, size, mtime} records.
inventory="$(jq -cse 'select(length == 1) | .[0] | if . == null then [] else . end | select(type == "array" and all(.[]; (.path|type)=="string" and (.size|type)=="number" and (.mtime|type)=="number"))' <<<"${inventory}")" || Die 'guest dump inventory is invalid'

phase=metadata
# Schema version 2: defines all fields expected by watch-crash.sh and extract--guest-os--crash-info.sh.
# String fields come from metaArr through $ARGS.named; jq refuses to write a document with a missing top-level field.
metaArr+=([runId]="${cfgArr[runId]}" [outputDir]="${cfgArr[outDir]}" [namespace]="${cfgArr[ns]}" [vm]="${cfgArr[vm]}"
    [memoryDumpPvc]="${cfgArr[memoryPvc]}" [snapshotClass]="${cfgArr[snapClass]}" [recoveryImage]="${cfgArr[recoveryImage]}"
    [mountKind]="${cfgArr[evidenceKind]}" [mountId]="${cfgArr[evidenceId]}")
typeset -a metaArgArr=()
for key in "${!metaArr[@]}"; do metaArgArr+=(--arg "${key}" "${metaArr[${key}]}"); done
typeset armedEpoch=''; armedEpoch="$(date -u +%s)"
typeset temporary="${cfgArr[metadataFile]}.tmp"
jq -ne "${metaArgArr[@]}" --argjson armedEpoch "${armedEpoch}" --argjson inventory "${inventory}" \
  --argjson notMyFault "${notMyFault}" --argjson evidenceMount "${evidenceMount}" \
  '$ARGS.named | {schema:2,runId,outputDir,namespace,vm,launcherPod,domain,node,
    guestPvc,diskName,diskTarget,memoryDumpPvc,snapshotClass,storageClass,storageProvisioner,
    storageSize,volumeMode,recoveryImage,recoveryImageContract:"bash+guestfish-v1",
    armedEpoch,preCrashInventory:.inventory,artifacts:{notMyFault},
    evidenceMount:(.evidenceMount + {kind:.mountKind,id:.mountId})} | select(all(.[]; . != null))' > "${temporary}" || { rm -f "${temporary}"; Die 'metadata document is incomplete'; }
chmod 0600 "${temporary}"; mv -f "${temporary}" "${cfgArr[metadataFile]}"

: "preflight-rhov: OK: ${cfgArr[ns]}/${cfgArr[vm]}; run=${cfgArr[runId]}; disk=${metaArr[diskTarget]}/${metaArr[diskName]}; PVC=${metaArr[guestPvc]}; evidence=${cfgArr[evidenceRoot]} (${cfgArr[evidenceId]})"

true
