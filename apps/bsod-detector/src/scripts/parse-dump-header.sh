#!/usr/bin/env bash
# parse-dump-header - read bug-check code and parameters from a Windows kernel
# crash dump header, then resolve via bugcheck-codes.json.
#
# Works on PAGEDU64 (64-bit full/kernel dump) files. Reads the fixed-offset
# fields from the dump header without needing a Windows debugger.
#
# Usage:
#   parse-dump-header <dump-file> [<dump-file> ...]
#   parse-dump-header --dir <directory>   # all *.DMP files in the directory
#
# Output (stdout JSON):
#   { "ok": true, "dumps": [ { "file": "...", "bugCheckCode": "0x...",
#     "bugCheckName": "...", "parameters": [...], "valid": true } ], "warnings": [] }
#
# Requires: xxd, jq, python3 (for struct unpacking on 64-bit params)
set -euo pipefail
shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null
set -x

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CODES_FILE="$REPO_ROOT/src/data/bugcheck-codes.json"

die() { echo "parse-dump-header: $*" >&2; exit 2; }
warn_list=()

[[ -f "$CODES_FILE" ]] || die "bugcheck-codes.json not found at $CODES_FILE"

# Gather files
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      [[ -d "$2" ]] || die "directory not found: $2"
      while IFS= read -r f; do files+=("$f"); done < <(find "$2" -maxdepth 1 -iname '*.dmp' -type f | sort)
      shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *)
      [[ -f "$1" ]] || die "file not found: $1"
      files+=("$1"); shift ;;
  esac
done

[[ ${#files[@]} -gt 0 ]] || die "no dump files specified"

# PAGEDU64 header layout (64-bit kernel dump):
#   Offset  Size  Field
#   0x00    8     Signature ("PAGEDU64")
#   0x38    4     BugCheckCode (uint32 LE)
#   0x40    8     BugCheckParameter1 (uint64 LE)
#   0x48    8     BugCheckParameter2 (uint64 LE)
#   0x50    8     BugCheckParameter3 (uint64 LE)
#   0x58    8     BugCheckParameter4 (uint64 LE)
PAGEDU64_SIG="5041474544553634"

read_u32_le() { # file offset -> hex string
  python3 -c "
import struct, sys
with open('$1','rb') as f:
    f.seek($2)
    print('0x' + format(struct.unpack('<I', f.read(4))[0], '08X'))
"
}

read_u64_le() { # file offset -> hex string
  python3 -c "
import struct, sys
with open('$1','rb') as f:
    f.seek($2)
    print('0x' + format(struct.unpack('<Q', f.read(8))[0], '016X'))
"
}

results=()
for dump in "${files[@]}"; do
  basename="$(basename "$dump")"

  # Check signature
  sig=$(xxd -l 8 -p "$dump" 2>/dev/null || echo "")
  if [[ "$sig" != "$PAGEDU64_SIG" ]]; then
    warn_list+=("$basename: not a PAGEDU64 dump (sig=$sig), skipped")
    results+=("$(jq -n --arg f "$basename" '{file:$f, bugCheckCode:null, bugCheckName:null, parameters:[], valid:false, error:"not a PAGEDU64 dump"}')")
    continue
  fi

  code=$(read_u32_le "$dump" 0x38)
  p1=$(read_u64_le "$dump" 0x40)
  p2=$(read_u64_le "$dump" 0x48)
  p3=$(read_u64_le "$dump" 0x50)
  p4=$(read_u64_le "$dump" 0x58)

  # Look up name in bugcheck-codes.json
  name=$(jq -r --arg c "$code" '.codes[$c].name // empty' "$CODES_FILE")
  if [[ -z "$name" ]]; then
    warn_list+=("$basename: code $code not in bugcheck-codes.json")
    name="null"
  else
    name="\"$name\""
  fi

  results+=("$(jq -n \
    --arg f "$basename" \
    --arg code "$code" \
    --argjson name "$name" \
    --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" --arg p4 "$p4" \
    '{file:$f, bugCheckCode:$code, bugCheckName:$name, parameters:[$p1,$p2,$p3,$p4], valid:true}')")
done

# Emit single JSON result
dumps_json=$(printf '%s\n' "${results[@]}" | jq -s .)
warns_json=$(printf '%s\n' "${warn_list[@]:-}" | jq -R . | jq -s 'map(select(length>0))')
ok=true
for r in "${results[@]}"; do
  if echo "$r" | jq -e '.valid == false or .bugCheckName == null' >/dev/null 2>&1; then
    ok=false; break
  fi
done

jq -n --argjson ok "$ok" --argjson dumps "$dumps_json" --argjson warns "$warns_json" \
  '{ok:$ok, totalDumps:($dumps|length), dumps:$dumps, warnings:$warns}'
