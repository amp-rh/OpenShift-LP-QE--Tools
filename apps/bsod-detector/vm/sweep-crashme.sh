#!/usr/bin/env bash
set -euxo pipefail
shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI=qemu:///system
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

CODES=(
  "0x0000000A 0x0 0x0 0x0 0x0"
  "0x00000019 0x3 0x0 0x0 0x0"
  "0x0000001A 0x3F 0xF4EC 0x45C23B3D 0xEBC0C2B3"
  "0x0000001E 0x0 0x0 0x0 0x0"
  "0x0000003D 0xfffff80376bc2cc8 0xfffff80376bc2510 0x0 0x0"
  "0x0000007A 0xffff908313b69b40 0xC0000185 0x707AE860 0xffff8027d77688e8"
  "0x0000007B 0x0 0x0 0x0 0x0"
  "0x0000007E 0x0 0x0 0x0 0x0"
  "0x00000080 0x0 0x0 0x0 0x0"
  "0x0000009F 0x0 0x0 0x0 0x0"
  "0x000000C1 0x0 0x0 0x0 0x0"
  "0x000000C2 0x0 0x0 0x0 0x0"
  "0x000000F7 0x0 0x0 0x0 0x0"
  "0x00000109 0xA3A007E720C9B519 0x0 0x5229358D108F9F1A 0x101"
  "0x00000124 0x0 0x0 0x0 0x0"
  "0x00000133 0x0 0x0 0x0 0x0"
  "0x00000135 0xC0000006 0xFFFFF906CD8C4F80 0xFFFFF8030FA98A90 0xFFFFCC8D699B5920"
  "0x00000154 0xFFFF800A275D0000 0xFFFFB68B2D598F60 0x2 0x0"
  "0x00020001 0x32 0x1 0x0 0x0"
)

wait_ssh() {
  local max="${1:-30}"
  for _i in $(seq 1 "$max"); do
    ./vm/guest-ssh.sh -c '"up"' 2>/dev/null | grep -q up && return 0
    sleep 8
  done
  return 1
}

collect_result() {
  local code_hex="$1"
  local sweep_dir="output/sweep-${code_hex}"
  mkdir -p "$sweep_dir"

  local json
  json=$(./vm/guest-ssh.sh -c "& C:\\bsod-detector\\scripts\\collect-guest.ps1 -OutputDir C:\\bsod-detector\\output\\sweep-${code_hex}" 2>&1) || true
  if [[ -n "$json" ]]; then
    echo "$json" > "${sweep_dir}/collect-guest.json"
    echo "$json"
  else
    echo '{"ok":false,"warnings":["collect-guest.ps1 produced no output"]}' > "${sweep_dir}/collect-guest.json"
    echo "EMPTY"
  fi
}

echo "=== CRASHME SWEEP: ${#CODES[@]} codes ==="
echo ""

for entry in "${CODES[@]}"; do
  read -r code p1 p2 p3 p4 <<< "$entry"
  code_upper=$(echo "$code" | tr '[:lower:]' '[:upper:]' | sed 's/^0X/0x/')

  echo "--- [$code_upper] REVERT ---"
  virsh snapshot-revert bsod-test crashme-installed 2>&1
  virsh start bsod-test 2>&1 || true

  echo "[$code_upper] Waiting for SSH..."
  if ! wait_ssh 30; then
    echo "[$code_upper] FAIL: SSH never came up after revert"
    mkdir -p "output/sweep-${code_upper}"
    echo '{"ok":false,"warnings":["SSH never came up after snapshot revert"]}' > "output/sweep-${code_upper}/collect-guest.json"
    continue
  fi

  echo "[$code_upper] Starting CrashMe driver..."
  sc_out=$(./vm/guest-ssh.sh -c 'sc.exe start CrashMe' 2>&1) || true
  if echo "$sc_out" | grep -qi "RUNNING\|START_PENDING"; then
    echo "[$code_upper] Driver running"
  else
    echo "[$code_upper] WARNING: sc start output: $sc_out"
  fi

  echo "[$code_upper] Triggering BugCheck $code_upper $p1 $p2 $p3 $p4"
  ./vm/guest-ssh.sh -c "C:\\Tools\\crashme-ctl.exe $code $p1 $p2 $p3 $p4" 2>&1 || true

  echo "[$code_upper] Waiting for reboot (~45s)..."
  sleep 45

  echo "[$code_upper] Waiting for SSH after crash..."
  if ! wait_ssh 40; then
    echo "[$code_upper] SSH not up after 320s, trying virsh reset..."
    virsh reset bsod-test 2>&1 || true
    sleep 30
    if ! wait_ssh 20; then
      echo "[$code_upper] FAIL: VM unresponsive after reset"
      mkdir -p "output/sweep-${code_upper}"
      echo '{"ok":false,"warnings":["VM unresponsive after BSOD + reset"]}' > "output/sweep-${code_upper}/collect-guest.json"
      continue
    fi
  fi

  echo "[$code_upper] Collecting evidence..."
  result=$(collect_result "$code_upper")
  observed=$(echo "$result" | grep -oP '"bugCheckCode"\s*:\s*"[^"]*"' | head -1 | grep -oP '0x[0-9a-fA-F]+')
  dump=$(echo "$result" | grep -oP '"dumpFiles"\s*:\s*\[[^\]]*\]' | head -1)
  echo "[$code_upper] Observed: ${observed:-NONE} Dumps: ${dump:-NONE}"
  echo ""
done

echo "=== SWEEP COMPLETE ==="
