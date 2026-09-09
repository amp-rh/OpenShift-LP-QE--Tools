#!/usr/bin/env bash
set -euxo pipefail; shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

DATA_DIR="$REPO_ROOT/src/data"
export DATA_DIR

# data/ is split by staging side: guest-staged tables in data/guest/, host-only
# tables in data/host/, and tables both sides need (bugcheck-codes) at the root.
DATA_GUEST_DIR="$DATA_DIR/guest"
export DATA_GUEST_DIR

DATA_HOST_DIR="$DATA_DIR/host"
export DATA_HOST_DIR

TESTS_DIR="$REPO_ROOT/test"
export TESTS_DIR

function SetupTemp () {
  BATS_TMPDIR="$(mktemp -d)"
  export BATS_TMPDIR
  true
}

function TeardownTemp () {
  [[ -d "${BATS_TMPDIR:-}" ]] && rm -rf "$BATS_TMPDIR"
  true
}
