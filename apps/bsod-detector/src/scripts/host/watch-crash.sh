#!/usr/bin/env bash
# RHOV crash watcher. It fails closed unless preflight, crash corroboration,
# early disk progress, durable captures, and snapshot recovery all succeed.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset ns=''; typeset vm=''; typeset outArg=''; typeset outDir=''; typeset metadataFile=''; typeset runId=''
typeset interval=5; typeset miss=2; typeset quiesceWait=900; typeset idleSamples=3
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset memoryPvc="${BSOD_MEMORY_DUMP_PVC:-}"; typeset diskTarget=''; typeset noRestart=0
typeset evidenceRoot="${BSOD_EVIDENCE_MOUNT:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_EVIDENCE_STORAGE_ID:-}"; typeset readyFile=''
typeset commandTimeout="${BSOD_COMMAND_TIMEOUT:-30}"; typeset preflightTimeout="${BSOD_PREFLIGHT_TIMEOUT:-300}"
typeset captureTimeout="${BSOD_CAPTURE_TIMEOUT:-300}"; typeset memoryTimeout="${BSOD_MEMORY_CAPTURE_TIMEOUT:-1800}"
typeset recoveryTimeout="${BSOD_RECOVERY_TIMEOUT:-1200}"; typeset armedTimeout="${BSOD_ARMED_TIMEOUT:-3600}"
typeset runDir=''; typeset pvpanicFile=''; typeset pvpanicPid=''; typeset progressPid=''; typeset memoryAssociated=0
typeset stageErrors=''; typeset pipelineLog=''; typeset summaryMode='natural-rhov'
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
[[ -z "${BSOD_GUEST_AGENT_BIN:-}" ]] || guestAgent=("${BSOD_GUEST_AGENT_BIN}")
typeset recoveryBin="${BSOD_RECOVERY_BIN:-${scriptDir}/recover-natural-crash.sh}"
typeset hostSignalsBin="${BSOD_HOST_SIGNALS_BIN:-${scriptDir}/collect-host-signals.sh}"

function Die () { echo "watch-crash: ERROR: $*" >&2; exit 1; }
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${pipelineLog}"; true; }
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
# shellcheck disable=SC2317  # Invoked by EXIT trap.
function Cleanup () {
  if [[ -n "${progressPid}" ]]; then kill "${progressPid}" 2>/dev/null || true; wait "${progressPid}" 2>/dev/null || true; progressPid=''; fi
  if [[ -n "${pvpanicPid}" ]]; then kill -- "-${pvpanicPid}" 2>/dev/null || true; wait "${pvpanicPid}" 2>/dev/null || true; pvpanicPid=''; fi
  if ((memoryAssociated)) && [[ -n "${vm}" && -n "${ns}" ]]; then
    RunTimed 60 virtctl memory-dump remove "${vm}" -n "${ns}" >/dev/null 2>&1 || true
    memoryAssociated=0
  fi
  [[ -z "${runDir}" ]] || rm -rf "${runDir}"
  true
}
# shellcheck disable=SC2317  # Invoked by INT/TERM traps.
function OnSignal () { typeset status="${1:?}"; [[ -z "${stageErrors}" ]] || RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

while (($#)); do
  case "$1" in
    --ns) ns="${2:?}"; shift 2 ;;
    --vm) vm="${2:?}"; shift 2 ;;
    --out) outArg="${2:?}"; shift 2 ;;
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --run-id) runId="${2:?}"; shift 2 ;;
    --ready-file) readyFile="${2:?}"; shift 2 ;;
    --evidence-mount) evidenceRoot="${2:?}"; shift 2 ;;
    --evidence-volume-kind) evidenceKind="${2:?}"; shift 2 ;;
    --evidence-storage-id) evidenceId="${2:?}"; shift 2 ;;
    --interval) interval="${2:?}"; shift 2 ;;
    --miss) miss="${2:?}"; shift 2 ;;
    --quiesce-wait) quiesceWait="${2:?}"; shift 2 ;;
    --idle-samples) idleSamples="${2:?}"; shift 2 ;;
    --snap-class) snapClass="${2:?}"; shift 2 ;;
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;
    --memory-dump-pvc) memoryPvc="${2:?}"; shift 2 ;;
    --disk-target) diskTarget="${2:?}"; shift 2 ;;
    --intentional) summaryMode='intentional-rhov'; shift ;;
    --no-restart) noRestart=1; shift ;;
    -h|--help)
      echo 'usage: watch-crash.sh --ns NS --vm VM --out EVIDENCE_MOUNT_OR_RUN_DIR [--metadata PREFLIGHT.json --run-id ID] --evidence-mount MOUNT --evidence-volume-kind KIND --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [options]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

[[ -n "${ns}" && -n "${vm}" && -n "${outArg}" ]] || Die '--ns, --vm, and --out are required'
command -v setsid >/dev/null 2>&1 || Die "required local tool 'setsid' is not installed"
for value in "${interval}" "${miss}" "${quiesceWait}" "${idleSamples}" "${commandTimeout}" "${armedTimeout}"; do
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || Die 'all timeout/count values must be positive integers'
done

if [[ -n "${metadataFile}" ]]; then
  [[ -r "${metadataFile}" && -n "${runId}" ]] || Die '--metadata requires a readable file and --run-id'
  outDir="$(jq -er .outputDir "${metadataFile}")"
  [[ "$(realpath -m "${outArg}")" == "${outDir}" && "$(jq -r .runId "${metadataFile}")" == "${runId}" ]] || Die 'preflight metadata does not identify this run output'
else
  [[ -n "${evidenceRoot}" ]] || evidenceRoot="${outArg}"
  runId="${runId:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
  outDir="$(realpath -m "${evidenceRoot}")/${runId}"
  mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
  metadataFile="${outDir}/recovery-metadata.json"
  typeset -a preflightArgs=(--ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}"
    --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}"
    --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}")
  [[ -n "${diskTarget}" ]] && preflightArgs+=(--disk-target "${diskTarget}")
  RunTimed "${preflightTimeout}" "${scriptDir}/preflight-rhov.sh" "${preflightArgs[@]}" || Die 'preflight failed or timed out'
fi

typeset pod=''; pod="$(jq -er .launcherPod "${metadataFile}")"
typeset dom=''; dom="$(jq -er .domain "${metadataFile}")"
typeset node=''; node="$(jq -r .node "${metadataFile}")"
diskTarget="$(jq -er .diskTarget "${metadataFile}")"; memoryPvc="$(jq -er .memoryDumpPvc "${metadataFile}")"
[[ "$(jq -r .namespace "${metadataFile}")" == "${ns}" && "$(jq -r .vm "${metadataFile}")" == "${vm}" ]] || Die 'metadata target does not match watcher target'
export GA_NS="${ns}" GA_VM="${vm}" GA_POD="${pod}" GA_DOM="${dom}"
mkdir -p "${outDir}"; chmod 0700 "${outDir}"
stageErrors="${outDir}/stage-errors.jsonl"; : > "${stageErrors}"; chmod 0600 "${stageErrors}"
pipelineLog="${outDir}/watcher.log"; : > "${pipelineLog}"; chmod 0600 "${pipelineLog}"
runDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-watcher.XXXXXX")"; pvpanicFile="${runDir}/pvpanic.current"

function PingOk () { RunTimed 15 "${guestAgent[@]}" ping >/dev/null 2>&1; }
function DomainState () { Oc exec -n "${ns}" "${pod}" -- virsh domstate "${dom}" 2>/dev/null | tr -d '[:space:]'; }
function WriteSummary () {
  RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
    --mode "${summaryMode}" --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename evidence-summary.json
}
function CaptureScreenshot () {
  typeset temporary="${outDir}/.bsod-screenshot.tmp"; typeset result=''; typeset format=''; typeset target=''
  rm -f "${temporary}"
  if ! RunTimed "${captureTimeout}" virtctl vnc screenshot "${vm}" -n "${ns}" --file="${temporary}" >>"${pipelineLog}" 2>&1; then
    RecordError screenshot 'virtctl vnc screenshot failed or timed out'; return 1
  fi
  if ! result="$(RunTimed 30 python3 "${scriptDir}/reliability.py" validate-artifact --type screenshot --path "${temporary}")"; then
    rm -f "${temporary}"; RecordError screenshot 'screenshot is structurally invalid'; return 1
  fi
  format="$(jq -r .format <<<"${result}")"; target="${outDir}/bsod-screenshot.${format}"; mv -f "${temporary}" "${target}"
  Log "validated screenshot: $(basename "${target}")"
}
function CaptureMemory () {
  typeset temporary="${outDir}/.vm-memory.elf.tmp"; typeset target="${outDir}/vm-memory.elf"
  rm -f "${temporary}"
  if ! RunTimed 90 virtctl memory-dump get "${vm}" -n "${ns}" --claim-name="${memoryPvc}" >>"${pipelineLog}" 2>&1; then
    RecordError memory 'KubeVirt memory-dump request failed or timed out'; return 1
  fi
  memoryAssociated=1
  typeset phase=''; typeset deadline=$((SECONDS + memoryTimeout))
  while ((SECONDS < deadline)); do
    phase="$(Oc get vm "${vm}" -n "${ns}" -o jsonpath='{.status.memoryDumpRequest.phase}' 2>>"${pipelineLog}" || true)"
    [[ "${phase}" == Completed ]] && break
    [[ "${phase}" == Failed ]] && { RecordError memory 'KubeVirt memory-dump API reported Failed'; return 1; }
    sleep 3
  done
  [[ "${phase}" == Completed ]] || { RecordError memory "KubeVirt memory-dump phase timed out (last=${phase:-unset})"; return 1; }
  if ! RunTimed "${memoryTimeout}" virtctl memory-dump download "${vm}" -n "${ns}" --output="${temporary}" >>"${pipelineLog}" 2>&1; then
    rm -f "${temporary}"; RecordError memory 'KubeVirt memory-dump download failed or timed out'; return 1
  fi
  if ! RunTimed 60 python3 "${scriptDir}/reliability.py" validate-artifact --type memory --path "${temporary}" >/dev/null; then
    rm -f "${temporary}"; RecordError memory 'downloaded memory dump is not a structurally valid ELF file'; return 1
  fi
  mv -f "${temporary}" "${target}"
  RunTimed 60 virtctl memory-dump remove "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1 || { RecordError memory 'memory-dump association cleanup failed'; return 1; }
  memoryAssociated=0; Log "validated KubeVirt memory dump: $(basename "${target}")"
}
function CaptureHostSignals () {
  typeset ok=0
  if Oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${outDir}/domain.xml" 2>>"${pipelineLog}" && [[ -s "${outDir}/domain.xml" ]]; then ok=$((ok + 1)); else rm -f "${outDir}/domain.xml"; RecordError host-signals 'domain XML capture failed'; fi
  if Oc logs -n "${ns}" "${pod}" -c compute > "${outDir}/launcher-compute.log" 2>>"${pipelineLog}" && [[ -s "${outDir}/launcher-compute.log" ]]; then ok=$((ok + 1)); else rm -f "${outDir}/launcher-compute.log"; RecordError host-signals 'launcher log capture failed'; fi
  ((ok == 2)) || return 1
  typeset -a args=(--vm "${dom}" --log-file "${outDir}/launcher-compute.log" --domain-xml "${outDir}/domain.xml")
  RunTimed 60 "${hostSignalsBin}" "${args[@]}" > "${outDir}/host-signals.json" 2>>"${pipelineLog}" || { RecordError host-signals 'host-signal parser failed'; return 1; }
  Log "captured launcher/domain diagnostics for node ${node:-unknown}"
}
function ProgressSample () {
  typeset stateFile="${runDir}/dump-progress.json"; typeset raw=''; typeset decision=''
  raw="$(Oc exec -n "${ns}" "${pod}" -- virsh domstats --block "${dom}" 2>>"${pipelineLog}")" || return 2
  decision="$(printf '%s\n' "${raw}" | RunTimed 20 python3 "${scriptDir}/reliability.py" progress-step --device "${diskTarget}" --state "${stateFile}" --idle-samples "${idleSamples}")" || return 2
  Log "dump progress: $(jq -r .status <<<"${decision}") ($(jq -r .reason <<<"${decision}"), writes=$(jq -r .writeBytes <<<"${decision}"))"
  [[ "$(jq -r .status <<<"${decision}")" == complete ]]
}
function MonitorDumpProgress () {
  typeset deadline=$((SECONDS + quiesceWait)); typeset stateFile="${runDir}/dump-progress.json"; typeset sampleStatus=0
  while ((SECONDS < deadline)); do
    if ProgressSample; then return 0; else sampleStatus=$?; fi
    if ((sampleStatus == 2)); then RecordError dump-completion 'disk statistics or progress evaluation failed/timed out'; return 1; fi
    sleep "${interval}"
  done
  if [[ "$(jq -r '.observedProgress // false' "${stateFile}" 2>/dev/null || echo false)" == true ]]; then
    RecordError dump-completion 'write progress did not quiesce before the wall-clock deadline'
  else
    RecordError dump-completion 'no write progress was observed before the wall-clock deadline'
  fi
  return 1
}
function StartDumpMonitor () {
  # The first sample is synchronous and precedes every potentially long capture.
  typeset sampleStatus=0
  if ProgressSample; then RecordError dump-completion 'unexpected completed state at baseline'; return 1; else sampleStatus=$?; fi
  ((sampleStatus == 1)) || { RecordError dump-completion 'cannot establish bounded pre-capture disk-write baseline'; return 1; }
  [[ -f "${runDir}/dump-progress.json" ]] || { RecordError dump-completion 'cannot establish pre-capture disk-write baseline'; return 1; }
  MonitorDumpProgress & progressPid=$!
}
function WaitDumpMonitor () {
  typeset status=0; wait "${progressPid}" || status=$?; progressPid=''; return "${status}"
}
function StopAndRecover () {
  Log 'requesting VMI stop through virtctl'
  RunTimed 90 virtctl stop "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1 || { RecordError stop 'virtctl stop failed or timed out; no fallback mutation attempted'; return 1; }
  typeset phase=''; typeset deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    phase="$(Oc get vmi "${vm}" -n "${ns}" --ignore-not-found -o jsonpath='{.status.phase}' 2>>"${pipelineLog}")" || { RecordError stop 'cannot verify VMI stop'; return 1; }
    [[ -z "${phase}" || "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 3
  done
  [[ -z "${phase}" || "${phase}" == Succeeded || "${phase}" == Failed ]] || { RecordError stop "offline deadline exceeded (phase=${phase})"; return 1; }
  RunTimed "${recoveryTimeout}" "${recoveryBin}" --metadata "${metadataFile}" --out "${outDir}" >>"${pipelineLog}" 2>&1 || { RecordError recovery 'snapshot recovery failed or timed out'; return 1; }
  if ((noRestart == 0)); then RunTimed 90 virtctl start "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1 || { RecordError restart 'virtctl start failed or timed out'; return 1; }; fi
}
function CrashResponse () {
  typeset state="${1:?}"; typeset failed=0
  Log "corroborated crash/freeze detected (domstate=${state})"
  StartDumpMonitor || failed=1
  CaptureScreenshot || failed=1
  CaptureMemory || failed=1
  CaptureHostSignals || failed=1
  ((failed == 0)) || { [[ -z "${progressPid}" ]] || { kill "${progressPid}" 2>/dev/null || true; wait "${progressPid}" 2>/dev/null || true; progressPid=''; }; WriteSummary || true; return 1; }
  WaitDumpMonitor || { WriteSummary || true; return 1; }
  StopAndRecover || { WriteSummary || true; return 1; }
  WriteSummary
}

Log "preflight passed; preparing watcher for ${ns}/${vm} (run=${runId}, disk=${diskTarget})"
PingOk || { RecordError preflight 'qemu guest agent became unavailable before arming'; WriteSummary || true; exit 1; }
setsid timeout --signal=TERM --kill-after=5 "${armedTimeout}" oc --request-timeout="${armedTimeout}s" get events -n "${ns}" --watch-only \
  --field-selector "reason=Panicked,involvedObject.name=${vm}" -o name >"${pvpanicFile}" 2>>"${pipelineLog}" &
pvpanicPid=$!
sleep 1; kill -0 "${pvpanicPid}" 2>/dev/null || { RecordError preflight 'event watcher exited before arming'; WriteSummary || true; exit 1; }
if [[ -n "${readyFile}" ]]; then typeset readyTmp="${readyFile}.tmp.$$"; printf '%s\n' "${runId}" > "${readyTmp}"; chmod 0600 "${readyTmp}"; mv -f "${readyTmp}" "${readyFile}"; fi
Log 'qemu guest agent and event watch healthy; watcher armed'

typeset misses=0; typeset state=''; typeset phase=''; typeset decision=''; typeset -a flags=(); typeset watchDeadline=$((SECONDS + armedTimeout))
while ((SECONDS < watchDeadline)); do
  if PingOk; then misses=0; sleep "${interval}"; continue; fi
  misses=$((misses + 1)); state="$(DomainState || printf unavailable)"; Log "missed ping ${misses}/${miss} (domstate=${state})"
  if ((misses >= miss)); then
    phase="$(Oc get vmi "${vm}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || printf unavailable)"
    flags=(--misses "${misses}" --threshold "${miss}" --domstate "${state}" --vmi-phase "${phase}")
    [[ -s "${pvpanicFile}" ]] && flags+=(--pvpanic)
    Oc get pod "${pod}" -n "${ns}" >/dev/null 2>&1 && flags+=(--pod-present)
    decision="$(RunTimed 20 python3 "${scriptDir}/reliability.py" decision "${flags[@]}")" || { RecordError detection 'ambiguous or unavailable crash evidence'; WriteSummary || true; exit 1; }
    if [[ "$(jq -r .decision <<<"${decision}")" == capture ]]; then
      kill -- "-${pvpanicPid}" 2>/dev/null || true; wait "${pvpanicPid}" 2>/dev/null || true; pvpanicPid=''
      CrashResponse "${state}"; exit $?
    fi
  fi
  sleep "${interval}"
done
RecordError detection "armed observation phase exceeded ${armedTimeout}s without a crash"
WriteSummary || true
exit 1
