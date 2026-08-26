#!/usr/bin/env bash
# collect-from-host.sh - libvirt/KVM host-side BSOD/freeze detector + dump recovery.
#
# Runs on: the Linux HOST (libvirt/KVM; the KubeVirt/OpenShift-Virtualization
# node model). This is the libvirt-native counterpart to collect-from-host.ps1
# (which targets Hyper-V). It covers the cases the guest cannot handle itself:
#   - detect a guest hang/freeze via libvirt state + the qemu-guest-agent ping
#     (a guest that is 'running' but no longer answers guest-ping is the classic
#      BSOD/hang signature - the kernel stopped scheduling the agent)
#   - recover MEMORY.DMP / Minidump\*.dmp offline from the guest disk when the
#     guest is frozen or unbootable, by delegating to host-tools/extract-dump.sh
#     (libguestfs on the host) or host-tools/run.sh (the same in a container)
#   - optional last-resort 'virsh dump' of live guest memory (QEMU/ELF, NOT a
#     Windows crash dump) when the guest is wedged and you cannot power it off
#
# Produces facts only; interpreting the crash is the agent's job. Emits exactly
# one JSON object to stdout (the script contract); diagnostics go to stderr.
#
# Usage:
#   collect-from-host.sh --vm <name> [--mode detect|recover] [--out <dir>]
#                        [--disk <path>] [--windows-root /Windows]
#                        [--force] [--virsh-dump]
#
#   --mode detect   report guest state only (no disk access)
#   --mode recover  detect, then pull dumps offline (default)
#   --disk          guest disk image; auto-resolved from `virsh domblklist` if omitted
#   --force         allow offline read while the VM is still 'running' (risks an
#                   inconsistent image; prefer powering the guest off first)
#   --virsh-dump    if no on-disk dump is found, capture live guest memory via
#                   `virsh dump --memory-only` (briefly pauses the guest)
#
# Output (stdout JSON):
#   { "ok": true, "vm": "...", "mode": "recover",
#     "guestState": "running|off|hung|crashed|rebooting|unknown",
#     "crashDetected": true|false,
#     "recovery": { "method": "none|guestfs-copy-out|guestfs-container|virsh-memory-dump",
#                   "dumpFiles": ["MEMORY.DMP","Minidump/..."], "outputDir": "..." },
#     "warnings": [ ... ] }
set -euo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

typeset here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset hostTools; hostTools="$(cd "$here/../.." && pwd)/host-tools"

VM_NAME="${VM_NAME:-}"
MODE="recover"
OUT=""
DISK=""
WINROOT="/Windows"
FORCE=0
VIRSH_DUMP=0

function Warn () { echo "collect-from-host: $*" >&2; true; }
function Die  () { Warn "$*"; exit 2; }
function Have () { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)           VM_NAME="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --out)          OUT="$2"; shift 2 ;;
    --disk)         DISK="$2"; shift 2 ;;
    --windows-root) WINROOT="$2"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    --virsh-dump)   VIRSH_DUMP=1; shift ;;
    -h|--help)      sed -n '2,44p' "$0"; exit 0 ;;
    *) Die "unknown arg: $1" ;;
  esac
done

Have jq    || Die "jq not found"
Have virsh || Die "virsh not found; install libvirt-client"
[[ -n "$VM_NAME" ]] || Die "--vm is required"
[[ "$MODE" == "detect" || "$MODE" == "recover" ]] || Die "--mode must be detect or recover"

# 1. Guest state via libvirt.
typeset domstate
domstate="$(virsh domstate "$VM_NAME" 2>/dev/null | sed -n '1p' | sed 's/[[:space:]]*$//')" \
  || Die "VM '$VM_NAME' not found (virsh domstate failed)"
[[ -n "$domstate" ]] || Die "VM '$VM_NAME' not found (empty domstate)"

typeset -a warns=()

# 2. qemu-guest-agent liveness (only meaningful while the domain is 'running').
typeset agentOk=""
if [[ "$domstate" == "running" ]]; then
  if timeout 5 virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    agentOk=1
  else
    agentOk=0
  fi
fi

# 3. Map libvirt state (+ agent) to our guestState vocabulary.
typeset guestState
case "$domstate" in
  running)
    if [[ "$agentOk" == "1" ]]; then
      guestState="running"
    else
      guestState="hung"
      warns+=("guest is 'running' but qemu-guest-agent did not answer guest-ping within 5s - classic BSOD/hang signature (or the guest agent is not installed)")
    fi ;;
  "shut off")            guestState="off" ;;
  crashed)               guestState="crashed" ;;
  paused|pmsuspended)    guestState="hung" ;;
  "in shutdown"|dying)   guestState="rebooting" ;;
  *)                     guestState="unknown"; warns+=("unmapped libvirt domstate: '$domstate'") ;;
esac

typeset crashDetected="false"
[[ "$guestState" == "crashed" || "$guestState" == "hung" ]] && crashDetected="true"

typeset method="none"
typeset FILES_JSON="[]"

emit() {  # assemble and print the single JSON result
  local outField="$OUT"
  jq -n \
    --arg vm "$VM_NAME" --arg mode "$MODE" --arg gs "$guestState" \
    --argjson crash "$crashDetected" --arg method "$method" \
    --arg out "$outField" --argjson files "$FILES_JSON" \
    --argjson warns "$(printf '%s\n' "${warns[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
    '{ok:true, vm:$vm, mode:$mode, guestState:$gs, crashDetected:$crash,
      recovery:{method:$method, dumpFiles:$files, outputDir:(if $out=="" then null else $out end)},
      warnings:$warns}'
}

# 4. Detect-only: report and stop.
if [[ "$MODE" == "detect" ]]; then
  emit
  exit 0
fi

# 5. Recovery. Resolve output dir + guest disk.
[[ -n "$OUT" ]] || OUT="$(cd "$here/../.." && pwd)/output/host-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$OUT"

if [[ -z "$DISK" ]]; then
  # First file-backed 'disk' device from domblklist --details:
  #   Type  Device  Target  Source
  DISK="$(virsh domblklist "$VM_NAME" --details 2>/dev/null \
            | awk '$2=="disk" && $4 ~ /^\// {print $4; exit}')" || true
fi

typeset canRead=0
if [[ -z "$DISK" ]]; then
  warns+=("could not resolve the guest disk; pass --disk <path>")
elif [[ ! -r "$DISK" ]]; then
  warns+=("guest disk not readable: $DISK (need libvirt group or root)")
elif [[ "$domstate" == "running" && "$FORCE" != "1" ]]; then
  warns+=("VM is 'running'; reading its disk offline risks an inconsistent image. Power it off (e.g. vmctl.sh kill) then re-run, or pass --force.")
else
  canRead=1
fi

# 5a. Offline dump pull via the existing extractor (libguestfs, host or container).
if [[ "$canRead" == "1" ]]; then
  typeset extractJson=""
  if Have virt-copy-out; then
    extractJson="$("$hostTools/extract-dump.sh" --disk "$DISK" --out "$OUT" --windows-root "$WINROOT")" || true
    method="guestfs-copy-out"
  elif Have podman; then
    extractJson="$("$hostTools/run.sh" --disk "$DISK" --out "$OUT")" || true
    method="guestfs-container"
  else
    warns+=("no libguestfs (virt-copy-out) and no podman on host; cannot pull dumps offline")
  fi
  if [[ -n "$extractJson" ]]; then
    FILES_JSON="$(jq -c '.dumpFiles // []' <<<"$extractJson" 2>/dev/null || echo '[]')"
    while IFS= read -r w; do [[ -n "$w" ]] && warns+=("extract: $w"); done \
      < <(jq -r '.warnings[]? // empty' <<<"$extractJson" 2>/dev/null || true)
  fi
fi

# 5b. Last-resort: capture live guest memory via virsh dump (NOT a Windows dump).
if [[ "$(jq 'length' <<<"$FILES_JSON" 2>/dev/null || echo 0)" -eq 0 && "$VIRSH_DUMP" == "1" ]]; then
  typeset raw="$OUT/qemu-memory.dump"
  if timeout 180 virsh dump "$VM_NAME" "$raw" --memory-only --format elf >/dev/null 2>&1; then
    FILES_JSON="$(jq -n --arg f "qemu-memory.dump" '[$f]')"
    method="virsh-memory-dump"
    warns+=("captured a QEMU/ELF guest-memory image via 'virsh dump' - this is NOT a Windows MEMORY.DMP; analyze with volatility, not cdb")
  else
    warns+=("virsh dump fallback failed (guest may not be dumpable in current state)")
  fi
fi

# Recovering an actual dump confirms a crash occurred.
[[ "$(jq 'length' <<<"$FILES_JSON" 2>/dev/null || echo 0)" -gt 0 ]] && crashDetected="true"

# Parsing the recovered dumps is delegated to parse-dump-header.sh /
# analyze-dump.ps1 (the same logic collect-guest.ps1 uses), not duplicated here.
emit
