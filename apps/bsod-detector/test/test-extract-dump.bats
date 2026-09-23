#!/usr/bin/env bats

load test-helper

setup() {
    # Ensure we're in the bsod-detector directory
    cd "$BATS_TEST_DIRNAME/.." || exit 1
}

@test "extract-dump.sh --help prints usage and exits 0" {
    run bash host-tools/extract-dump.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"usage:"* ]]
}

@test "extract-dump.sh with no args exits non-zero" {
    run bash host-tools/extract-dump.sh
    [ "$status" -ne 0 ]
}

@test "extract-dump.sh with nonexistent disk file fails" {
    run bash host-tools/extract-dump.sh --disk /nonexistent/disk.img --out /tmp/bsod-test-out
    [ "$status" -ne 0 ]
}

@test "extract-dump.sh rejects unknown flags" {
    run bash host-tools/extract-dump.sh --invalid-flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown arg"* ]]
}

@test "extract-dump.sh handles -- separator" {
    run bash host-tools/extract-dump.sh -- --help
    # Should not fail with "unknown arg: --"
    [[ "$output" != *"unknown arg: --"* ]]
}

@test "extract-dump.sh --disk without value exits non-zero" {
    run bash host-tools/extract-dump.sh --disk
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a value"* ]]
}

@test "extract-dump.sh --out without value exits non-zero" {
    run bash host-tools/extract-dump.sh --out
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a value"* ]]
}

@test "extract-dump.sh --windows-root without value exits non-zero" {
    run bash host-tools/extract-dump.sh --windows-root
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a value"* ]]
}
