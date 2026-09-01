#!/usr/bin/env bash
# capture-host-dump.sh - host-side crash dump via virsh dump + elf2dmp.
#
# When a Windows guest crashes and the domain enters the "crashed" state
# (requires <on_crash>preserve</on_crash> in the domain XML), this script
# captures a full physical memory dump from the host side and converts it
# to a WinDbg-readable DMP file using QEMU's elf2dmp tool.
#
# This is a fallback for cases where the guest-side crash dump mechanism
# fails (e.g., viostor StorPortGetUncachedExtension failure under
# allocation pressure). See:
#   https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1629
#   https://daynix.github.io/2023/05/23/Guest-Windows-debugging-and-crashdumping-under-QEMU-KVM-elf2dmp.html
#
# Prerequisites:
#   - elf2dmp (Fedora: qemu-tools package)
#   - virsh (libvirt)
#   - Network access (elf2dmp downloads PDB from Microsoft symbol server)
#   - Domain must be in "crashed" or "paused" state
#
# Usage:
#   capture-host-dump.sh --vm <name> --out <dir>
#
# Output (stdout JSON):
#   { "ok": true, "dumpFile": "host-crash.dmp", "method": "elf2dmp",
#     "sizeBytes": N, "warnings": [] }
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

typeset vm=""
typeset outDir=""

function Warn () { echo "capture-host-dump: $*" >&2; true; }
function Die ()  { Warn "$*"; exit 2; }
function Have () { command -v "$1" >/dev/null 2>&1; }

# Emit a JSON failure object to stdout and exit 1.
function EmitFailure () {
  typeset error="$1"; shift
  typeset warnsJson='[]'
  if [[ $# -gt 0 ]]; then
    warnsJson="$(printf '%s\n' "$@" | jq -R . | jq -s '.')"
  fi
  jq -n --arg e "${error}" --argjson w "${warnsJson}" \
    '{ ok: false, error: $e, warnings: $w }'
  exit 1
}

Have virsh    || Die "virsh not found"
Have elf2dmp  || Die "elf2dmp not found (install qemu-tools)"
Have jq       || Die "jq not found"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)  [[ $# -ge 2 ]] || Die "--vm requires a value";  vm="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || Die "--out requires a value"; outDir="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) Die "unknown arg: $1" ;;
  esac
done

[[ -n "${vm}" ]]     || Die "--vm required"
[[ -n "${outDir}" ]] || Die "--out required"

mkdir -p "${outDir}"

typeset -a warnings=()
typeset elfFile="${outDir}/guest-memory.elf"
typeset dmpFile="${outDir}/host-crash.dmp"

typeset domState=''
domState="$(virsh domstate "${vm}" 2>/dev/null)" || EmitFailure "could not query domain state for '${vm}'"

case "${domState}" in
  crashed|paused)
    Warn "domain '${vm}' is in '${domState}' state; proceeding with memory dump"
    ;;
  *)
    EmitFailure "domain '${vm}' is in '${domState}' state (expected 'crashed' or 'paused')"
    ;;
esac

Warn "capturing guest memory via virsh dump --memory-only (this may take a while for large VMs)"
if ! virsh dump "${vm}" "${elfFile}" --memory-only --verbose 2>&1 | while IFS= read -r line; do Warn "virsh: ${line}"; done; then
  EmitFailure "virsh dump --memory-only failed" "ELF file may be incomplete at ${elfFile}"
fi

if [[ ! -f "${elfFile}" ]]; then
  EmitFailure "virsh dump completed but ELF file not found at ${elfFile}"
fi

chmod u+rw "${elfFile}" 2>/dev/null || warnings+=("could not fix permissions on ${elfFile}; elf2dmp may fail")

typeset elfSize=''
elfSize="$(stat -c%s "${elfFile}" 2>/dev/null)" || elfSize="unknown"
Warn "ELF dump captured: ${elfFile} (${elfSize} bytes)"

Warn "converting ELF to WinDbg DMP via elf2dmp (requires network for PDB download)"
typeset elf2dmpOutput=''
if elf2dmpOutput="$(elf2dmp "${elfFile}" "${dmpFile}" 2>&1)"; then
  Warn "elf2dmp conversion succeeded"
else
  Warn "elf2dmp output: ${elf2dmpOutput}"
  EmitFailure "elf2dmp conversion failed" "${elf2dmpOutput}"
fi

if [[ ! -f "${dmpFile}" ]]; then
  EmitFailure "elf2dmp completed but DMP file not found at ${dmpFile}"
fi

rm -f "${elfFile}"
Warn "cleaned up intermediate ELF file"

typeset dmpSize=''
dmpSize="$(stat -c%s "${dmpFile}" 2>/dev/null)" || dmpSize=0

typeset warnsJson=''
warnsJson="$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

jq -n \
  --arg file "host-crash.dmp" \
  --arg method "elf2dmp" \
  --argjson size "${dmpSize}" \
  --argjson warnings "${warnsJson}" \
  '{ ok: true, dumpFile: $file, method: $method, sizeBytes: $size, warnings: $warnings }'
true
