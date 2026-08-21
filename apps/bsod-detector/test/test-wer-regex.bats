#!/usr/bin/env bats

load test-helper

# The WER bugcheck regex from collect-guest.ps1 / test-bugcheck-lookup.ps1:
#   'bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)'
# We reimplement it in bash/python to validate the pattern against test vectors.

parse_wer_message() {
  python3 -c "
import re, sys, json

message = sys.argv[1]
pattern = r'bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)'
m = re.search(pattern, message)
if not m:
    json.dump({'code': None, 'params': []}, sys.stdout)
    sys.exit(0)

raw_code = m.group(1)
norm = '0x' + raw_code[2:].upper().zfill(8)
params = [p.strip() for p in m.group(2).split(',')]
json.dump({'code': norm, 'params': params}, sys.stdout)
" "$1"
}

@test "WER regex: standard 0xD1 message" {
  msg="The computer has rebooted from a bugcheck. The bugcheck was: 0x000000d1 (0xdeadbeef00000001, 0x0000000000000002, 0x0000000000000000, 0xfffff80000000003). A dump was saved in: C:\\WINDOWS\\MEMORY.DMP."
  result=$(parse_wer_message "$msg")
  code=$(echo "$result" | jq -r '.code')
  [ "$code" = "0x000000D1" ]
}

@test "WER regex: code with small value 0x3D" {
  msg="The bugcheck was: 0x0000003d (0xfffff80376bc2cc8, 0xfffff80376bc2510, 0x0000000000000000, 0x0000000000000000). A dump."
  result=$(parse_wer_message "$msg")
  code=$(echo "$result" | jq -r '.code')
  [ "$code" = "0x0000003D" ]
}

@test "WER regex: 5-digit code 0x20001" {
  msg="The bugcheck was: 0x00020001 (0x0000000000000032, 0x0000000000000001, 0x0000000000000000, 0x0000000000000000). A dump."
  result=$(parse_wer_message "$msg")
  code=$(echo "$result" | jq -r '.code')
  [ "$code" = "0x00020001" ]
}

@test "WER regex: extracts exactly 4 parameters" {
  msg="The bugcheck was: 0x000000c2 (0x0000000000000007, 0x0000000000000000, 0x0000000000000000, 0xffffcf067cf551a0). A dump."
  result=$(parse_wer_message "$msg")
  count=$(echo "$result" | jq '.params | length')
  [ "$count" -eq 4 ]
}

@test "WER regex: normalizes lowercase to uppercase" {
  msg="The bugcheck was: 0x000000ef (0x0000000000000001, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000). A dump."
  result=$(parse_wer_message "$msg")
  code=$(echo "$result" | jq -r '.code')
  [ "$code" = "0x000000EF" ]
}

@test "WER regex: returns null code on non-matching message" {
  msg="The system was shut down cleanly."
  result=$(parse_wer_message "$msg")
  code=$(echo "$result" | jq -r '.code')
  [ "$code" = "null" ]
}

@test "WER regex: all 19 trigger-methods codes are parseable" {
  python3 -c "
import re, json, sys

with open('$DATA_DIR/trigger-methods.json') as f:
    codes = json.load(f)['codes']

pattern = r'bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)'
errors = []
for code_key in codes:
    lower = '0x' + code_key[2:].lower()
    msg = f'The bugcheck was: {lower} (0xdeadbeef, 0x0, 0x0, 0x0). A dump.'
    m = re.search(pattern, msg)
    if not m:
        errors.append(f'Failed to parse {code_key}')
        continue
    norm = '0x' + m.group(1)[2:].upper().zfill(8)
    if norm != code_key:
        errors.append(f'Expected {code_key}, got {norm}')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
"
}
