#!/usr/bin/env bash
# extract-dump - pull Windows crash dumps out of a guest disk image offline.
#
# Runs INSIDE the bsod-host-tools container (libguestfs). Use when the guest is
# frozen or unbootable: reads the qcow2 read-only and copies MEMORY.DMP and any
# minidumps into an output directory. Emits one JSON object to stdout describing
# what was found (the script contract; diagnostics go to stderr).
#
# Usage:
#   extract-dump --disk /images/bsod-test.qcow2 --out /out [--windows-root /Windows]
#
# Output (stdout JSON):
#   { "ok": true, "disk": "...", "outputDir": "/out",
#     "dumpFiles": ["MEMORY.DMP","Minidump/..."], "warnings": [ ... ] }
set -euxo pipefail; shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null

typeset disk=''
typeset out='/out'
typeset winRoot='/Windows'
function Warn () { echo "extract-dump: $*" >&2; true; }
function Emit () {
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
      sed -n '2,16p' "$0"; exit 0 ;;
    *) Warn "unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "${disk}" ]] || { Warn "--disk is required"; exit 2; }
[[ -f "${disk}" ]] || { Warn "disk not found: ${disk}"; exit 2; }
mkdir -p "${out}"

typeset -a warns=()
typeset -a found=()

# Locate the Windows partition automatically; -i inspects the OS layout.
# virt-copy-out reads read-only by default.
function CopyOut () {
  typeset src="${winRoot}/$1"
  if virt-ls -a "${disk}" "${src}" >/dev/null 2>&1; then
    virt-copy-out -a "${disk}" "${src}" "${out}" 2>>/tmp/err && return 0
  fi
  return 1
}

# MEMORY.DMP (kernel/complete dump)
if CopyOut "MEMORY.DMP"; then
  found+=("MEMORY.DMP")
else
  warns+=("MEMORY.DMP not found - dump type may be misconfigured or none written")
fi

# Minidump directory (small dumps, one per crash)
typeset f=''
if virt-ls -a "${disk}" "${winRoot}/Minidump" >/dev/null 2>&1; then
  virt-copy-out -a "${disk}" "${winRoot}/Minidump" "${out}" 2>>/tmp/err || true
  while IFS= read -r f; do found+=("Minidump/${f}"); done < <(virt-ls -a "${disk}" "${winRoot}/Minidump" 2>/dev/null | sed -n '/\.dmp$/Ip')
else
  warns+=("no Minidump directory found")
fi

typeset filesJson=''
filesJson="$(printf '%s\n' "${found[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
typeset warnJson=''
warnJson="$(printf '%s\n' "${warns[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

if [[ "${#found[@]}" -eq 0 ]]; then Emit false; exit 1; fi
Emit true
true
