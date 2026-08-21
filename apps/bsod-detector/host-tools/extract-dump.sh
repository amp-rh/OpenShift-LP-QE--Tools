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
set -euo pipefail

DISK=""; OUT="/out"; WINROOT="/Windows"
warn() { echo "extract-dump: $*" >&2; }
emit() { # $1=ok(true/false) ; reads $FILES_JSON, $WARN_JSON
  printf '{"ok":%s,"disk":%s,"outputDir":%s,"dumpFiles":%s,"warnings":%s}\n' \
    "$1" "$(jq -Rn --arg v "$DISK" '$v')" "$(jq -Rn --arg v "$OUT" '$v')" \
    "${FILES_JSON:-[]}" "${WARN_JSON:-[]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) DISK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --windows-root) WINROOT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *) warn "unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$DISK" ]] || { warn "--disk is required"; exit 2; }
[[ -f "$DISK" ]] || { warn "disk not found: $DISK"; exit 2; }
mkdir -p "$OUT"

warns=(); found=()

# Locate the Windows partition automatically; -i inspects the OS layout.
# virt-copy-out reads read-only by default.
copy_out() { # $1 = path inside guest (relative to Windows root)
  local src="$WINROOT/$1"
  if virt-ls -a "$DISK" "$src" >/dev/null 2>&1; then
    virt-copy-out -a "$DISK" "$src" "$OUT" 2>>/tmp/err && return 0
  fi
  return 1
}

# MEMORY.DMP (kernel/complete dump)
if copy_out "MEMORY.DMP"; then
  found+=("MEMORY.DMP")
else
  warns+=("MEMORY.DMP not found - dump type may be misconfigured or none written")
fi

# Minidump directory (small dumps, one per crash)
if virt-ls -a "$DISK" "$WINROOT/Minidump" >/dev/null 2>&1; then
  virt-copy-out -a "$DISK" "$WINROOT/Minidump" "$OUT" 2>>/tmp/err || true
  while IFS= read -r f; do found+=("Minidump/$f"); done < <(virt-ls -a "$DISK" "$WINROOT/Minidump" 2>/dev/null | grep -i '\.dmp$' || true)
else
  warns+=("no Minidump directory found")
fi

FILES_JSON="$(printf '%s\n' "${found[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
WARN_JSON="$(printf '%s\n' "${warns[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

if [[ ${#found[@]} -eq 0 ]]; then emit false; exit 1; fi
emit true
