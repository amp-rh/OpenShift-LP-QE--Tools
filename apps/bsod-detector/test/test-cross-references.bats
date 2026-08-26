#!/usr/bin/env bats

load test-helper

@test "every trigger-methods code exists in bugcheck-codes.json" {
  missing=$(python3 -c "
import json
tm = json.load(open('$DATA_DIR/trigger-methods.json'))['codes']
bc = set(json.load(open('$DATA_DIR/bugcheck-codes.json'))['codes'].keys())
bad = [k for k in tm if k not in bc]
print(len(bad))
")
  [ "$missing" -eq 0 ]
}

@test "trigger-methods names match bugcheck-codes names" {
  mismatches=$(python3 -c "
import json
tm = json.load(open('$DATA_DIR/trigger-methods.json'))['codes']
bc = json.load(open('$DATA_DIR/bugcheck-codes.json'))['codes']
bad = []
for code, entry in tm.items():
    if code in bc and entry['name'] != bc[code]['name']:
        bad.append(code)
print(len(bad))
")
  [ "$mismatches" -eq 0 ]
}

@test "event-sources entries have required fields" {
  bad=$(jq '[.events[] | select(.log == null or .eventId == null)] | length' "$DATA_DIR/event-sources.json")
  [ "$bad" -eq 0 ]
}

@test "bugcheck-codes entries all have a name field" {
  bad=$(jq '[.codes | to_entries[] | select(.value.name == null or .value.name == "")] | length' "$DATA_DIR/bugcheck-codes.json")
  [ "$bad" -eq 0 ]
}

@test "host-signals relatedBugCheck codes resolve in bugcheck-codes.json" {
  missing=$(python3 -c "
import json
sig = json.load(open('$DATA_DIR/host-signals.json'))['kernelLogSignals']
bc = set(json.load(open('$DATA_DIR/bugcheck-codes.json'))['codes'].keys())
bad = [s['relatedBugCheck'] for s in sig if s.get('relatedBugCheck') and s['relatedBugCheck'] not in bc]
print(len(bad))
")
  [ "$missing" -eq 0 ]
}

@test "host-signals kernelLogSignals patterns are valid PCRE" {
  while IFS= read -r pat; do
    printf '' | grep -P "$pat" >/dev/null 2>&1 || [ $? -le 1 ]
  done < <(jq -r '.kernelLogSignals[].pattern' "$DATA_DIR/host-signals.json")
}

@test "host-signals hypervEnlightenments entries have name and risk" {
  bad=$(jq '[.hypervEnlightenments[] | select(.name == null or .risk == null)] | length' "$DATA_DIR/host-signals.json")
  [ "$bad" -eq 0 ]
}

@test "chaos-triggers expectedCodes resolve in bugcheck-codes.json" {
  missing=$(python3 -c "
import json
ct = json.load(open('$DATA_DIR/chaos-triggers.json'))['triggers']
bc = set(json.load(open('$DATA_DIR/bugcheck-codes.json'))['codes'].keys())
bad = []
for tid, t in ct.items():
    for code in t.get('expectedCodes', []):
        if code not in bc:
            bad.append(f'{tid}:{code}')
print(len(bad))
")
  [ "$missing" -eq 0 ]
}

@test "chaos-triggers enlightenment-toggle features exist in host-signals.json or domain XML" {
  missing=$(python3 -c "
import json
ct = json.load(open('$DATA_DIR/chaos-triggers.json'))['triggers']
hs = json.load(open('$DATA_DIR/host-signals.json'))
known_names = {e['name'] for e in hs['hypervEnlightenments']}
known_elements = {e.get('element', e['name']) for e in hs['hypervEnlightenments']}
known = known_names | known_elements
bad = []
for tid, t in ct.items():
    for feat in t.get('disableEnlightenments', []):
        if feat not in known:
            bad.append(f'{tid}:{feat}')
print(len(bad))
")
  [ "$missing" -eq 0 ]
}
