#!/usr/bin/env bats

load test-helper

@test "host-signals related bugcheck codes resolve in bugcheck-codes.json" {
  missing=$(python3 -c "
import json
signals = json.load(open('$DATA_DIR/host-signals.json'))['kernelLogSignals']
codes = set(json.load(open('$DATA_DIR/bugcheck-codes.json'))['codes'])
bad = [s['relatedBugCheck'] for s in signals
       if s.get('relatedBugCheck') and s['relatedBugCheck'] not in codes]
print(len(bad))
")
  [ "$missing" -eq 0 ]
}

@test "host-signals patterns and enlightenment entries are usable" {
  while IFS= read -r pattern; do
    printf '' | grep -P "$pattern" >/dev/null 2>&1 || [ "$?" -le 1 ]
  done < <(jq -r '.kernelLogSignals[].pattern' "$DATA_DIR/host-signals.json")

  bad=$(jq '[.hypervEnlightenments[] |
    select(.name == null or .element == null or .risk == null)] | length' "$DATA_DIR/host-signals.json")
  [ "$bad" -eq 0 ]
}
