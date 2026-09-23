#!/usr/bin/env bats

load test-helper

setup() {
    # Ensure we're in the bsod-detector directory
    cd "$BATS_TEST_DIRNAME/.." || exit 1
}

@test "run.sh --help prints usage and exits 0" {
    run bash host-tools/run.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"usage:"* ]]
}

@test "run.sh with no args exits non-zero" {
    run bash host-tools/run.sh
    [ "$status" -ne 0 ]
}

@test "run.sh rejects unknown flags" {
    run bash host-tools/run.sh --invalid-flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown arg"* ]]
}
