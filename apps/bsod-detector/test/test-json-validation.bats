#!/usr/bin/env bats

load test-helper

@test "all data/*.json files are valid JSON" {
  for f in "$DATA_DIR"/*.json; do
    run python3 -c "import json; json.load(open('$f'))"
    [ "$status" -eq 0 ]
  done
}

@test "trigger-methods.json has required top-level keys" {
  run jq -e '.codes and ._comment' "$DATA_DIR/trigger-methods.json"
  [ "$status" -eq 0 ]
}

@test "bugcheck-codes.json has codes object" {
  run jq -e '.codes | type == "object"' "$DATA_DIR/bugcheck-codes.json"
  [ "$status" -eq 0 ]
}

@test "crash-control.json has recommended key" {
  run jq -e '.recommended' "$DATA_DIR/crash-control.json"
  [ "$status" -eq 0 ]
}

@test "event-sources.json has events array" {
  run jq -e '.events | type == "array"' "$DATA_DIR/event-sources.json"
  [ "$status" -eq 0 ]
}

@test "trigger-methods.json has exactly 19 codes" {
  count=$(jq '.codes | length' "$DATA_DIR/trigger-methods.json")
  [ "$count" -eq 19 ]
}

@test "every trigger-methods code has verified: true" {
  unverified=$(jq '[.codes[] | select(.verified != true)] | length' "$DATA_DIR/trigger-methods.json")
  [ "$unverified" -eq 0 ]
}

@test "every trigger-methods code has exactly 4 parameters" {
  bad=$(jq '[.codes[] | select(.parameters | length != 4)] | length' "$DATA_DIR/trigger-methods.json")
  [ "$bad" -eq 0 ]
}

@test "every trigger-methods code has method kebugcheckex" {
  bad=$(jq '[.codes[] | select(.method != "kebugcheckex")] | length' "$DATA_DIR/trigger-methods.json")
  [ "$bad" -eq 0 ]
}
