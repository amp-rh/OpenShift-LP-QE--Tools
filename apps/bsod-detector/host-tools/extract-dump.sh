#!/usr/bin/env bash
# extract-dump - pull Windows crash dumps out of a guest disk image offline.
#
# Runs INSIDE the bsod-host-tools container (libguestfs). Use when the guest is
# frozen or unbootable: reads the qcow2 read-only and copies MEMORY.DMP and any
# minidumps into an output directory. Emits one JSON object to stdout describing
# what was found (the script contract; diagnostics go to stderr).
#
# Usage:
#   extract-dump --disk <imgFile> [--out <outDir>] [--windows-root <winRootDir>]
#
# Parameters:
#   --disk <imgFile>           Path to the guest disk image (qcow2) [required]
#   --out <outDir>             Output directory for recovered dumps (default: /out)
#   --windows-root <winRootDir> Windows root path in the disk (default: /Windows)
#
# Examples:
#   extract-dump --disk /images/bsod-test.qcow2
#   extract-dump --disk /images/bsod-test.qcow2 --out /out
#   extract-dump --disk /images/bsod-test.qcow2 --out /out --windows-root /Windows
#
# Output (stdout JSON):
#   { "ok": true, "disk": "...", "outputDir": "/out",
#     "dumpFiles": ["MEMORY.DMP","Minidump/..."], "warnings": [ ... ] }
####
set -euxo pipefail; shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null

typeset disk=''
typeset out='/out'
typeset winRoot='/Windows'
# warn — print a diagnostic message to stderr.
function warn () { echo "extract-dump: $*" >&2; true; }
# emit — write the final JSON result object to stdout.
function emit () {
  printf '{"ok":%s,"disk":%s,"outputDir":%s,"dumpFiles":%s,"warnings":%s}\n' \
    "$1" "$(jq -Rn --arg v "${disk}" '$v')" "$(jq -Rn --arg v "${out}" '$v')" \
    "${filesJson:-[]}" "${warnJson:-[]}"
  true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) disk="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --windows-root) winRoot="$2"; shift 2 ;;
    -h|--help)
      sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    --)
      shift
      break
      ;;
    *) warn "unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "${disk}" ]] || { warn "--disk is required"; exit 2; }
[[ -f "${disk}" ]] || { warn "disk not found: ${disk}"; exit 2; }
mkdir -p "${out}"

typeset -a warns=()
typeset -a found=()

# Locate the Windows partition automatically; -i inspects the OS layout.
# virt-copy-out reads read-only by default.
# copy_out — copy a file from the guest disk image to the output directory.
#   Returns: 0 = success, 1 = not found (expected), 2 = copy failed (unexpected).
function copy_out () {
  typeset src="${winRoot}/$1"
  typeset dst="$2"
  typeset rc=0

  virt-copy-out -a "${disk}" "${src}" "${dst}" 2>/tmp/err || rc=$?

  typeset err_content=""
  [[ -s /tmp/err ]] && err_content=$(</tmp/err)

  if [[ $rc -ne 0 ]]; then
    if [[ "${err_content}" == *"No such file"* ]] || \
       [[ "${err_content}" == *"not found"* ]] || \
       [[ "${err_content}" == *"does not exist"* ]]; then
      return 1  # not found (expected)
    else
      warn "virt-copy-out failed for ${src} (rc=${rc}): ${err_content}"
      return 2  # copy failed (unexpected)
    fi
  fi

  # Success — but still capture any warnings
  if [[ -n "${err_content}" ]]; then
    warns+=("virt-copy-out warning for ${src}: ${err_content}")
  fi
  return 0
}

# MEMORY.DMP (kernel/complete dump)
typeset copy_rc=0
copy_out "MEMORY.DMP" "${out}" || copy_rc=$?
if [[ ${copy_rc} -eq 0 ]]; then
  found+=("MEMORY.DMP")
elif [[ ${copy_rc} -eq 1 ]]; then
  warns+=("MEMORY.DMP not found - dump type may be misconfigured or none written")
else
  warns+=("MEMORY.DMP copy failed (rc=${copy_rc})")
fi

# Minidump directory (small dumps, one per crash)
typeset f=''
if virt-ls -a "${disk}" "${winRoot}/Minidump" >/dev/null 2>&1; then
  virt-copy-out -a "${disk}" "${winRoot}/Minidump" "${out}" 2>>/tmp/err || true
  while IFS= read -r f; do found+=("Minidump/${f}"); done < <(virt-ls -a "${disk}" "${winRoot}/Minidump" 2>/dev/null | sed -n '/\.dmp$/Ip')
else
  warns+=("no Minidump directory found")
fi

# Event log files (.evtx) for offline crash-event parsing
typeset evtxDir="${winRoot}/System32/winevt/Logs"
typeset -a evtxTargets=("System.evtx" "Application.evtx")
mkdir -p "${out}/winevt" 2>/dev/null || true
for evtxName in "${evtxTargets[@]}"; do
  copy_rc=0
  copy_out "System32/winevt/Logs/${evtxName}" "${out}" || copy_rc=$?
  if [[ ${copy_rc} -eq 0 ]]; then
    # virt-copy-out preserves the path structure; move to our flat winevt/ dir
    typeset srcEvtx="${out}/${evtxName}"
    if [[ -f "${srcEvtx}" ]]; then
      if mv "${srcEvtx}" "${out}/winevt/${evtxName}" 2>/dev/null; then
        found+=("winevt/${evtxName}")
      else
        warns+=("Failed to move ${srcEvtx} to ${out}/winevt/${evtxName}")
      fi
    fi
  elif [[ ${copy_rc} -eq 1 ]]; then
    warns+=("${evtxName} not found at ${evtxDir}")
  else
    warns+=("${evtxName} copy failed (rc=${copy_rc})")
  fi
done

typeset filesJson=''
filesJson="$(printf '%s\n' "${found[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"
typeset warnJson=''
warnJson="$(printf '%s\n' "${warns[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"

if [[ "${#found[@]}" -eq 0 ]]; then emit false; exit 1; fi
emit true
true
