#!/usr/bin/env bash
set -euxo pipefail; shopt -s inherit_errexit

typeset testDir
testDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "=== BSOD Detector Test Suite ==="

if ! command -v bats &>/dev/null; then
  echo "ERROR: bats-core not installed. Install with: dnf install bats" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not installed." >&2
  exit 1
fi

bats "$testDir/"
true
