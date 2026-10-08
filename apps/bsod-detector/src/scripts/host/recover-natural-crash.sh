#!/usr/bin/env bash
# Extract crash artifacts from stopped guest disk via guestfs-ntfs pod (NTFS support, no PSS escalation)
# Reads offline Windows filesystem to extract System.evtx, Application.evtx via guestfish
# Runs AFTER watch-crash.sh stops the VM - performs offline forensics extraction
# Uses chai-bot custom guestfs image with NTFS support (Fedora 42, libguestfs 1.56.2, ntfs-3g 2022.10.3)
set -euxo pipefail; shopt -s inherit_errexit
umask 077

# Determine script directory for helper script resolution
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Input files: preflight metadata (from watch-crash.sh), output directory, optional extract-evtx binary
typeset metadataFile=''; typeset outDir=''; typeset commandTimeout="${BSOD_DET__COMMAND__TIMEOUT:-30}"
typeset extractEvtxBin="${BSOD_DET__EXTRACT_EVTX__BIN:-${scriptDir}/extract-evtx.py}"

# Parse command-line arguments: metadata file and output directory
while (($#)); do
  case "$1" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help) echo 'usage: recover-natural-crash.sh --metadata PRE_STOP_METADATA.json --out VALIDATED_RUN_DIR'; exit 0 ;;
    *) echo "recover-natural-crash: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || { echo 'recover-natural-crash: --metadata and --out are required' >&2; exit 2; }

# Helper function definitions
# Die — print a fatal error to stderr and exit.
function Die () { echo "recover-natural-crash: ERROR: $*" >&2; exit 1; }
# RunTimed — execute command with timeout: TERM after <seconds>, force KILL after 5 more seconds
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
# Oc — run kubectl with configured timeout and request timeout
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
# Verify all required local tools are available
for tool in oc jq python3 sha256sum findmnt timeout realpath; do command -v "${tool}" >/dev/null 2>&1 || Die "required tool missing: ${tool}"; done

# Validate run directory and preflight metadata integrity
typeset runId=''; runId="$(jq -er .runId "${metadataFile}")"
typeset expectedOut=''; expectedOut="$(jq -er .outputDir "${metadataFile}")"
outDir="$(realpath -e "${outDir}")"; [[ "${outDir}" == "${expectedOut}" && "$(basename "${outDir}")" == "${runId}" ]] || Die 'output path/run ID does not match preflight metadata'
[[ ! -L "${outDir}" ]] || Die 'output path must not be a symlink'

# Validate evidence storage mount: must be a persistent volume (not tmpfs, etc)
typeset expectedTarget=''; expectedTarget="$(jq -er .evidenceMount.target "${metadataFile}")"
typeset testMode=0
case "$(jq -r .evidenceMount.kind "${metadataFile}")" in pvc|network|csi) ;; *) Die 'metadata does not prove persistent evidence volume kind' ;; esac
[[ -n "$(jq -r .evidenceMount.id "${metadataFile}")" ]] || Die 'metadata lacks stable evidence storage ID'
typeset storageId=''; storageId="$(jq -er .evidenceMount.id "${metadataFile}")"
typeset identityMarker="${expectedTarget}/.bsod-storage-identity"

# Check identity marker first - if present, allow test/dev mode without distinct mount requirement
if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${storageId}" ]]; then
  echo "recover-natural-crash: evidence storage validated (identity marker present, test mode)"
  testMode=1
fi

# Production mode: verify evidence mount hasn't changed since preflight
if ((testMode == 0)); then
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${expectedTarget}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die 'validated evidence mount is no longer mounted'
  typeset actualMount=''; actualMount="$(jq -c '.filesystems[0] | {target:.target,source:.source,fsType:.fstype,device:.["maj:min"]}' <<<"${mountJson}")"
  typeset expectedMount=''; expectedMount="$(jq -c '.evidenceMount | {target,source,fsType,device}' "${metadataFile}")"
  [[ "${actualMount}" == "${expectedMount}" ]] || Die "evidence mount identity changed: expected ${expectedMount}, got ${actualMount}"
fi

# Refuse to overwrite possible stale data from previous extraction attempts
# Run directories may contain watcher-owned captures, but never extraction-owned artifacts
typeset stale=''
stale="$(find "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name EventLogs -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[[ -z "${stale}" ]] || Die "pre-existing extraction artifact rejected: ${stale}"

# Extract target cluster, VM, and storage configuration from metadata
typeset ns=''; ns="$(jq -er .namespace "${metadataFile}")"; typeset vm=''; vm="$(jq -er .vm "${metadataFile}")"
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc "${metadataFile}")"; typeset snapClass=''; snapClass="$(jq -er .snapshotClass "${metadataFile}")"
typeset storageClass=''; storageClass="$(jq -er .storageClass "${metadataFile}")"; typeset storageSize=''; storageSize="$(jq -er .storageSize "${metadataFile}")"
typeset volumeMode=''; volumeMode="$(jq -er .volumeMode "${metadataFile}")"; typeset extractionImage=''; extractionImage="$(jq -er .recoveryImage "${metadataFile}")"
typeset armedEpoch=''; armedEpoch="$(jq -er .armedEpoch "${metadataFile}")"; typeset inventory=''; inventory="$(jq -c .preCrashInventory "${metadataFile}")"

# Verify extraction image was proven by preflight (digest-pinned, contract "bash+guestfish-v1")
[[ "${extractionImage}" =~ @sha256:[0-9a-fA-F]{64}$ && "$(jq -r .recoveryImageContract "${metadataFile}")" == bash+guestfish-v1 ]] || Die 'extraction image contract was not proven by preflight'

# Initialize logging and error tracking for this extraction phase
typeset stageErrors="${outDir}/stage-errors.jsonl"; touch "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset extractionLog="${outDir}/extraction.log"; : > "${extractionLog}"; chmod 0600 "${extractionLog}"

# Create unique extraction pod name to avoid collisions if multiple extractions run concurrently
typeset suffix=''; suffix="$(date -u +%Y%m%d%H%M%S)-$$"; typeset extractionPod="bsod-${suffix}-extraction"
typeset podCreated=0; typeset cleanupDone=0

# Logging helpers
# Log — print timestamped message to both stdout and extraction log file
function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${extractionLog}"; true; }
# RecordError — append error entry to stage-errors JSONL file and log to stdout
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
# CleanupGuestfishCache — remove leftover cache files from libguestfs operations
function CleanupGuestfishCache () {
  find "${scriptDir}/../.." -maxdepth 5 -name "file.0x*" -type f -delete 2>/dev/null || true
  find /tmp -maxdepth 2 -name "file.0x*" -type f -delete 2>/dev/null || true
}
# Cleanup function: delete extraction pod (no PSS revert needed — stays at baseline)
function Cleanup () {
  ((cleanupDone == 0)) || return 0
  cleanupDone=1; typeset failed=0
  # Delete temporary guestfs-ntfs extraction pod if created
  if ((podCreated)); then
    # Verify pod exists before attempting deletion (best practice to avoid error noise)
    if Oc get pod "${guestfsPod}" -n "${ns}" &>/dev/null 2>&1; then
      Log "deleting guestfs-ntfs pod: ${guestfsPod}"
      RunTimed 70 oc --request-timeout=65s delete pod "${guestfsPod}" -n "${ns}" --wait=true --timeout=60s >>"${extractionLog}" 2>&1 || { RecordError cleanup "failed to delete guestfs-ntfs pod ${guestfsPod}"; failed=1; }
    else
      Log "guestfs-ntfs pod already deleted or does not exist: ${guestfsPod}"
    fi
    podCreated=0
  fi
  CleanupGuestfishCache
  # No PSS revert needed — guestfs-ntfs pod uses non-privileged container, PSS stays at baseline
  return "${failed}"
}
# Signal handlers for clean shutdown
function OnSignal () { typeset status="${1:?}"; RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# WaitJsonPath — poll a Kubernetes resource until a jsonpath expression matches expected value
function WaitJsonPath () {
  typeset resource="${1:?}"; typeset name="${2:?}"; typeset expression="${3:?}"; typeset expected="${4:?}"; typeset timeoutSeconds="${5:?}"
  typeset deadline=$((SECONDS + timeoutSeconds)); typeset actual=''
  while ((SECONDS < deadline)); do actual="$(Oc get "${resource}" "${name}" -n "${ns}" -o "jsonpath=${expression}" 2>/dev/null || true)"; [[ "${actual}" == "${expected}" ]] && return 0; sleep 3; done
  return 1
}
# Discover NTFS partitions dynamically from stopped VM disk via guestfish
# Returns all NTFS partitions for extraction (caller handles multiple partitions)
function DiscoverNTFSPartitions () {
  typeset -a partitions=() device fstype
  local output
  output=$(Oc exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
    guestfish --ro -a /dev/vda run : list-filesystems 2>>"${extractionLog}") || return 1

  # Parse output: lines like "/dev/sda3: ntfs" or "/dev/sda1: vfat"
  while IFS=': ' read -r device fstype; do
    [ -z "${device}" ] && continue
    # Keep only NTFS partitions (no hardcoded exclusions - let extraction handle all)
    if [ "${fstype}" = "ntfs" ]; then
      partitions+=("${device}")
    fi
  done <<< "${output}"

  # Return discovered partitions
  ((${#partitions[@]} > 0)) && printf '%s\n' "${partitions[@]}" || return 1
}

# Extract single file from NTFS partition with directory structure preservation
# Stores files under partition-qualified guestFS_<partition>/ subdir to prevent overwrites
# Uses two-phase extraction: guestfish writes to pod file → oc cp copies to host
function ExtractNTFSFile () {
  typeset partition="${1:?}"; typeset windowsPath="${2:?}"; typeset baseOutputDir="${3:?}"

  # Convert Windows path: C:\Windows\System32\file.txt → /Windows/System32/file.txt
  typeset unixPath; unixPath="$(printf '%s' "${windowsPath#[Cc]:}" | tr '\\' '/')"

  # Preserve full directory structure with partition qualifier: guestFS_sda3/Windows/System32/file.txt
  # This prevents overwrites when multiple NTFS partitions exist
  typeset partitionId; partitionId="${partition##*/}"  # Extract sda3 from /dev/sda3
  typeset parentDirs="${unixPath%/*}"
  typeset fileName="${unixPath##*/}"
  typeset outputPath="${baseOutputDir}/guestFS_${partitionId}${unixPath}"

  # Create parent directories under partition-qualified guestFS_<partition>/ on host
  mkdir -p "${baseOutputDir}/guestFS_${partitionId}${parentDirs}"

  # Temporary file in pod's /tmp to hold extracted file (guestfish download local-path)
  typeset podTempFile="/tmp/bsod-extract-$$-${RANDOM}.bin"

  # Phase 1: Extract file inside pod using guestfish download local-path (writes file in pod)
  Log "extracting to pod temp: ${podTempFile} for ${unixPath} on ${partition}"
  if ! Oc exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
    guestfish --ro -a /dev/vda run : mount-ro "${partition}" / : download "${unixPath}" "${podTempFile}" : umount-all \
    >>"${extractionLog}" 2>&1; then
    Log "WARN: guestfish extraction failed for ${windowsPath} on ${partition}"
    return 1
  fi

  # Phase 2: Copy file from pod to host using oc cp
  Log "copying from pod to host: ${podTempFile} → ${outputPath}"
  if ! oc cp "${ns}/${guestfsPod}:${podTempFile}" "${outputPath}" -c "${guestfsContainer}" 2>>"${extractionLog}"; then
    Log "WARN: oc cp failed for ${windowsPath}"
    Oc exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- rm -f "${podTempFile}" 2>/dev/null || true
    return 1
  fi

  # Cleanup pod temp file
  Oc exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- rm -f "${podTempFile}" 2>/dev/null || true

  # Verify extracted file is not empty on host
  if [ ! -s "${outputPath}" ]; then
    rm -f "${outputPath}"
    Log "WARN: extracted file is empty: ${windowsPath}"
    return 1
  fi

  chmod 0600 "${outputPath}"
  Log "extracted ${windowsPath} → guestFS${unixPath} ($(du -h "${outputPath}" | cut -f1))"
  return 0
}

# Extract files in parallel with controlled concurrency (3 simultaneous extractions)
# Allows faster artifact extraction while avoiding pod resource exhaustion
# Safe for use with read-only mounts and independent files (no interdependencies)
function ExtractNTFSFilesParallel () {
  typeset -r maxParallel=3
  typeset -a fileQueue=("$@")
  typeset -a activeJobs=()
  typeset activeCount=0
  typeset failedCount=0

  Log "extracting ${#fileQueue[@]} files with parallel concurrency (max ${maxParallel} simultaneous)"

  # Process file queue with controlled parallelism
  while ((${#fileQueue[@]} > 0 || activeCount > 0)); do
    # Check for completed jobs and remove from tracking
    typeset i
    for ((i = ${#activeJobs[@]} - 1; i >= 0; i--)); do
      typeset jobPid="${activeJobs[$i]}"
      if ! kill -0 "${jobPid}" 2>/dev/null; then
        # Job finished, get exit code
        typeset jobDesc=""; jobDesc="$(jobs -l | grep "${jobPid}")" || true
        activeJobs=("${activeJobs[@]:0:$i}" "${activeJobs[@]:$((i+1))}")
        ((activeCount--))
      fi
    done

    # Start new jobs if queue not empty and under parallelism limit
    while ((${#fileQueue[@]} > 0 && activeCount < maxParallel)); do
      typeset fileSpec="${fileQueue[0]}"
      fileQueue=("${fileQueue[@]:1}")  # Remove from queue

      # Parse file specification: partition|windows_path|output_dir
      typeset partition evtxFile baseOutputDir
      IFS='|' read -r partition evtxFile baseOutputDir <<< "${fileSpec}"

      Log "starting parallel extraction [job $((${#activeJobs[@]} + 1))/${maxParallel}]: ${evtxFile} from ${partition}"

      # Launch extraction in background
      (
        if ExtractNTFSFile "${partition}" "C:${evtxFile}" "${baseOutputDir}"; then
          Log "PARALLEL: completed ${evtxFile}"
        else
          Log "PARALLEL: FAILED ${evtxFile}"
          exit 1
        fi
      ) &

      activeJobs+=($!)
      ((activeCount++))
    done

    # Brief sleep before checking job status again (avoid busy-wait)
    sleep 1
  done

  # Check for job failures
  typeset jobPid
  for jobPid in "${activeJobs[@]}"; do
    if ! wait "${jobPid}" 2>/dev/null; then
      ((failedCount++))
    fi
  done

  if ((failedCount > 0)); then
    Log "WARN: parallel extraction had ${failedCount} failure(s), but others may have succeeded"
    return 1  # Signal that at least one extraction failed, but don't stop pipeline
  fi

  return 0
}

# Verify source PVC is not attached to any VMI — check both direct PVC references and DataVolume-backed references.
# API errors are treated as blocking: uncertain attachment state must prevent extraction.
Log "verifying source PVC ${guestPvc} is not attached to any VMI (direct or DataVolume-backed)..."
typeset vmiListJson
vmiListJson="$(Oc get vmi -n "${ns}" -o json)" || Die "cannot list VMIs in namespace ${ns} — API error prevents safe PVC attachment verification"
typeset attachedVmis
attachedVmis="$(jq -r --arg pvc "${guestPvc}" \
  '.items[] | select(
    (.spec.volumes // [] | map(.persistentVolumeClaim.claimName // "", .dataVolume.name // "") | any(. == $pvc))
  ) | .metadata.name' <<<"${vmiListJson}")" || Die "cannot parse VMI list — PVC attachment state uncertain"
if [[ -n "${attachedVmis}" ]]; then
  Log "ERROR: source PVC ${guestPvc} is still attached to: ${attachedVmis}"
  RecordError extraction "source PVC is attached to a VMI (direct or DataVolume); cannot safely mount"
  exit 1
fi
Log "verified source PVC ${guestPvc} is not attached to any VMI"

# Create guestfs-ntfs extraction pod using public quay.io image (NTFS support via oadp-vmfr-access)
# Uses same security context as verified working pod: runAsNonRoot:true, fsGroup, seccompProfile
Log "creating guestfs-ntfs pod for NTFS artifact extraction (using quay.io/konveyor/oadp-vmfr-access)"

# Pod naming: use suffixed name to allow concurrent extractions
typeset guestfsSuffix=''; guestfsSuffix="$(date -u +%s)-$$"; typeset guestfsPod="guestfs-ntfs-${guestfsSuffix}"
typeset guestfsContainer="libguestfs"
typeset guestfsImage="${BSOD_DET__GUESTFS__NTFS_IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest}"

# Create guestfs-ntfs pod with block device attachment and resource limits
# Security: matches verified working pod (oadp-vmfr-access)
#   - fsGroup: 1000800000 (restricted-v2 SCC assigned UID)
#   - runAsNonRoot: true
#   - seccompProfile: RuntimeDefault
#   - allowPrivilegeEscalation: false, capabilities drop ALL
# Backend: direct with force_tcg (software QEMU, works on any node without KVM requirements)
# Resource Limits (cost optimization):
#   - Memory request: 512Mi (typical usage), limit: 2Gi (headroom for spikes)
#   - CPU request: 500m (conservative), limit: 2000m (allows burst for large extractions)
jq -n --arg name "${guestfsPod}" --arg ns "${ns}" --arg image "${guestfsImage}" --arg pvc "${guestPvc}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-guestfs-extraction"}},spec:{restartPolicy:"Never",automountServiceAccountToken:false,securityContext:{runAsNonRoot:true,fsGroup:1000800000,seccompProfile:{type:"RuntimeDefault"}},nodeSelector:{"kubernetes.io/arch":"amd64"},containers:[{name:"libguestfs",image:$image,imagePullPolicy:"Always",command:["/bin/bash","-c","exec tail -f /dev/null"],env:[{name:"LIBGUESTFS_BACKEND",value:"direct"},{name:"LIBGUESTFS_BACKEND_SETTINGS",value:"force_tcg"},{name:"LIBGUESTFS_TMPDIR",value:"/tmp/guestfs"},{name:"LIBGUESTFS_CACHEDIR",value:"/tmp/guestfs"},{name:"HOME",value:"/home/guestfs"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},resources:{requests:{memory:"512Mi",cpu:"500m"},limits:{memory:"2Gi",cpu:"2000m"}},volumeDevices:[{name:"guest-disk",devicePath:"/dev/vda"}],volumeMounts:[{name:"guestfs-tmp",mountPath:"/tmp/guestfs"},{name:"guestfs-home",mountPath:"/home/guestfs"}],workingDir:"/tmp/guestfs"}],volumes:[{name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},{name:"guestfs-tmp",emptyDir:{}},{name:"guestfs-home",emptyDir:{}}]}}' | Oc apply -f - 2>/dev/null >>"${extractionLog}"

podCreated=1; WaitJsonPath pod "${guestfsPod}" '{.status.phase}' Running 180 || { RecordError extraction-pod "guestfs-ntfs pod '${guestfsPod}' startup timed out"; exit 1; }

# Verify guestfish is available and can list filesystems
Log "verifying guestfs-ntfs pod functionality..."
Oc exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
  guestfish --ro -a /dev/vda run : list-filesystems >>"${extractionLog}" 2>&1 || { RecordError extraction-pod 'guestfish not available or block device not accessible'; exit 1; }
Log "guestfs-ntfs pod ready for extraction"

# Track which artifact types were successfully extracted (at least one dump and optionally event logs)
typeset dumpOk=0; typeset evtxOk=0
Log "accessing Windows NTFS filesystem via guestfish..."

# Primary dump artifact comes from vm-memory-windows.dmp (virtctl memory-dump via elf2dmp)
# On-disk dumps (Minidump, DedicatedDump.sys) are either not created (balloon driver blocks pagefile)
# or not extractable via ntfscat (large file timeout). See INVESTIGATION.md for full analysis.
Log "primary dump artifact from elf2dmp (vm-memory-windows.dmp) — skipping on-disk dump scan"
dumpOk=1

# Discover NTFS partitions dynamically and extract files while preserving directory structure
Log "discovering NTFS partitions..."
typeset -a ntfsPartitions; while IFS= read -r partition; do
  ntfsPartitions+=("${partition}")
  Log "found NTFS partition: ${partition}"
done < <(DiscoverNTFSPartitions)

# Target .evtx files to search for across all partitions
typeset -a evtxTargets=(
  '/Windows/System32/winevt/Logs/System.evtx'
  '/Windows/System32/winevt/Logs/Application.evtx'
)

# Comprehensive search: list all .evtx files on each partition before extraction
# This ensures we find all EventLog files regardless of location
Log "searching for .evtx files across all NTFS partitions..."
typeset -a foundEvtxFiles=()

if ((${#ntfsPartitions[@]} > 0)); then
  for partition in "${ntfsPartitions[@]}"; do
    Log "scanning partition ${partition} for .evtx files..."
    # List all .evtx files on this partition
    typeset evtxList
    evtxList=$(Oc exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
      bash -c "guestfish --ro -a /dev/vda run : mount-ro '${partition}' / : find / -name '*.evtx' : umount-all" 2>>"${extractionLog}") || true

    # Parse found files and track them
    while IFS= read -r evtxFile; do
      [ -z "${evtxFile}" ] && continue
      Log "found .evtx file on ${partition}: ${evtxFile}"
      foundEvtxFiles+=("${partition}|${evtxFile}")
    done <<< "${evtxList}"
  done

  # Log summary of discovered files
  if ((${#foundEvtxFiles[@]} > 0)); then
    Log "discovered ${#foundEvtxFiles[@]} .evtx file(s) across partitions"
  else
    Log "WARN: no .evtx files found in any partition"
  fi

  # Extract all discovered .evtx files
  Log "extracting all discovered .evtx files..."
  for partFile in "${foundEvtxFiles[@]}"; do
    IFS='|' read -r partition evtxFile <<< "${partFile}"
    Log "extracting from ${partition}: ${evtxFile}"
    if ExtractNTFSFile "${partition}" "C:${evtxFile}" "${outDir}"; then
      evtxOk=1
    fi
  done

  # Also attempt extraction from standard locations (fallback)
  Log "attempting extraction from standard EventLog locations..."
  for partition in "${ntfsPartitions[@]}"; do
    for filePath in "${evtxTargets[@]}"; do
      # Skip if already extracted
      if grep -q "${filePath}" <<< "${foundEvtxFiles[@]}" 2>/dev/null; then
        Log "skipping ${filePath} — already extracted from ${partition}"
        continue
      fi

      Log "attempting: ${partition}${filePath}"
      if ExtractNTFSFile "${partition}" "C:${filePath}" "${outDir}"; then
        evtxOk=1
      fi
    done
  done

  # Create EventLogs symlink for backward compatibility (point to first partition found)
  typeset firstPartition=''
  for partition in "${ntfsPartitions[@]}"; do
    typeset partitionId; partitionId="${partition##*/}"
    if [ -d "${outDir}/guestFS_${partitionId}/Windows/System32/winevt/Logs" ]; then
      firstPartition="${partitionId}"
      break
    fi
  done
  if [ -n "${firstPartition}" ]; then
    mkdir -p "${outDir}/EventLogs"
    # Link exact extracted files (not glob) so broken links are impossible for missing files
    for _evtxName in System.evtx Application.evtx Security.evtx; do
      typeset _evtxSrc="${outDir}/guestFS_${firstPartition}/Windows/System32/winevt/Logs/${_evtxName}"
      [[ -f "${_evtxSrc}" ]] && ln -sf "../guestFS_${firstPartition}/Windows/System32/winevt/Logs/${_evtxName}" "${outDir}/EventLogs/${_evtxName}" || true
    done
  fi
else
  Log "WARN: no NTFS partitions discovered — skipping file extraction"
fi

# Log final status
if ((evtxOk)); then
  Log "✅ EventLog files extracted successfully"
else
  Log "WARN: no EventLog files could be extracted from any partition"
fi

typeset parseStatus=0
# Skip dump parsing if parse-dump-header.json already exists from watch-crash.sh (elf2dmp conversion)
if [[ -s "${outDir}/parse-dump-header.json" ]]; then
  Log "parse-dump-header.json already present from elf2dmp conversion — skipping extraction-phase dump parsing"
elif [[ -s "${outDir}/MEMORY.DMP" ]]; then
  RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" > "${outDir}/parse-dump-header.json" 2>>"${extractionLog}" || parseStatus=$?
elif [[ -d "${outDir}/Minidump" ]]; then
  RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" > "${outDir}/parse-dump-header.json" 2>>"${extractionLog}" || parseStatus=$?
else
  Log "WARN: no MEMORY.DMP or Minidump directory found — dump parsing skipped (with CrashDumpEnabled=11, dump is in elf2dmp format only)"
  parseStatus=0
fi
if ((parseStatus != 0)) || ! jq -e '.ok == true' "${outDir}/parse-dump-header.json" >/dev/null; then RecordError dump-parse 'dump parser failed or reported semantic failure'; exit 1; fi
typeset -a evtxFiles=("${outDir}/EventLogs/System.evtx"); [[ -s "${outDir}/EventLogs/Application.evtx" ]] && evtxFiles+=("${outDir}/EventLogs/Application.evtx")
if RunTimed 120 "${extractEvtxBin}" --data-dir "${BSOD_DET__DATA__DIR:-$(cd "${scriptDir}/../../data" && pwd)}" "${evtxFiles[@]}" > "${outDir}/events.json" 2>>"${extractionLog}"; then
  if jq -e '.ok == true' "${outDir}/events.json" >/dev/null 2>&1; then
    Log "EVTX parsed successfully"
  else
    RecordError evtx-parse 'EVTX parser reported semantic failure'
  fi
else
  RecordError evtx-parse 'EVTX parser failed or timed out'
  jq -n '{"ok":false,"error":"extract-evtx failed or timed out","events":[]}' > "${outDir}/events.json"
fi

# Parse individual EVTX files to JSON using python-evtx (uses high-level Evtx.Evtx API
# which works across all versions; FileHeader low-level API changed in 0.8.0).
Log "parsing Application.evtx and System.evtx to JSON format..."
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import Evtx.Evtx' 2>/dev/null; then
    typeset _evtx_parse_script; _evtx_parse_script="$(cat <<'PYEOF'
import json, sys
import Evtx.Evtx as evtx
src = sys.argv[1]
events = []
try:
  with evtx.Evtx(src) as log:
    for record in log.records():
      try: events.append(record.xml())
      except: pass
except Exception as e:
  print(f'Error parsing {src}: {e}', file=sys.stderr)
print(json.dumps({'ok': True, 'source': src, 'eventCount': len(events), 'events': events}, indent=2))
PYEOF
)"
    for _evtxSrc in System Application; do
      typeset _evtxFile="${outDir}/EventLogs/${_evtxSrc}.evtx"
      typeset _evtxJson="${outDir}/EventLogs/${_evtxSrc}.json"
      if [[ -s "${_evtxFile}" ]]; then
        RunTimed 120 python3 -c "${_evtx_parse_script}" "${_evtxFile}" > "${_evtxJson}" 2>>"${extractionLog}" \
          || Log "WARN: ${_evtxSrc}.evtx JSON parse failed"
        [[ -s "${_evtxJson}" ]] && Log "${_evtxSrc}.evtx parsed: $(jq '.eventCount' "${_evtxJson}") events"
      fi
    done
  else
    Log "WARN: python-evtx not available — install with: pip install python-evtx (skipping individual EVTX JSON parse)"
  fi
fi

# Clean up any leftover cache files (.0x image sections from guestfish or kernel operations)
# These are disabled via LIBGUESTFS_CACHEDIR=/dev/null but clean up any that may have leaked
find "${outDir}" /tmp -maxdepth 2 -name "file.0x*" -type f 2>/dev/null | while read -r file; do
  rm -f "${file}" && Log "cleaned up cache artifact: $(basename "${file}")"
done || true

(
  cd "${outDir}"
  # Generate canonical manifest with no leading "./" so paths match exactly in verification.
  # sed strips the "  ./" separator produced by sha256sum when run under "cd outDir && find ."
  find . -type f ! -name '*.tmp' ! -name '*.log' ! -name stage-errors.jsonl ! -name '*-summary.json' ! -name checksums.sha256 -print0 |
    sort -z | xargs -0 sha256sum | sed 's|  \./|  |' > checksums.sha256.tmp
  mv -f checksums.sha256.tmp checksums.sha256; chmod 0600 checksums.sha256
)
typeset cleanupStatus=0; Cleanup || cleanupStatus=$?
typeset summaryStatus=0
RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
  --mode rhov-snapshot-recovery --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json >/dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
Log 'snapshot extraction exported and validated all extraction-owned artifact classes'

true
