#!/usr/bin/env bash
#
# stakeout.sh -- end-to-end campaign runner for a NATURALLY-OCCURRING Windows
# BSOD/freeze. A stakeout: you do not cause the crime, you make sure every
# camera is running before it happens and you miss nothing when it does.
#
# This orchestrates the four phases of docs/file-guide.md section 6 that were
# previously manual or missing:
#
#   1. PREFLIGHT  Verify every precondition that decides whether the crash can
#                 happen AND whether it can be captured. Read-only: it never
#                 mutates the VM or the node, it prints the remedy. Blocks the
#                 campaign rather than letting you stake out a VM for hours and
#                 find out afterwards the evidence was never capturable.
#   2. STAGE      Idempotently put the toolkit + dump config into the guest.
#   3. WATCH      Delegate to watch-crash.sh (detection is not reimplemented).
#   4. ESCALATE   The gap this script exists to close. On a HARD FREEZE
#                 watch-crash.sh stops -- but a frozen guest is exactly when
#                 guest memory is still resident in host RAM. Escalate to
#                 capture-host-dump.sh (virsh dump + elf2dmp, raw ELF preserved)
#                 and collect-from-host.sh --mode recover (libguestfs offline).
#   5. VERDICT    One stakeout-summary.json with a plain-English verdict.
#
# WHAT THIS SCRIPT DOES NOT DO
#   - It does not trigger the crash. There is no such thing as triggering a
#     natural BSOD; see docs/file-guide.md section 2. Use --workload to run your
#     own load generator alongside the watch.
#   - It does not fix preconditions. Hyper-V enlightenments need a VM restart and
#     split_lock_detect needs a node MachineConfig + reboot; on a shared cluster
#     that is not a script's decision. Preflight prints exactly what to change.
#
# BACKENDS (review item #3): --provider kubevirt|kvm|auto, or BSOD_DET__HYP_PROV.
#   kubevirt -> virsh runs inside the virt-launcher pod via `oc exec`, domain is
#               <ns>_<vm>.  kvm -> virsh runs directly, domain is <vm>.
#
# Usage:
#   ./stakeout.sh preflight [--scenario tlb-flush] [--ns NS] [--vm NAME]
#   ./stakeout.sh stage     [--ns NS] [--vm NAME]
#   ./stakeout.sh watch     [--out DIR] [--duration SEC] [--workload 'CMD']
#   ./stakeout.sh escalate  --out DIR          # run phase 4 against a frozen VM
#
# Common flags: --ns --vm --out --provider --scenario --duration --workload
#               --workload-guest --skip-preflight --dry-run --json -h
# Offline preflight (check artifacts captured elsewhere, no cluster needed):
#               --domain-xml FILE --node-cmdline FILE
#
# Requires: jq, python3; plus `oc` (kubevirt) or `virsh` (kvm). Sibling scripts:
#   watch-crash.sh, capture-host-dump.sh, collect-from-host.sh, guest-agent.py,
#   collect-host-signals.sh, parse-dump-header.sh
#
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appRoot='';   appRoot="$(cd "${scriptDir}/../../.." && pwd)"

typeset cmd="${1:-}"; [ $# -gt 0 ] && shift || true

typeset ns=""
typeset vm=""
typeset outDir=""
typeset provider="${BSOD_DET__HYP_PROV:-auto}"
typeset scenario="any"          # 'tlb-flush' promotes the enlightenment check to a blocker
typeset duration=0              # 0 = watch until crash or Ctrl-C
typeset workload=""             # host-side command to run during the watch
typeset workloadGuest=""        # .ps1 to run in the guest during the watch
typeset skipPreflight=false
typeset dryRun=false
typeset jsonOnly=false
typeset domainXmlFile=""        # preflight offline: read domain XML from a file
typeset nodeCmdlineFile=""      # preflight offline: read the node /proc/cmdline from a file
typeset -a watchArgs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)             ns="$2"; shift 2;;
    --vm)             vm="$2"; shift 2;;
    --out)            outDir="$2"; shift 2;;
    --provider)       provider="$2"; shift 2;;
    --scenario)       scenario="$2"; shift 2;;
    --duration)       duration="$2"; shift 2;;
    --workload)       workload="$2"; shift 2;;
    --workload-guest) workloadGuest="$2"; shift 2;;
    --skip-preflight) skipPreflight=true; shift;;
    --dry-run)        dryRun=true; shift;;
    --json)           jsonOnly=true; shift;;
    --domain-xml)     domainXmlFile="$2"; shift 2;;
    --node-cmdline)   nodeCmdlineFile="$2"; shift 2;;
    --interval|--miss|--node|--reboot-wait|--burst)
                      watchArgs+=("$1" "$2"); shift 2;;
    -h|--help)        sed -n '2,55p' "$0"; exit 0;;
    *) echo "stakeout: unknown arg: $1" >&2; exit 2;;
  esac
done

case "${cmd}" in
  preflight|stage|watch|escalate) : ;;
  ''|-h|--help) sed -n '2,55p' "$0"; exit 0;;
  *) echo "stakeout: unknown command '${cmd}' (want: preflight|stage|watch|escalate)" >&2; exit 2;;
esac

function Log  () { [ "${jsonOnly}" = true ] || echo "[$(date -u +%H:%M:%S)] $*" >&2; true; }
function Die  () { echo "stakeout: $*" >&2; exit 1; }
function Have () { command -v "$1" >/dev/null 2>&1; }

# Echo instead of executing under --dry-run, so the whole decision tree is
# exercisable (and testable) without a cluster.
function Run () {
  if [ "${dryRun}" = true ]; then echo "DRY-RUN: $*" >&2; return 0; fi
  "$@"
}

# --- backend abstraction (review #3) -----------------------------------------

if [ "${provider}" = auto ]; then
  if Have oc && oc get vmi -A >/dev/null 2>&1; then provider=kubevirt
  elif Have virsh; then provider=kvm
  elif [ "${dryRun}" = true ]; then provider=kubevirt
  else provider=unknown; fi
fi
case "${provider}" in
  kubevirt|kvm) : ;;
  *) Die "cannot determine hypervisor provider; pass --provider kubevirt|kvm (or set BSOD_DET__HYP_PROV)";;
esac

typeset pod=""
typeset dom=""

# Resolve ns/vm/pod/dom for the active provider. Explicit flags always win.
function ResolveTarget () {
  if [ "${provider}" = kubevirt ]; then
    if [ -z "${vm}" ] || [ -z "${ns}" ]; then
      typeset -a scope=(-A); [ -n "${ns}" ] && scope=(-n "${ns}")
      typeset -a rows=()
      mapfile -t rows < <(oc get vmi "${scope[@]}" \
        -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d') || true
      [ -n "${vm}" ] && [ "${#rows[@]}" -gt 0 ] && \
        mapfile -t rows < <(printf '%s\n' "${rows[@]}" | awk -v v="${vm}" '$2==v')
      case "${#rows[@]}" in
        1) read -r ns vm <<<"${rows[0]}"; Log "auto-detected target: ns=${ns} vm=${vm}";;
        0) [ "${dryRun}" = true ] && { ns="${ns:-DRYRUN-NS}"; vm="${vm:-DRYRUN-VM}"; } \
             || Die "no matching VMI found; pass --ns <ns> --vm <name>";;
        *) printf 'stakeout: ambiguous target; pass --ns and/or --vm. Candidates:\n' >&2
           printf '  %s\n' "${rows[@]}" >&2; exit 1;;
      esac
    fi
    pod="$(oc get pod -n "${ns}" -o name 2>/dev/null | sed -n "/virt-launcher-${vm}-/p" | head -n1 | cut -d/ -f2)" || true
    [ -n "${pod}" ] || [ "${dryRun}" = true ] || Die "no virt-launcher pod for ${vm} in ${ns}"
    dom="${ns}_${vm}"
    export GA_NS="${ns}" GA_VM="${vm}" GA_DOM="${dom}"
    [ -n "${pod}" ] && export GA_POD="${pod}"
  else
    [ -n "${vm}" ] || vm="${VM_NAME:-bsod-test}"
    dom="${vm}"
    export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
  fi
  true
}

function Virsh () {
  if [ "${provider}" = kubevirt ]; then Run oc exec -n "${ns}" "${pod}" -- virsh "$@"
  else Run virsh "$@"; fi
}

function Ga () { Run python3 "${scriptDir}/guest-agent.py" "$@"; }

# --- phase 1: preflight -------------------------------------------------------

typeset -a CHECKS=()
typeset -i BLOCKERS=0
typeset -i WARNS=0

function Check () {   # id status(pass|warn|fail) detail [remedy]
  typeset id="$1" status="$2" detail="$3" remedy="${4:-}"
  CHECKS+=("$(jq -nc --arg id "${id}" --arg status "${status}" \
                     --arg detail "${detail}" --arg remedy "${remedy}" \
      '{id:$id,status:$status,detail:$detail,remedy:(if $remedy=="" then null else $remedy end)}')")
  case "${status}" in
    fail) BLOCKERS=$((BLOCKERS+1)); [ "${jsonOnly}" = true ] || printf '  [FAIL] %-22s %s\n' "${id}" "${detail}" >&2;;
    warn) WARNS=$((WARNS+1));       [ "${jsonOnly}" = true ] || printf '  [warn] %-22s %s\n' "${id}" "${detail}" >&2;;
    *)                              [ "${jsonOnly}" = true ] || printf '  [ ok ] %-22s %s\n' "${id}" "${detail}" >&2;;
  esac
  [ -n "${remedy}" ] && [ "${status}" != pass ] && [ "${jsonOnly}" != true ] && \
    printf '         -> %s\n' "${remedy}" >&2
  true
}

function Preflight () {
  Log "preflight (provider=${provider}, scenario=${scenario}) -- read-only, nothing is modified"

  # -- tooling
  typeset -a missing=()
  typeset t=""
  for t in jq python3; do Have "${t}" || missing+=("${t}"); done
  if [ "${provider}" = kubevirt ]; then Have oc || missing+=(oc); else Have virsh || missing+=(virsh); fi
  if [ "${#missing[@]}" -eq 0 ]; then Check tooling pass "all required binaries present"
  else Check tooling fail "missing: ${missing[*]}" "install them before running a campaign"; fi

  # -- sibling scripts we delegate to
  missing=()
  for t in watch-crash.sh capture-host-dump.sh collect-from-host.sh guest-agent.py \
           collect-host-signals.sh parse-dump-header.sh; do
    [ -f "${scriptDir}/${t}" ] || missing+=("${t}")
  done
  if [ "${#missing[@]}" -eq 0 ]; then Check siblings pass "all delegate scripts found in ${scriptDir##*/}/"
  else Check siblings fail "missing: ${missing[*]}" "run from a complete checkout"; fi

  # -- target reachable
  typeset state=""
  state="$(Virsh domstate "${dom}" 2>/dev/null | tr -d '[:space:]')" || true
  case "${state}" in
    running) Check target pass "${dom} is running";;
    "")      Check target "$([ "${dryRun}" = true ] && echo warn || echo fail)" \
                 "cannot read domstate for ${dom}" "check --ns/--vm and cluster access";;
    *)       Check target fail "${dom} is '${state}', not running" "start the VM before staking it out";;
  esac

  # -- guest agent
  if [ "${dryRun}" = true ]; then Check guest-agent warn "dry-run: guest agent not actually pinged"
  elif Ga ping >/dev/null 2>&1; then Check guest-agent pass "qemu-guest-agent answers"
  else Check guest-agent fail "guest agent not answering" \
         "install/start qemu-guest-agent in the guest; detection depends on it"; fi

  # -- domain XML derived checks (from a file when given, so preflight can run
  #    offline against artifacts captured elsewhere -- same pattern as
  #    collect-host-signals.sh --domain-xml)
  typeset xml=""
  if [ -n "${domainXmlFile}" ]; then
    [ -f "${domainXmlFile}" ] || Die "--domain-xml: no such file: ${domainXmlFile}"
    xml="$(cat "${domainXmlFile}")"
  else
    xml="$(Virsh dumpxml "${dom}" 2>/dev/null)" || true
  fi

  # pvpanic (review #6): changes the domstate seen at bugcheck, and can move the
  # guest out of 'running' before the host has captured anything.
  if [ -z "${xml}" ]; then Check pvpanic warn "domain XML unavailable; cannot tell"
  elif printf '%s' "${xml}" | grep -q 'pvpanic'; then
    Check pvpanic pass "pvpanic present -- expect domstate crashed/paused at bugcheck"
  else
    Check pvpanic warn "no pvpanic device -- a bugcheck will leave domstate 'running' (pure hang)" \
      "detection still works; watch-crash.sh treats running+dead-agent as a crash"
  fi

  # Hyper-V enlightenments: the TLB-flush scenario REQUIRES the unmitigated
  # config. Without both tlbflush and ipi the crash simply will not occur.
  typeset hasTlb=false hasIpi=false
  if [ -n "${xml}" ]; then
    printf '%s' "${xml}" | grep -q "<tlbflush[^>]*state=['\"]on" && hasTlb=true || true
    printf '%s' "${xml}" | grep -q "<ipi[^>]*state=['\"]on"      && hasIpi=true || true
  fi
  if [ -z "${xml}" ]; then
    Check hyperv-enlightenments warn "domain XML unavailable; cannot verify tlbflush/ipi"
  elif [ "${hasTlb}" = true ] && [ "${hasIpi}" = true ]; then
    Check hyperv-enlightenments pass "tlbflush + ipi both on (unmitigated -- TLB-flush crash is possible)"
  elif [ "${scenario}" = tlb-flush ]; then
    Check hyperv-enlightenments fail \
      "tlbflush=${hasTlb} ipi=${hasIpi} -- the TLB-flush crash CANNOT occur in this config" \
      "enable both in spec.domain.features.hyperv (KubeVirt) or <hyperv> in the domain XML, then restart the VM"
  else
    Check hyperv-enlightenments warn "tlbflush=${hasTlb} ipi=${hasIpi} (not the unmitigated config)"
  fi

  # Screenshot viability: virtio-video goes dark during a kernel crash.
  if [ -z "${xml}" ]; then Check video-device warn "domain XML unavailable; cannot verify video model"
  elif printf '%s' "${xml}" | grep -qE "<model[^>]*type=['\"](qxl|vga|cirrus|bochs)"; then
    Check video-device pass "framebuffer model supports crash-time screenshots"
  else
    Check video-device warn "video model appears to be virtio -- no framebuffer during a kernel crash" \
      "switch to QXL/VGA if you need the blue-screen image; all other evidence is unaffected"
  fi

  # split_lock_detect on the worker node: without it the #AC line never appears,
  # even when the crash does -- and that is the ONLY host-side attribution.
  typeset cmdline=""
  if [ -n "${nodeCmdlineFile}" ]; then
    [ -f "${nodeCmdlineFile}" ] || Die "--node-cmdline: no such file: ${nodeCmdlineFile}"
    cmdline="$(cat "${nodeCmdlineFile}")"
  elif [ "${provider}" = kubevirt ]; then
    typeset node=""
    node="$(oc get vmi "${vm}" -n "${ns}" -o jsonpath='{.status.nodeName}' 2>/dev/null)" || true
    [ -n "${node}" ] && cmdline="$(Run timeout 90 oc debug "node/${node}" -- chroot /host cat /proc/cmdline 2>/dev/null)" || true
  else
    cmdline="$(cat /proc/cmdline 2>/dev/null)" || true
  fi
  if [ -z "${cmdline}" ]; then
    Check split-lock-detect warn "could not read the node kernel cmdline" \
      "verify manually: split_lock_detect must be 'warn' or 'on'"
  elif printf '%s' "${cmdline}" | grep -qE 'split_lock_detect=(warn|on|fatal)'; then
    Check split-lock-detect pass "split-lock detection enabled on the node"
  else
    Check split-lock-detect "$([ "${scenario}" = tlb-flush ] && echo fail || echo warn)" \
      "split_lock_detect is not enabled -- the #AC evidence will NEVER appear, crash or not" \
      "add split_lock_detect=warn via a MachineConfig (node reboot required)"
  fi

  # -- guest side: dump config + staged toolkit
  typeset probe=""
  probe="$(Ga psfile "${appRoot}/src/scripts/guest/probe-dump-config.ps1" 2>/dev/null | sed -n '/^{/,$p')" || true
  if [ -z "${probe}" ]; then
    Check guest-dump-config warn "could not probe the guest dump configuration"
  else
    typeset enabled=""
    enabled="$(printf '%s' "${probe}" | jq -r '.crashControl.CrashDumpEnabled // empty' 2>/dev/null)" || true
    if [ "${enabled}" = "0" ] || [ -z "${enabled}" ]; then
      Check guest-dump-config warn "CrashDumpEnabled=${enabled:-unknown} -- no dump will be written" \
        "run: stakeout.sh stage   (applies configure-dumps.ps1; needs a guest reboot)"
    else
      Check guest-dump-config pass "CrashDumpEnabled=${enabled}"
    fi
    if printf '%s' "${probe}" | jq -e '.toolkitStaged == true' >/dev/null 2>&1; then
      Check toolkit-staged pass "toolkit present at C:\\bsod-detector"
    else
      Check toolkit-staged warn "toolkit not staged -- post-reboot collection will be skipped" \
        "run: stakeout.sh stage"
    fi
  fi

  # -- offline recovery readiness: this is what saves a HARD FREEZE
  if Have virt-copy-out || Have podman; then
    Check offline-recovery pass "libguestfs or podman available for offline dump recovery"
  else
    Check offline-recovery warn "neither virt-copy-out nor podman found" \
      "install libguestfs-tools or podman, else a hard freeze yields no dump at all"
  fi
  if Have elf2dmp; then Check elf2dmp pass "elf2dmp available (host-side dump conversion)"
  else Check elf2dmp warn "elf2dmp not found (qemu-tools)" \
         "without it the raw ELF is still preserved and convertible later"; fi

  true
}

function WritePreflight () {   # $1 = destination file (optional)
  typeset ready=true
  [ "${BLOCKERS}" -gt 0 ] && ready=false
  typeset json=""
  json="$(printf '%s\n' "${CHECKS[@]}" | jq -s \
      --arg vm "${vm}" --arg ns "${ns}" --arg dom "${dom}" \
      --arg provider "${provider}" --arg scenario "${scenario}" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson ready "${ready}" --argjson blockers "${BLOCKERS}" --argjson warnings "${WARNS}" \
      '{ok:true, phase:"preflight", checkedAt:$at, provider:$provider, scenario:$scenario,
        vm:$vm, namespace:(if $ns=="" then null else $ns end), domain:$dom,
        ready:$ready, blockers:$blockers, warnings:$warnings, checks:.}')"
  [ -n "${1:-}" ] && printf '%s\n' "${json}" > "$1"
  [ "${jsonOnly}" = true ] && printf '%s\n' "${json}"
  true
}

# --- phase 2: stage -----------------------------------------------------------

function Stage () {
  Log "staging toolkit + dump configuration into the guest (idempotent)"
  typeset zip="/tmp/bsod-src-$$.zip"
  Run bash -c "cd '${appRoot}' && rm -f '${zip}' && zip -qr '${zip}' src"
  Ga put "${zip}" 'C:\Windows\Temp\bsod-src.zip' >/dev/null 2>&1 || Log "warn: upload failed"
  Ga psfile "${appRoot}/src/scripts/guest/stage-toolkit.ps1"    >/dev/null 2>&1 || Log "warn: stage-toolkit failed"
  Ga psfile "${appRoot}/src/scripts/guest/configure-dumps.ps1"  >/dev/null 2>&1 || Log "warn: configure-dumps failed"
  Run rm -f "${zip}"
  Log "staged. If configure-dumps reported rebootRequired, reboot the guest before the campaign."
  true
}

# --- phase 4: escalate (the gap this script closes) ---------------------------
#
# watch-crash.sh stops at a hard freeze. But a frozen guest still holds its
# memory in host RAM, so this is the highest-value moment for a host-side
# capture -- and the last one before anybody power-cycles the VM.

typeset escalationMethod="none"
typeset -a escalationFiles=()

function Escalate () {
  typeset dst="$1"
  Log "*** HARD FREEZE -- escalating to host-side capture (guest memory is still resident) ***"
  mkdir -p "${dst}/host-recovery"

  # 4a. Live memory capture + elf2dmp conversion. Raw ELF is always preserved
  #     (review #5) so a symbol mismatch can be re-converted offline later.
  if [ "${provider}" = kvm ]; then
    if Run bash "${scriptDir}/capture-host-dump.sh" --vm "${dom}" --out "${dst}/host-recovery" \
         > "${dst}/host-recovery/capture-host-dump.json" 2>/dev/null; then
      escalationMethod="virsh-dump+elf2dmp"; escalationFiles+=("host-recovery/host-crash.dmp")
      Log "host-side dump captured"
    else
      Log "warn: capture-host-dump.sh failed (domain may need <on_crash>preserve</on_crash>)"
    fi
  else
    # On KubeVirt the domain lives inside virt-launcher, so dump there and copy out.
    Log "kubevirt: dumping guest memory inside the virt-launcher pod"
    if Virsh dump --memory-only --live "${dom}" /tmp/guest-memory.elf >/dev/null 2>&1; then
      Run oc cp "${ns}/${pod}:/tmp/guest-memory.elf" "${dst}/host-recovery/guest-memory.elf" >/dev/null 2>&1 || true
      escalationFiles+=("host-recovery/guest-memory.elf")
      escalationMethod="virsh-dump"
      if Have elf2dmp && [ -s "${dst}/host-recovery/guest-memory.elf" ]; then
        Run elf2dmp "${dst}/host-recovery/guest-memory.elf" "${dst}/host-recovery/host-crash.dmp" >/dev/null 2>&1 \
          && { escalationMethod="virsh-dump+elf2dmp"; escalationFiles+=("host-recovery/host-crash.dmp"); } \
          || Log "warn: elf2dmp conversion failed; the raw ELF is preserved for offline conversion"
      fi
    else
      Log "warn: virsh dump failed inside the pod"
    fi
  fi

  # 4b. Offline extraction from the guest disk (review #7 / #2). Only meaningful
  #     once the guest is powered off; we do not power it off for you.
  if [ "${provider}" = kvm ]; then
    if Run bash "${scriptDir}/collect-from-host.sh" --vm "${dom}" --mode recover \
         --out "${dst}/host-recovery" > "${dst}/host-recovery/collect-from-host.json" 2>/dev/null; then
      escalationFiles+=("host-recovery/collect-from-host.json")
      Log "offline recovery attempted; see collect-from-host.json"
    else
      Log "warn: offline recovery needs the guest powered off -- rerun after: virsh destroy ${dom}"
    fi
  else
    Log "kubevirt: for offline disk recovery run collect-from-host.sh ON THE WORKER NODE after stopping the VM"
  fi
  true
}

# --- phase 5: verdict ---------------------------------------------------------

function Verdict () {
  typeset dst="$1" timedOut="$2"
  typeset ev="${dst}/evidence-summary.json"
  typeset crashed=false rebooted=false hardFreeze=false splitLock=null bugCheck=""
  if [ -s "${ev}" ]; then
    crashed="$(jq -r '.crashDetected // false' "${ev}" 2>/dev/null)"   || crashed=false
    rebooted="$(jq -r '.guestRebooted // false' "${ev}" 2>/dev/null)"  || rebooted=false
    hardFreeze="$(jq -r '.hardFreeze // false' "${ev}" 2>/dev/null)"   || hardFreeze=false
    splitLock="$(jq -c '.splitLockDetected // null' "${ev}" 2>/dev/null)" || splitLock=null
    bugCheck="$(jq -r '.bugCheck // empty' "${ev}" 2>/dev/null)"       || bugCheck=""
  fi

  typeset verdict="" advice=""
  if [ "${crashed}" != true ]; then
    verdict="no-crash"
    advice="No crash within the campaign window. This is a valid outcome. Re-check preflight warnings, lengthen --duration, or intensify the workload."
  elif [ "${hardFreeze}" = true ] && [ "${splitLock}" = true ]; then
    verdict="hard-freeze-splitlock"
    advice="Hard freeze WITH a split-lock #AC on the node -- the strongest available evidence for the TLB-flush HYPERVISOR_ERROR path. Guest wrote no dump, as expected; use the host-side capture in host-recovery/."
  elif [ "${hardFreeze}" = true ]; then
    verdict="hard-freeze-unattributed"
    advice="Hard freeze with no split-lock signal. Confirm split_lock_detect is enabled on the node -- absence of the signal is not absence of the cause. Check host-recovery/ for the memory capture."
  elif [ -n "${bugCheck}" ]; then
    verdict="bugcheck-captured"
    advice="Guest rebooted and a dump was recovered (${bugCheck}). Run analyze-dump.ps1 for the failure bucket and faulting image."
  else
    verdict="crash-no-dump"
    advice="Crash detected and the guest rebooted, but no dump was found. See the three-tier detection notes in collect-guest.json (LiveKernelEvent / dirty shutdown)."
  fi

  typeset filesJson='[]'
  [ "${#escalationFiles[@]}" -gt 0 ] && filesJson="$(printf '%s\n' "${escalationFiles[@]}" | jq -R . | jq -sc .)"

  jq -n \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg vm "${vm}" --arg ns "${ns}" \
    --arg dom "${dom}" --arg provider "${provider}" --arg scenario "${scenario}" \
    --arg verdict "${verdict}" --arg advice "${advice}" --arg bugCheck "${bugCheck}" \
    --arg method "${escalationMethod}" --argjson files "${filesJson}" \
    --argjson crashed "${crashed}" --argjson rebooted "${rebooted}" \
    --argjson hardFreeze "${hardFreeze}" --argjson splitLock "${splitLock}" \
    --argjson timedOut "${timedOut}" --argjson warnings "${WARNS}" \
    '{ok:true, phase:"stakeout", mode:"natural", completedAt:$at,
      provider:$provider, scenario:$scenario, vm:$vm,
      namespace:(if $ns=="" then null else $ns end), domain:$dom,
      campaignTimedOut:$timedOut, preflightWarnings:$warnings,
      crashDetected:$crashed, guestRebooted:$rebooted, hardFreeze:$hardFreeze,
      bugCheck:(if $bugCheck=="" then null else $bugCheck end),
      splitLockDetected:$splitLock,
      hostRecovery:{method:$method, files:$files},
      verdict:$verdict, advice:$advice,
      artifacts:{preflight:"preflight.json", evidence:"evidence-summary.json"}}' \
    > "${dst}/stakeout-summary.json"

  if [ "${jsonOnly}" = true ]; then cat "${dst}/stakeout-summary.json"
  else
    Log "VERDICT: ${verdict}"
    Log "${advice}"
    Log "package: ${dst}"
  fi
  true
}

# --- phase 3 + driver ---------------------------------------------------------

function Watch () {
  typeset dst="$1"
  typeset -a wa=(--out "${dst}")
  [ "${provider}" = kubevirt ] && wa+=(--ns "${ns}" --vm "${vm}")
  [ "${#watchArgs[@]}" -gt 0 ] && wa+=("${watchArgs[@]}")

  typeset wlPid="" wlgPid=""
  if [ -n "${workload}" ]; then
    Log "starting host-side workload: ${workload}"
    if [ "${dryRun}" = true ]; then echo "DRY-RUN: workload: ${workload}" >&2
    else bash -c "${workload}" >"${dst}/workload.log" 2>&1 & wlPid=$!; fi
  fi
  if [ -n "${workloadGuest}" ]; then
    Log "starting in-guest workload: ${workloadGuest}"
    if [ "${dryRun}" = true ]; then echo "DRY-RUN: guest workload: ${workloadGuest}" >&2
    else python3 "${scriptDir}/guest-agent.py" psfile "${workloadGuest}" >"${dst}/workload-guest.log" 2>&1 & wlgPid=$!; fi
  fi

  typeset timedOut=false
  typeset -i rc=0
  if [ "${dryRun}" = true ]; then
    echo "DRY-RUN: bash ${scriptDir}/watch-crash.sh ${wa[*]}" >&2
  elif [ "${duration}" -gt 0 ]; then
    Log "watching for up to ${duration}s (a clean timeout is a valid 'no crash' result)"
    timeout "${duration}" bash "${scriptDir}/watch-crash.sh" "${wa[@]}" || rc=$?
    [ "${rc}" -eq 124 ] && timedOut=true
  else
    Log "watching until a crash or Ctrl-C"
    bash "${scriptDir}/watch-crash.sh" "${wa[@]}" || rc=$?
  fi

  [ -n "${wlPid}" ]  && kill "${wlPid}"  2>/dev/null || true
  [ -n "${wlgPid}" ] && kill "${wlgPid}" 2>/dev/null || true

  # The gap: watch-crash.sh records the freeze but never tries a host-side capture.
  if [ -s "${dst}/evidence-summary.json" ] && \
     jq -e '.hardFreeze == true' "${dst}/evidence-summary.json" >/dev/null 2>&1; then
    Escalate "${dst}"
  elif [ "${dryRun}" = true ]; then
    Log "dry-run: would escalate here if evidence-summary.json reported hardFreeze"
  fi

  Verdict "${dst}" "${timedOut}"
  true
}

ResolveTarget
[ -n "${outDir}" ] || outDir="./output/stakeout-$(date +%Y%m%d-%H%M%S)"

case "${cmd}" in
  preflight)
    mkdir -p "${outDir}"; Preflight; WritePreflight "${outDir}/preflight.json"
    Log "preflight: ${BLOCKERS} blocker(s), ${WARNS} warning(s) -> ${outDir}/preflight.json"
    [ "${BLOCKERS}" -eq 0 ] || exit 1
    ;;
  stage)
    Stage
    ;;
  escalate)
    [ -d "${outDir}" ] || Die "escalate needs an existing evidence dir: --out DIR"
    Escalate "${outDir}"; Verdict "${outDir}" false
    ;;
  watch)
    mkdir -p "${outDir}"
    if [ "${skipPreflight}" = true ]; then
      Log "preflight skipped by request"
    else
      Preflight; WritePreflight "${outDir}/preflight.json"
      if [ "${BLOCKERS}" -gt 0 ]; then
        Log "ABORT: ${BLOCKERS} blocker(s). Fix them, or rerun with --skip-preflight to stake out anyway."
        exit 1
      fi
      [ "${WARNS}" -gt 0 ] && Log "proceeding with ${WARNS} warning(s) -- some evidence may be unavailable"
    fi
    Watch "${outDir}"
    ;;
esac
true
