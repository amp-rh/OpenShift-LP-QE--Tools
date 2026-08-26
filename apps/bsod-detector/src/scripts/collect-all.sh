#!/usr/bin/env bash
# collect-all.sh - host-side BSOD evidence collection orchestrator.
#
# Single entry point for the detector deliverable. Captures all post-mortem
# evidence from a crashed Windows VM: framebuffer screenshot, guest-side report
# (event logs, dumps, system context), and host-side signals (kernel log,
# hypervisor config).
#
# Invoked by test harnesses (src/scripts/crash-injector/run-dry-run.sh) or by a CI post-step after any
# test run that may have triggered a BSOD.
#
# Usage:
#   collect-all.sh --vm <name> --out <dir> --ssh <guest-ssh-path> \
#     [--guest-scripts <path>] [--timeout 300]
#
# Outputs: <out>/ containing:
#   bsod-screenshot.png    - framebuffer capture (best frame from rapid burst)
#   collect-guest.json     - structured guest-side report
#   host-signals.json      - host-side kernel log + hyperv evidence
#   Minidump/*.dmp         - crash dump files copied from guest
#   evidence-summary.json  - manifest of all collected artifacts
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

typeset scriptDir; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repoRoot; repoRoot="$(cd "$scriptDir/../.." && pwd)"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

typeset vm=""
typeset outDir=""
typeset sshCmd=""
typeset guestScripts='C:/bsod-detector/scripts'
typeset timeout=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)             [[ $# -ge 2 ]] || { echo "collect-all: --vm requires a value" >&2; exit 2; }; vm="$2"; shift 2 ;;
    --out)            [[ $# -ge 2 ]] || { echo "collect-all: --out requires a value" >&2; exit 2; }; outDir="$2"; shift 2 ;;
    --ssh)            [[ $# -ge 2 ]] || { echo "collect-all: --ssh requires a value" >&2; exit 2; }; sshCmd="$2"; shift 2 ;;
    --guest-scripts)  [[ $# -ge 2 ]] || { echo "collect-all: --guest-scripts requires a value" >&2; exit 2; }; guestScripts="$2"; shift 2 ;;
    --timeout)        [[ $# -ge 2 ]] || { echo "collect-all: --timeout requires a value" >&2; exit 2; }; timeout="$2"; shift 2 ;;
    -h|--help)        sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "collect-all: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$vm" ]]     || { echo "collect-all: --vm required" >&2; exit 2; }
[[ -n "$outDir" ]] || { echo "collect-all: --out required" >&2; exit 2; }
[[ -n "$sshCmd" ]] || { echo "collect-all: --ssh required" >&2; exit 2; }

mkdir -p "$outDir"

function Log () { echo "[collect-all] $*" >&2; true; }

# --- Phase 1: Capture BSOD screenshot (background, concurrent with reboot) ---
Log "starting framebuffer capture"
"$scriptDir/capture-vm-screen.sh" --vm "$vm" --out "$outDir" --frames 30 --interval 0.3 &
typeset capturePid=$!

# --- Phase 2: Wait for VM reboot (SSH becomes reachable again) ---
Log "waiting for guest reboot (timeout=${timeout}s)"
typeset rebooted=0
typeset elapsed=0
typeset pollInterval=8
while [[ $elapsed -lt $timeout ]]; do
  if "$sshCmd" -c '"up"' 2>/dev/null | grep -q up; then
    rebooted=1
    break
  fi
  sleep "$pollInterval"
  elapsed=$((elapsed + pollInterval))
done

kill $capturePid 2>/dev/null || true
wait $capturePid 2>/dev/null || true

# --- Phase 3: Select best screenshot frame ---
typeset bestFrame=""
if compgen -G "${outDir}/bsod-frame-*.png" &>/dev/null; then
  bestFrame="$(ls -S "${outDir}"/bsod-frame-*.png 2>/dev/null | head -n1)" || true
fi
if [[ -n "${bestFrame}" ]]; then
  mv "${bestFrame}" "${outDir}/bsod-screenshot.png"
  Log "screenshot captured: bsod-screenshot.png"
else
  Log "WARNING: no screenshot frames captured"
fi
rm -f "$outDir"/bsod-frame-*.png

# --- Phase 4: Collect guest-side evidence (if VM rebooted) ---
typeset guestCollected=false
if [[ "$rebooted" == 1 ]]; then
  Log "guest is up; collecting guest-side evidence"
  typeset guestOut='C:/bsod-detector/output/collect-current'
  typeset guestCommandOk=false
  if "${sshCmd}" -c "Remove-Item -Recurse -Force ${guestOut} -EA SilentlyContinue; & ${guestScripts}/collect-guest.ps1 -OutputDir ${guestOut//\//\\}" \
    2>/dev/null | sed -E '/^#< CLIXML|<Objs /d' > "${outDir}/collect-guest.json"; then
    guestCommandOk=true
  else
    Log "WARNING: guest collection pipeline returned non-zero"
  fi

  if [[ "${guestCommandOk}" == true && -s "${outDir}/collect-guest.json" ]] && python3 -c "import json,sys;json.load(open(sys.argv[1]))" "${outDir}/collect-guest.json" 2>/dev/null; then
    guestCollected=true
    typeset ip=""
    if ip="$(virsh -q domifaddr "${vm}" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)"; then
      true
    fi
    if [[ -n "${ip}" ]]; then
      typeset -a scpOpts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
      typeset keyFile="$repoRoot/.ssh/bsod-test"
      [[ -f "$keyFile" ]] && scpOpts+=(-i "$keyFile" -o IdentitiesOnly=yes)
      scp -r "${scpOpts[@]}" "Administrator@$ip:${guestOut}/*" "$outDir/" 2>/dev/null || true
    fi
    Log "guest evidence collected"
  else
    Log "WARNING: collect-guest.ps1 produced no output"
  fi
else
  Log "WARNING: guest did not reboot within ${timeout}s; guest-side collection skipped"
fi

# --- Phase 5: Collect host-side signals ---
Log "collecting host-side signals"
"$scriptDir/collect-host-signals.sh" --vm "$vm" > "$outDir/host-signals.json" 2>/dev/null || true

# --- Phase 6: Assemble evidence summary manifest ---
Log "writing evidence summary"
typeset hasScreenshot=false; [[ -f "$outDir/bsod-screenshot.png" ]] && hasScreenshot=true
typeset hasHostSignals=false; [[ -s "$outDir/host-signals.json" ]] && hasHostSignals=true
typeset -a dumpFiles=()
if [[ -d "$outDir/Minidump" ]]; then
  while IFS= read -r f; do
    dumpFiles+=("Minidump/$(basename "${f}")")
  done < <(find "${outDir}/Minidump" -name '*.dmp' 2>/dev/null)
fi
typeset hasMemoryDmp=false
if [[ -f "${outDir}/MEMORY.DMP" ]]; then
  hasMemoryDmp=true
  dumpFiles+=("MEMORY.DMP")
fi

python3 - "$outDir" "$hasScreenshot" "$guestCollected" "$hasHostSignals" "${dumpFiles[@]}" <<'PY'
import json, sys, os
out_dir = sys.argv[1]
has_screenshot = sys.argv[2] == "true"
guest_collected = sys.argv[3] == "true"
has_host_signals = sys.argv[4] == "true"
dump_files = sys.argv[5:] if len(sys.argv) > 5 else []

crash_info = None
if guest_collected:
    try:
        with open(os.path.join(out_dir, "collect-guest.json")) as f:
            guest = json.load(f)
            crash_info = guest.get("crash", {})
    except (json.JSONDecodeError, FileNotFoundError):
        pass

summary = {
    "ok": True,
    "collectedAt": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "artifacts": {
        "screenshot": "bsod-screenshot.png" if has_screenshot else None,
        "guestReport": "collect-guest.json" if guest_collected else None,
        "hostSignals": "host-signals.json" if has_host_signals else None,
        "dumpFiles": dump_files,
    },
    "crash": crash_info,
}

with open(os.path.join(out_dir, "evidence-summary.json"), "w") as f:
    json.dump(summary, f, indent=2)
print(json.dumps(summary, indent=2))
PY

Log "done. Evidence package: $outDir"
