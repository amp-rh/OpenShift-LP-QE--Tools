#!/usr/bin/env bash
# RHOV-only natural crash watcher.  The watcher fails closed: it will not stop a
# VMI unless preflight passes, a crash is corroborated, and disk write progress
# followed by quiescence is observed on the selected Windows system disk.
set -euo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset ns=''; typeset vm=''; typeset outDir=''
typeset interval=5; typeset miss=2; typeset quiesceWait=900; typeset idleSamples=3
typeset snapClass="${BSOD_SNAPSHOT_CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset diskTarget=''; typeset noRestart=0

while (($#)); do
  case "$1" in
    --ns) ns="${2:?}"; shift 2 ;;
    --vm) vm="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    --interval) interval="${2:?}"; shift 2 ;;
    --miss) miss="${2:?}"; shift 2 ;;
    --quiesce-wait) quiesceWait="${2:?}"; shift 2 ;;
    --idle-samples) idleSamples="${2:?}"; shift 2 ;;
    --snap-class) snapClass="${2:?}"; shift 2 ;;
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;
    --disk-target) diskTarget="${2:?}"; shift 2 ;;
    --no-restart) noRestart=1; shift ;;
    -h|--help)
      echo 'usage: watch-crash.sh --ns NS --vm VM --out DURABLE_DIR --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST [--disk-target vda] [--interval SEC] [--miss COUNT] [--quiesce-wait SEC] [--idle-samples COUNT] [--no-restart]'
      exit 0 ;;
    *) echo "watch-crash: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${ns}" && -n "${vm}" && -n "${outDir}" ]] || { echo 'watch-crash: --ns, --vm, and --out are required' >&2; exit 2; }
[[ "${interval}" =~ ^[1-9][0-9]*$ && "${miss}" =~ ^[1-9][0-9]*$ && "${quiesceWait}" =~ ^[1-9][0-9]*$ && "${idleSamples}" =~ ^[1-9][0-9]*$ ]] || { echo 'watch-crash: numeric thresholds must be positive integers' >&2; exit 2; }

mkdir -p "${outDir}"; chmod 0700 "${outDir}"
typeset stageErrors="${outDir}/stage-errors.jsonl"; : > "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset pipelineLog="${outDir}/watcher.log"; : > "${pipelineLog}"; chmod 0600 "${pipelineLog}"
typeset metadataFile="${outDir}/recovery-metadata.json"
typeset runDir=''; runDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-watcher.XXXXXX")"
typeset pvpanicFile="${runDir}/pvpanic.current"
typeset pvpanicPid=''

function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${pipelineLog}"; true; }
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
  true
}
function Cleanup () {
  if [[ -n "${pvpanicPid}" ]]; then kill "${pvpanicPid}" 2>/dev/null || true; fi
  rm -rf "${runDir}"
  true
}
trap Cleanup EXIT INT TERM

typeset -a preflightArgs=(--ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --snap-class "${snapClass}" --recovery-image "${recoveryImage}")
[[ -n "${diskTarget}" ]] && preflightArgs+=(--disk-target "${diskTarget}")
"${scriptDir}/preflight-rhov.sh" "${preflightArgs[@]}" | tee -a "${pipelineLog}"

typeset pod=''; pod="$(jq -r .launcherPod "${metadataFile}")"
typeset dom=''; dom="$(jq -r .domain "${metadataFile}")"
typeset node=''; node="$(jq -r .node "${metadataFile}")"
diskTarget="$(jq -r .diskTarget "${metadataFile}")"
export GA_NS="${ns}" GA_VM="${vm}" GA_POD="${pod}" GA_DOM="${dom}"

function PingOk () { timeout 10 python3 "${scriptDir}/guest-agent.py" ping >/dev/null 2>&1; }
function DomainState () {
  oc exec -n "${ns}" "${pod}" -- virsh domstate "${dom}" 2>/dev/null | tr -d '[:space:]'
}
function WriteSummary () {
  python3 "${scriptDir}/reliability.py" write-summary \
    --out "${outDir}" --stage-errors "${stageErrors}" --mode natural-rhov \
    --vm "${vm}" --namespace "${ns}" --filename evidence-summary.json
}

function CaptureScreenshot () {
  typeset temporary="${outDir}/.bsod-screenshot.tmp"
  typeset result=''; typeset format=''; typeset target=''
  rm -f "${temporary}"
  if virtctl screenshot "${vm}" -n "${ns}" > "${temporary}" 2>>"${pipelineLog}" && \
      result="$(python3 "${scriptDir}/reliability.py" validate-artifact --type screenshot --path "${temporary}" 2>/dev/null)"; then
    true
  else
    Log 'virtctl screenshot failed or returned an invalid image; trying pod-local virsh stdout fallback'
    rm -f "${temporary}"
    if ! oc exec -n "${ns}" "${pod}" -- virsh screenshot "${dom}" /dev/stdout > "${temporary}" 2>>"${pipelineLog}"; then
      rm -f "${temporary}"; RecordError screenshot 'virtctl and pod-local virsh screenshot commands failed'; return 1
    fi
    if ! result="$(python3 "${scriptDir}/reliability.py" validate-artifact --type screenshot --path "${temporary}")"; then
      rm -f "${temporary}"; RecordError screenshot 'captured image is empty or has an unsupported signature'; return 1
    fi
  fi
  format="$(jq -r .format <<<"${result}")"
  target="${outDir}/bsod-screenshot.${format}"
  mv -f "${temporary}" "${target}"
  Log "validated screenshot: $(basename "${target}") sha256=$(sha256sum "${target}" | awk '{print $1}')"
}

function CaptureMemory () {
  typeset temporary="${outDir}/.vm-memory.elf.tmp"
  typeset target="${outDir}/vm-memory.elf"
  rm -f "${temporary}"
  if ! oc exec -n "${ns}" "${pod}" -- virsh dump --memory-only --format elf "${dom}" /dev/stdout > "${temporary}" 2>>"${pipelineLog}"; then
    rm -f "${temporary}"; RecordError memory 'pod-local virsh memory stream failed'; return 1
  fi
  if ! python3 "${scriptDir}/reliability.py" validate-artifact --type memory --path "${temporary}" >/dev/null; then
    rm -f "${temporary}"; RecordError memory 'memory stream is empty or is not ELF'; return 1
  fi
  mv -f "${temporary}" "${target}"
  Log "validated raw memory: $(basename "${target}") sha256=$(sha256sum "${target}" | awk '{print $1}')"
}

function CaptureHostSignals () {
  typeset ok=0
  if oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${outDir}/domain.xml" 2>>"${pipelineLog}" && [[ -s "${outDir}/domain.xml" ]]; then
    ok=$((ok + 1))
  else
    rm -f "${outDir}/domain.xml"; RecordError host-signals 'domain XML capture failed'
  fi
  if oc logs -n "${ns}" "${pod}" -c compute > "${outDir}/launcher-compute.log" 2>>"${pipelineLog}" && [[ -s "${outDir}/launcher-compute.log" ]]; then
    ok=$((ok + 1))
  else
    rm -f "${outDir}/launcher-compute.log"; RecordError host-signals 'virt-launcher compute log capture failed'
  fi
  ((ok == 2)) || return 1
  typeset -a args=(--vm "${dom}")
  [[ -s "${outDir}/launcher-compute.log" ]] && args+=(--log-file "${outDir}/launcher-compute.log")
  [[ -s "${outDir}/domain.xml" ]] && args+=(--domain-xml "${outDir}/domain.xml")
  if ! bash "${scriptDir}/collect-host-signals.sh" "${args[@]}" > "${outDir}/host-signals.json" 2>>"${pipelineLog}"; then
    rm -f "${outDir}/host-signals.json"; RecordError host-signals 'host-signal parser failed'; return 1
  fi
  Log "captured launcher/domain diagnostics for node ${node:-unknown}"
}

function WaitDumpComplete () {
  typeset stateFile="${runDir}/dump-progress.json"
  typeset elapsed=0; typeset raw=''; typeset decision=''; typeset status=''
  Log "monitoring ${diskTarget} for write progress then ${idleSamples} idle samples (timeout ${quiesceWait}s)"
  while ((elapsed < quiesceWait)); do
    if ! raw="$(oc exec -n "${ns}" "${pod}" -- virsh domstats --block "${dom}" 2>>"${pipelineLog}")"; then
      RecordError dump-completion 'pod-local domstats command failed'; return 1
    fi
    if ! decision="$(printf '%s\n' "${raw}" | python3 "${scriptDir}/reliability.py" progress-step --device "${diskTarget}" --state "${stateFile}" --idle-samples "${idleSamples}")"; then
      RecordError dump-completion "$(jq -r '.reason + (if .detail then ": " + .detail else "" end)' <<<"${decision}" 2>/dev/null || echo 'progress evaluator failed')"; return 1
    fi
    status="$(jq -r .status <<<"${decision}")"
    Log "dump progress: ${status} ($(jq -r .reason <<<"${decision}"), writes=$(jq -r .writeBytes <<<"${decision}"))"
    [[ "${status}" == 'complete' ]] && return 0
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  if [[ -f "${stateFile}" ]] && [[ "$(jq -r .observedProgress "${stateFile}")" == 'true' ]]; then
    RecordError dump-completion "write progress never reached ${idleSamples} quiescent samples before timeout"
  else
    RecordError dump-completion 'no write progress was observed before timeout'
  fi
  return 1
}

function StopAndRecover () {
  Log 'requesting VMI stop through virtctl'
  if ! virtctl stop "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1; then
    RecordError stop 'virtctl stop failed; no fallback lifecycle mutation was attempted'; return 1
  fi
  typeset elapsed=0; typeset phase=''
  while ((elapsed < 120)); do
    if ! phase="$(oc get vmi "${vm}" -n "${ns}" --ignore-not-found -o jsonpath='{.status.phase}' 2>>"${pipelineLog}")"; then
      RecordError stop 'cannot verify VMI stop because the API query failed'; return 1
    fi
    [[ -z "${phase}" ]] && { phase='absent'; break; }
    [[ "${phase}" == 'Succeeded' || "${phase}" == 'Failed' ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  [[ "${phase}" == 'absent' || "${phase}" == 'Succeeded' || "${phase}" == 'Failed' ]] || { RecordError stop "VMI did not reach an offline state (phase=${phase})"; return 1; }
  Log "VMI offline (${phase}); starting snapshot recovery from pre-stop metadata"
  if ! bash "${scriptDir}/recover-natural-crash.sh" --metadata "${metadataFile}" --out "${outDir}" >>"${pipelineLog}" 2>&1; then
    RecordError recovery 'snapshot recovery did not produce the required validated artifacts'; return 1
  fi
  if ((noRestart == 0)); then
    if ! virtctl start "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1; then
      RecordError restart 'virtctl start failed'; return 1
    fi
    Log 'VM restart requested after verified export'
  fi
}

function CrashResponse () {
  typeset state="${1:?}"
  Log "corroborated crash/freeze detected (domstate=${state})"
  typeset failed=0
  CaptureScreenshot || failed=1
  CaptureMemory || failed=1
  CaptureHostSignals || failed=1
  ((failed == 0)) || { WriteSummary || true; return 1; }
  WaitDumpComplete || { WriteSummary || true; return 1; }
  StopAndRecover || { WriteSummary || true; return 1; }
  WriteSummary
}

Log "preflight passed; watching ${ns}/${vm} (pod=${pod}, disk=${diskTarget}, misses=${miss})"
if ! PingOk; then
  RecordError preflight 'qemu guest agent became unavailable after preflight; watcher not armed'
  WriteSummary || true
  exit 1
fi
Log 'qemu guest agent healthy; watcher armed'

# --watch-only prevents pre-existing Panicked events from being replayed.
(
  oc get events -n "${ns}" --watch-only \
    --field-selector "reason=Panicked,involvedObject.name=${vm}" -o name 2>>"${pipelineLog}" |
  while IFS= read -r event; do [[ -n "${event}" ]] && printf '%s\n' "${event}" > "${pvpanicFile}"; done
) &
pvpanicPid=$!

typeset misses=0; typeset state=''; typeset phase=''; typeset decision=''; typeset -a flags=()
while true; do
  if PingOk; then
    misses=0
    sleep "${interval}"
    continue
  fi
  misses=$((misses + 1))
  state="$(DomainState || printf 'unavailable')"
  Log "missed ping ${misses}/${miss} (domstate=${state})"
  if ((misses >= miss)); then
    phase="$(oc get vmi "${vm}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || printf 'unavailable')"
    flags=(--misses "${misses}" --threshold "${miss}" --domstate "${state}" --vmi-phase "${phase}")
    [[ -s "${pvpanicFile}" ]] && flags+=(--pvpanic)
    oc get pod "${pod}" -n "${ns}" >/dev/null 2>&1 && flags+=(--pod-present)
    if ! decision="$(python3 "${scriptDir}/reliability.py" decision "${flags[@]}")"; then
      RecordError detection "$(jq -r .reason <<<"${decision}" 2>/dev/null || echo 'ambiguous crash evidence')"
      WriteSummary || true
      exit 1
    fi
    if [[ "$(jq -r .decision <<<"${decision}")" == 'capture' ]]; then
      kill "${pvpanicPid}" 2>/dev/null || true; pvpanicPid=''
      CrashResponse "${state}"
      exit $?
    fi
  fi
  sleep "${interval}"
done
