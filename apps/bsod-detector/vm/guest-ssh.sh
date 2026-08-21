#!/usr/bin/env bash
# guest-ssh.sh - run PowerShell in the test guest over SSH, robustly.
#
# Runs on the HOST. Wraps sshpass + OpenSSH to execute PowerShell in the guest
# using -EncodedCommand (base64/UTF-16LE) so quoting is never an issue, and
# filters out PowerShell's CLIXML/progress noise so stdout is clean.
#
# Config via env (with defaults for the local bsod-test VM):
#   GUEST_IP    (default: auto-detected from libvirt DHCP lease for bsod-test)
#   GUEST_USER  (default: Administrator)
#   GUEST_KEY   (default: <repo>/.ssh/bsod-test if present) - SSH private key
#   GUEST_PASS  (fallback if no key; e.g. export GUEST_PASS=... )
#
# Auth: uses the SSH key when available (no password needed); otherwise falls
# back to GUEST_PASS via sshpass.
#
# Usage:
#   vm/guest-ssh.sh -c 'Get-Date; $env:COMPUTERNAME'     # inline PowerShell
#   vm/guest-ssh.sh -f path/to/script.ps1 [-- -Arg val]  # run a .ps1 file
#   echo '<ps>' | vm/guest-ssh.sh                        # PowerShell on stdin
set -euxo pipefail
shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
GUEST_USER="${GUEST_USER:-Administrator}"
VM_NAME="${VM_NAME:-bsod-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_KEY="${GUEST_KEY:-$SCRIPT_DIR/../.ssh/bsod-test}"

die() { echo "guest-ssh: $*" >&2; exit 1; }

# Resolve IP from the libvirt DHCP lease if not provided.
if [[ -z "${GUEST_IP:-}" ]]; then
  GUEST_IP="$(virsh -q domifaddr "$VM_NAME" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)"
  [[ -z "$GUEST_IP" ]] && GUEST_IP="$(virsh -q net-dhcp-leases default 2>/dev/null \
      | awk -v m="$(virsh -q domiflist "$VM_NAME" | awk 'NR==1{print $5}')" '$3==m{print $5}' | cut -d/ -f1)"
fi
[[ -n "$GUEST_IP" ]] || die "could not resolve guest IP (set GUEST_IP)"

# ServerAlive* ensures a session that dies mid-command (e.g. the guest
# bugchecking during a crash trigger) is torn down within ~15s instead of hanging
# indefinitely on a half-open TCP connection.
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o ConnectTimeout=15 -o LogLevel=ERROR
         -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

# Prefer key auth; fall back to password via sshpass. SSH_ and SCP_ are arrays
# holding the command prefix so the rest of the script is auth-agnostic.
if [[ -f "$GUEST_KEY" ]]; then
  SSHOPTS+=(-i "$GUEST_KEY" -o IdentitiesOnly=yes)
  SSH_=(ssh);  SCP_=(scp)
elif [[ -n "${GUEST_PASS:-}" ]]; then
  export SSHPASS="$GUEST_PASS"
  SSH_=(sshpass -e ssh);  SCP_=(sshpass -e scp)
else
  die "no auth: set GUEST_KEY to an SSH key ($GUEST_KEY) or GUEST_PASS"
fi

# Gather the PowerShell payload and any trailing args.
PS=""; ARGS=""
case "${1:-}" in
  -c) PS="$2"; shift 2 ;;
  -f) FILE="$2"; shift 2
      [[ -f "$FILE" ]] || die "no such file: $FILE"
      PS="$(cat "$FILE")"
      [[ "${1:-}" == "--" ]] && { shift; ARGS="$*"; } ;;
  "") PS="$(cat)" ;;                # stdin
  *)  die "usage: -c <ps> | -f <file> [-- args] | (stdin)" ;;
esac

# If args were passed with -f, append a param splat call is overkill; instead we
# dot-source the script body then rely on its params being set via $ARGS appended
# as a trailing command line. Simplest robust approach: wrap file + args.
PAYLOAD="$PS"
[[ -n "$ARGS" ]] && PAYLOAD="& { $PS } $ARGS"

# Windows caps the command line (~8KB) and -EncodedCommand inflates size ~2.7x
# (UTF-16 + base64). For anything non-trivial, scp the script and run from disk;
# only use -EncodedCommand for short inline commands.
B64="$(printf '%s' "$PAYLOAD" | iconv -t UTF-16LE | base64 -w0)"
if [[ ${#B64} -lt 6000 ]]; then
  "${SSH_[@]}" "${SSHOPTS[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "powershell -NoProfile -NonInteractive -EncodedCommand $B64" 2>&1 \
    | grep -avE '^#< CLIXML|<Objs |Permanently added'
else
  tmp="$(mktemp --suffix=.ps1)"; printf '%s' "$PS" > "$tmp"
  remote="C:/Windows/Temp/gssh-$$.ps1"
  "${SCP_[@]}" "${SSHOPTS[@]}" "$tmp" "${GUEST_USER}@${GUEST_IP}:${remote}" 2>&1 \
    | grep -avE 'Permanently added' || true
  rm -f "$tmp"
  rwin="${remote//\//\\}"
  "${SSH_[@]}" "${SSHOPTS[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $rwin $ARGS" 2>&1 \
    | grep -avE '^#< CLIXML|<Objs |Permanently added'
  "${SSH_[@]}" "${SSHOPTS[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "powershell -NoProfile -Command \"Remove-Item '$rwin' -Force -EA SilentlyContinue\"" >/dev/null 2>&1 || true
fi
