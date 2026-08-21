#!/usr/bin/env bash
# collect-host-signals - capture Linux/KVM HOST-side crash-correlation signals
# that are invisible from inside the Windows guest.
#
# Runs on: the Linux HOST (libvirt/KVM). The HYPERVISOR_ERROR root
# cause (Intel split-lock #AC during the Hyper-V enlightened TLB-flush hypercall)
# only shows up in the host kernel log and the guest's <hyperv> domain config,
# never in the guest dump. This script greps the kernel log for the patterns in
# data/host-signals.json and extracts the VM's Hyper-V enlightenment features
# from the libvirt domain XML, then emits one JSON object to stdout (the script
# contract; diagnostics go to stderr).
#
# Usage:
#   collect-host-signals.sh --vm <name> [--since "1 hour ago"] [--dmesg]
#
#   --vm     libvirt domain name (default: $VM_NAME or bsod-test)
#   --since  journalctl --since window for kernel logs (default: "2 hours ago")
#   --dmesg  read `dmesg` instead of `journalctl -k` (use when journald has no
#            kernel log or you are parsing a captured file via --log-file)
#   --log-file <path>  parse kernel log from a file instead of the live system
#
# Reads: data/host-signals.json (patterns + hyperv feature list; source of truth).
#
# Output (stdout JSON):
#   { "ok": true, "vm": "...", "collectedAt": "...",
#     "kernelSignals": [ { "id","matches":[{"raw","kvmThread","trapAddress",
#                          "addressSpace"}],"count","relatedBugCheck" } ],
#     "splitLockDetected": true|false,
#     "hyperv": { "features": [ {"name","state","risk","present"} ],
#                 "mitigationApplied": true|false },
#     "assessment": [ "..." ], "warnings": [ ... ] }
set -euo pipefail
shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null
set -x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SIGNALS_FILE="$REPO_ROOT/src/data/host-signals.json"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
VM_NAME="${VM_NAME:-bsod-test}"
SINCE="2 hours ago"
USE_DMESG=0
LOG_FILE=""

warn() { echo "collect-host-signals: $*" >&2; }
die()  { warn "$*"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

have jq || die "jq not found"
[[ -f "$SIGNALS_FILE" ]] || die "host-signals.json not found at $SIGNALS_FILE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_NAME="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --dmesg) USE_DMESG=1; shift ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

warnings=()

# ---------------------------------------------------------------------------
# 1. Obtain the kernel log text.
# ---------------------------------------------------------------------------
kernel_log=""
if [[ -n "$LOG_FILE" ]]; then
  [[ -f "$LOG_FILE" ]] || die "log file not found: $LOG_FILE"
  kernel_log="$(cat "$LOG_FILE")"
elif [[ "$USE_DMESG" -eq 1 ]]; then
  if have dmesg; then
    kernel_log="$(dmesg 2>/dev/null || true)"
    [[ -n "$kernel_log" ]] || warnings+=("dmesg returned no output (may need root)")
  else
    warnings+=("dmesg not available")
  fi
else
  if have journalctl; then
    kernel_log="$(journalctl -k --since "$SINCE" --no-pager 2>/dev/null || true)"
    [[ -n "$kernel_log" ]] || warnings+=("journalctl -k returned no output for window '$SINCE' (may need root or --dmesg)")
  else
    warnings+=("journalctl not available; try --dmesg")
  fi
fi

# ---------------------------------------------------------------------------
# 2. Match each kernel-log signal pattern from the source-of-truth file.
# ---------------------------------------------------------------------------
signal_results="[]"
split_lock=false
while IFS= read -r sig; do
  id="$(echo "$sig" | jq -r '.id')"
  pattern="$(echo "$sig" | jq -r '.pattern')"
  related="$(echo "$sig" | jq -r '.relatedBugCheck // empty')"

  matches="[]"
  count=0
  if [[ -n "$kernel_log" ]]; then
    # grep -P for the PCRE pattern; collect raw matching lines.
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # Extract KVM thread + trap address if the split-lock capture groups apply.
      kvm_thread="$(echo "$line" | grep -oP 'CPU\s+\d+/KVM/\d+' | head -n1 || true)"
      trap_addr="$(echo "$line" | grep -oP 'address:\s*\K0x[0-9a-fA-F]+' | head -n1 || true)"
      addr_space="unknown"
      if [[ -n "$trap_addr" ]]; then
        # Windows kernel space = 0xfffff8xx...; anything else treated as user/other.
        if [[ "$trap_addr" == 0xfffff8* ]]; then addr_space="kernel"; else addr_space="user"; fi
      fi
      matches="$(echo "$matches" | jq \
        --arg raw "$line" --arg t "$kvm_thread" --arg a "$trap_addr" --arg s "$addr_space" \
        '. + [{raw:$raw, kvmThread:(if $t=="" then null else $t end), trapAddress:(if $a=="" then null else $a end), addressSpace:$s}]')"
      count=$((count+1))
    done < <(grep -P "$pattern" <<<"$kernel_log" 2>/dev/null || true)
  fi

  [[ "$id" == "split-lock-trap" && "$count" -gt 0 ]] && split_lock=true

  signal_results="$(echo "$signal_results" | jq \
    --arg id "$id" --argjson matches "$matches" --argjson count "$count" \
    --arg related "$related" \
    '. + [{id:$id, count:$count, relatedBugCheck:(if $related=="" then null else $related end), matches:$matches}]')"
done < <(jq -c '.kernelLogSignals[]' "$SIGNALS_FILE")

# ---------------------------------------------------------------------------
# 3. Extract the guest's Hyper-V enlightenment features from the domain XML.
# ---------------------------------------------------------------------------
hyperv_features="[]"
mitigation_applied=false
hyperv_inspected=false
domain_xml=""
if have virsh; then
  domain_xml="$(virsh dumpxml "$VM_NAME" 2>/dev/null || true)"
  [[ -n "$domain_xml" ]] || warnings+=("could not read domain XML for '$VM_NAME' (is it defined?)")
else
  warnings+=("virsh not available; skipping Hyper-V feature extraction")
fi

if [[ -n "$domain_xml" ]]; then
  hyperv_inspected=true
  while IFS= read -r feat; do
    name="$(echo "$feat" | jq -r '.name')"
    risk="$(echo "$feat" | jq -r '.risk')"
    # The libvirt XML element name may differ from the friendly name
    # (e.g. synictimer -> <stimer>); fall back to name when .element absent.
    elem="$(echo "$feat" | jq -r '.element // .name')"
    # Look for <element state='on'/> inside the <hyperv> block.
    state="absent"; present=false
    if grep -qP "<$elem\b[^>]*state=['\"]on['\"]" <<<"$domain_xml"; then
      state="on"; present=true
    elif grep -qP "<$elem\b[^>]*state=['\"]off['\"]" <<<"$domain_xml"; then
      state="off"; present=true
    fi
    hyperv_features="$(echo "$hyperv_features" | jq \
      --arg n "$name" --arg s "$state" --arg r "$risk" --argjson p "$present" \
      '. + [{name:$n, state:$s, risk:$r, present:$p}]')"
  done < <(jq -c '.hypervEnlightenments[]' "$SIGNALS_FILE")

  # Mitigation is "applied" when both high-risk enlightenments are off/absent.
  tlb_state="$(echo "$hyperv_features" | jq -r '.[] | select(.name=="tlbflush") | .state')"
  ipi_state="$(echo "$hyperv_features"  | jq -r '.[] | select(.name=="ipi") | .state')"
  if [[ "$tlb_state" != "on" && "$ipi_state" != "on" ]]; then mitigation_applied=true; fi
fi

# ---------------------------------------------------------------------------
# 4. Assessment (facts, not verdicts): correlate split-lock + risky enlightenments.
# ---------------------------------------------------------------------------
assessment=()
if [[ "$split_lock" == true ]]; then
  kernel_hits="$(echo "$signal_results" | jq '[.[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="kernel")] | length')"
  assessment+=("Split-lock #AC traps present in host kernel log ($kernel_hits kernel-space). Consistent with HYPERVISOR_ERROR (0x20001) mechanism.")
  if [[ "$hyperv_inspected" == false ]]; then
    assessment+=("Could not read the guest Hyper-V config; unable to correlate the traps with tlbflush/ipi enlightenments.")
  elif [[ "$mitigation_applied" == false ]]; then
    assessment+=("Hyper-V tlbflush/ipi enlightenments are enabled AND split-lock traps observed: matches the unmitigated HYPERVISOR_ERROR configuration.")
  else
    assessment+=("Split-lock traps observed but tlbflush/ipi already off; traps may originate outside the enlightened TLB-flush path.")
  fi
else
  assessment+=("No split-lock #AC traps found in the examined kernel-log window.")
fi
if [[ "$hyperv_inspected" == true && "$mitigation_applied" == true ]]; then
  assessment+=("Mitigation appears applied: Hyper-V tlbflush and ipi are not enabled.")
fi

# ---------------------------------------------------------------------------
# 5. Emit the single JSON result.
# ---------------------------------------------------------------------------
assess_json="$(printf '%s\n' "${assessment[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
warns_json="$(printf '%s\n' "${warnings[@]:-}"   | jq -R . | jq -s 'map(select(length>0))')"

jq -n \
  --arg vm "$VM_NAME" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson signals "$signal_results" \
  --argjson splitlock "$split_lock" \
  --argjson features "$hyperv_features" \
  --argjson mitigation "$mitigation_applied" \
  --argjson assessment "$assess_json" \
  --argjson warnings "$warns_json" \
  '{ok:true, vm:$vm, collectedAt:$at,
    kernelSignals:$signals, splitLockDetected:$splitlock,
    hyperv:{features:$features, mitigationApplied:$mitigation},
    assessment:$assessment, warnings:$warnings}'
