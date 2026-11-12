#!/usr/bin/env bats

load test-helper

@test "active data JSON files parse" {
  for file in "$DATA_DIR"/*.json; do
    run python3 -c "import json; json.load(open('$file'))"
    [ "$status" -eq 0 ]
  done
}

@test "bugcheck codes have names and descriptions" {
  bad=$(jq '[.codes | to_entries[] |
    select(.value.name == null or .value.name == "" or
           .value.description == null or .value.description == "")] | length' \
    "$DATA_DIR/bugcheck-codes.json")
  [ "$bad" -eq 0 ]
}

@test "crash-control includes recommended dump settings" {
  run jq -e '.recommended.values.CrashDumpEnabled == 7 and
    .recommended.values.AutoReboot == 0 and .pageFile.path != null' \
    "$DATA_DIR/crash-control.json"
  [ "$status" -eq 0 ]
}

@test "host-signals includes kernel patterns and named enlightenments" {
  run jq -e '(.kernelLogSignals | length > 0) and
    all(.kernelLogSignals[]; (.id | length > 0) and (.pattern | length > 0)) and
    all(.hypervEnlightenments[]; (.name | length > 0) and (.risk | length > 0))' \
    "$DATA_DIR/host-signals.json"
  [ "$status" -eq 0 ]
}
