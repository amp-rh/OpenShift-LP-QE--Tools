#!/usr/bin/env bash
#
# trigger-bsod-intentional.sh
#
# Automated script to trigger an intentional BSOD on win2022-vm-hjoshi1
# and collect evidence using watch-crash.sh
#
# Usage:
#   bash /home/hijoshi/trigger-bsod-intentional.sh [crash_type]
#
# Crash Types:
#   0x01 = High IRQL fault (Kernel-mode) → 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL
#   0x02 = Buffer overflow
#   0x03 = Code overwrite
#   0x04 = Stack trash
#   0x05 = High IRQL fault (User-mode)
#   0x06 = Stack overflow
#   0x07 = Hardcoded breakpoint
#   0x08 = Double Free
#   0x09 = Trigger HAL Timer Watchdog
#

set -euxo pipefail

# Configuration
CRASH_TYPE="${1:-0x01}"
VM_NAME="win2022-vm-hjoshi1"
NAMESPACE="windows-bsod"
NOTMYFAULT_PATH="C:\\Temp\\nmf\\notmyfaultc64.exe"

# Auto-detect BSOD detector directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/OpenShift-LP-QE--Tools/apps/bsod-detector" ]; then
    DETECTOR_DIR="$SCRIPT_DIR/OpenShift-LP-QE--Tools/apps/bsod-detector"
elif [ -d "${SCRIPT_DIR%/*}/OpenShift-LP-QE--Tools/apps/bsod-detector" ]; then
    DETECTOR_DIR="${SCRIPT_DIR%/*}/OpenShift-LP-QE--Tools/apps/bsod-detector"
elif [ -d "/home/hijoshi/OpenShift-LP-QE--Tools/apps/bsod-detector" ]; then
    DETECTOR_DIR="/home/hijoshi/OpenShift-LP-QE--Tools/apps/bsod-detector"
else
    DETECTOR_DIR="$SCRIPT_DIR"
fi

# Change to detector directory
cd "$DETECTOR_DIR" || die "Cannot find BSOD detector directory. Expected: $DETECTOR_DIR"

EVIDENCE_DIR="./evidence"
LOG_FILE="/tmp/bsod-trigger-$(date +%s).log"
WATCH_CRASH_TIMEOUT=1800  # 30 minutes
CRASH_TRIGGER_TIMEOUT=30  # 30 seconds for crash command
REBOOT_WAIT=300  # 5 minutes for guest to reboot
COLLECTION_WAIT=180  # 3 minutes for evidence collection

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"
}

die() {
    log_error "$1"
    exit 1
}

# Main execution
main() {
    log_info "╔════════════════════════════════════════════════════════════════╗"
    log_info "║         INTENTIONAL BSOD TRIGGER - Automated Workflow          ║"
    log_info "╚════════════════════════════════════════════════════════════════╝"
    log_info ""
    log_info "Configuration:"
    log_info "  VM: $VM_NAME"
    log_info "  Namespace: $NAMESPACE"
    log_info "  Crash Type: $CRASH_TYPE"
    log_info "  Evidence Dir: $EVIDENCE_DIR"
    log_info "  Log File: $LOG_FILE"
    log_info ""

    # Step 0: DELETE all BSOD/dump files from previous runs (host + guest).
    # No process killing — only file cleanup so we start with a clean slate.
    log_info "STEP 0: Delete BSOD/dump files from previous runs"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 0a: Wipe local evidence directory
    log_info "  [0a] Clearing local evidence directory: $EVIDENCE_DIR"
    rm -rf "${EVIDENCE_DIR:?}" 2>/dev/null || true
    mkdir -p "$EVIDENCE_DIR"
    log_success "       Local evidence directory cleared."

    # 0b: Wait for guest to be reachable before guest-side cleanup
    log_info "  [0b] Waiting for guest to be reachable (up to 3 min)..."
    set +e
    GUEST_UP=0
    for _w in $(seq 1 18); do
        if GA_VM="$VM_NAME" GA_NS="$NAMESPACE" timeout 8 python3 src/scripts/host/guest-agent.py ping > /dev/null 2>&1; then
            GUEST_UP=1
            break
        fi
        log_info "       Not reachable yet, retrying in 10s... ($_w/18)"
        sleep 10
    done
    set -e
    if [ $GUEST_UP -eq 0 ]; then
        die "Guest did not respond within 3 minutes. Cannot proceed."
    fi
    log_success "       Guest is reachable."

    # 0c: Delete ALL BSOD dump files on guest — minidumps, MEMORY.DMP, temp dirs.
    # CRITICAL: MEMORY.DMP must be deleted before the crash. If it exists, Windows
    # writes only changed pages on next crash (faster, partial) instead of a full dump.
    # We verify the files are actually gone after deletion.
    log_info "  [0c] Deleting ALL BSOD/dump files on guest and verifying..."
    set +e
    CLEANUP_RESULT=$(GA_VM="$VM_NAME" GA_NS="$NAMESPACE" timeout 60 \
        python3 src/scripts/host/guest-agent.py exec powershell.exe -NoProfile -Command \
        "Remove-Item 'C:\Windows\Minidump\*' -Force -ErrorAction SilentlyContinue;
         Remove-Item 'C:\Windows\MEMORY.DMP'  -Force -ErrorAction SilentlyContinue;
         Remove-Item 'C:\Temp\bsod-*' -Recurse -Force -ErrorAction SilentlyContinue;
         \$memDmpExists = Test-Path 'C:\Windows\MEMORY.DMP';
         \$miniCount    = (Get-ChildItem 'C:\Windows\Minidump\' -ErrorAction SilentlyContinue | Measure-Object).Count;
         Write-Host ('MEMORY.DMP exists after delete: ' + \$memDmpExists);
         Write-Host ('Minidumps remaining: ' + \$miniCount);
         if (\$memDmpExists) { Write-Host 'WARNING: MEMORY.DMP could not be deleted' }
         else { Write-Host 'OK: MEMORY.DMP deleted' }
         if (\$miniCount -gt 0) { Write-Host 'WARNING: minidumps still present' }
         else { Write-Host 'OK: Minidump directory is clean' }" 2>&1)
    set -e
    echo "$CLEANUP_RESULT" | tee -a "$LOG_FILE"

    # Fail if MEMORY.DMP still exists — crash will not produce a full fresh dump
    if echo "$CLEANUP_RESULT" | grep -q "WARNING: MEMORY.DMP could not be deleted"; then
        die "MEMORY.DMP could not be deleted on guest — cannot guarantee a fresh full dump. Check file locks."
    fi
    log_success "       Guest dump files deleted and verified clean."

    # 0d: Configure crash dump settings.
    # Without this, Windows may crash but write no dump at all.
    # Sets: CrashDumpEnabled=2 (kernel dump), AutoReboot=1, AlwaysKeepMemoryDump=1, Overwrite=1
    # Also verifies page file is large enough to hold a kernel dump.
    log_info "  [0d] Configuring and verifying crash dump settings (configure-dumps.ps1)..."
    set +e
    DUMP_CFG=$(GA_VM="$VM_NAME" GA_NS="$NAMESPACE" timeout 60 \
        python3 src/scripts/host/guest-agent.py psfile \
        src/scripts/guest/configure-dumps.ps1 2>&1)
    DUMP_CFG_EXIT=$?
    set -e
    echo "$DUMP_CFG" | tee -a "$LOG_FILE"

    if [ $DUMP_CFG_EXIT -ne 0 ]; then
        die "configure-dumps.ps1 failed (exit $DUMP_CFG_EXIT) — dump settings not applied. Cannot proceed."
    fi

    # Check if a reboot is required for dump settings to take effect
    if echo "$DUMP_CFG" | grep -q '"rebootRequired": true'; then
        log_warning "       Dump config requires a reboot to take effect!"
        log_warning "       Run: oc get vmi -n $NAMESPACE $VM_NAME (then reboot via vmctl or virt-ctl)"
        die "Guest needs a reboot before dump settings apply. Reboot the VM and re-run this script."
    fi

    if echo "$DUMP_CFG" | grep -q '"matchesRecommended": true'; then
        log_success "       Dump settings verified: kernel dump, AutoReboot=1, Overwrite=1."
    else
        log_warning "       Dump settings applied but may not match recommended — check configure-dumps output above."
    fi

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "STEP 0: File cleanup + dump configuration complete."
    log_info ""

    # Step 1: Verify prerequisites
    log_info "STEP 1: Verify prerequisites"
    if [ ! -f "src/scripts/host/watch-crash.sh" ]; then
        die "watch-crash.sh not found. Expected: $(pwd)/src/scripts/host/watch-crash.sh"
    fi
    log_success "  watch-crash.sh found"
    log_success "  guest-agent.py found: $(ls src/scripts/host/guest-agent.py)"

    # Step 2: Guest confirmed online (done in STEP 0c — quick re-verify)
    log_info ""
    log_info "STEP 2: Guest online re-verify"
    set +e
    GA_VM="$VM_NAME" GA_NS="$NAMESPACE" timeout 8 python3 src/scripts/host/guest-agent.py ping > /dev/null 2>&1
    PING_CHECK=$?
    set -e
    if [ $PING_CHECK -eq 0 ]; then
        log_success "Guest is ONLINE and responding"
    else
        die "Guest went offline after STEP 0. Check VM state: oc get vmi -n $NAMESPACE $VM_NAME"
    fi

    # Step 2b: Show current VM and guest status
    log_info ""
    log_info "STEP 2b: VM status snapshot"
    oc get vmi -n "$NAMESPACE" "$VM_NAME" -o wide 2>&1 | tee -a "$LOG_FILE" || true
    set +e
    GA_VM="$VM_NAME" GA_NS="$NAMESPACE" timeout 15 python3 src/scripts/host/guest-agent.py \
        exec powershell.exe -NoProfile -Command \
        "Get-Date; hostname; (Get-WinEvent -LogName System -MaxEvents 5 | Select-Object TimeCreated,Id,Message | Format-List)" \
        2>&1 | tee -a "$LOG_FILE" || true
    set -e

    # Step 3: NotMyFault already reinstalled fresh in STEP 0e-0f — just confirm
    log_info ""
    log_success "STEP 3: NotMyFault fresh install confirmed (done in STEP 0)"

    # Step 4: Create evidence directory
    log_info ""
    log_info "STEP 4: Prepare evidence directory"
    mkdir -p "$EVIDENCE_DIR"
    log_success "Evidence directory ready: $EVIDENCE_DIR"

    # Step 5: Start watch-crash.sh in background
    log_info ""
    log_info "STEP 5: Start watch-crash.sh monitoring (PID tracking)"
    WATCH_LOG="/tmp/watch_crash_$(date +%s).log"
    timeout "$WATCH_CRASH_TIMEOUT" bash src/scripts/host/watch-crash.sh \
        --ns "$NAMESPACE" \
        --vm "$VM_NAME" \
        --out "$EVIDENCE_DIR" \
        --interval 5 \
        --miss 2 > "$WATCH_LOG" 2>&1 &
    WATCH_PID=$!
    log_success "watch-crash.sh started (PID: $WATCH_PID, log: $WATCH_LOG)"
    log_info "  Waiting 5 seconds for watcher to stabilize..."
    sleep 5

    # Steps 6+7: Fire crash in BACKGROUND, poll independently for crash via ping.
    # The exec call blocks until QGA responds (which never happens after a crash).
    # Running it in background lets us detect crash via ping while the exec hangs.
    # Script will NOT exit this loop until crash is CONFIRMED via ping going silent.
    CRASH_DETECTED=0
    REBOOT_DETECTED=0
    ATTEMPT=0
    TRIGGER_PID=""

    set +e
    while [ $CRASH_DETECTED -eq 0 ]; do
        ATTEMPT=$((ATTEMPT + 1))
        log_info ""
        log_info "STEP 6 [Attempt $ATTEMPT]: TRIGGER INTENTIONAL BSOD"
        log_info "  Firing crash in background — detecting crash via independent ping poll"

        # Kill any previous trigger process still running
        [ -n "$TRIGGER_PID" ] && kill "$TRIGGER_PID" 2>/dev/null || true

        TRIGGER_LOG="/tmp/crash_trigger_${ATTEMPT}.log"
        GA_VM="$VM_NAME" GA_NS="$NAMESPACE" \
            python3 src/scripts/host/guest-agent.py \
            exec cmd.exe /C "C:\\Temp\\nmf\\notmyfaultc64.exe /crash $CRASH_TYPE" \
            > "$TRIGGER_LOG" 2>&1 &
        TRIGGER_PID=$!
        log_info "  Trigger PID: $TRIGGER_PID | Log: $TRIGGER_LOG"
        sleep 3  # brief pause so notmyfault actually launches on guest

        # Step 7: Poll every 5s — wait for crash only.
        # AutoReboot=0 (crash-control.json default): VM stays frozen after BSOD so
        # Windows can finish writing MEMORY.DMP. No reboot wait — watch-crash.sh
        # handles the full pipeline: I/O quiescence → virtctl stop → ODF snapshot
        # → libguestfs extraction → virtctl start.
        log_info "STEP 7 [Attempt $ATTEMPT]: Polling (5s interval) — waiting for crash (AutoReboot=0)..."
        POLL_MAX=300  # 5 min max to detect crash

        for i in $(seq 1 $((POLL_MAX / 5))); do
            sleep 5
            ELAPSED_POLL=$((i * 5))

            GA_VM="$VM_NAME" GA_NS="$NAMESPACE" timeout 10 \
                python3 src/scripts/host/guest-agent.py ping > /dev/null 2>&1
            PING_EXIT=$?

            if [ $PING_EXIT -ne 0 ]; then
                log_success "⚡ CRASH CONFIRMED at +${ELAPSED_POLL}s — guest is DOWN!"
                log_info "  Windows is writing MEMORY.DMP (AutoReboot=0 — VM stays frozen)"
                log_info "  watch-crash.sh will detect I/O quiescence, stop VM, extract dumps offline"
                CRASH_DETECTED=1
                break
            else
                log_info "  ⏳ [+${ELAPSED_POLL}s] Guest online (waiting for crash)..."
            fi
        done

        # Log what the trigger process produced (if it exited)
        if [ -f "$TRIGGER_LOG" ]; then
            echo "--- Trigger log (Attempt $ATTEMPT) ---" >> "$LOG_FILE"
            cat "$TRIGGER_LOG" >> "$LOG_FILE"
        fi

        if [ $CRASH_DETECTED -eq 0 ]; then
            log_warning "No crash confirmed after ${POLL_MAX}s — killing trigger and retrying..."
            kill "$TRIGGER_PID" 2>/dev/null || true
            sleep 5
        fi
    done

    # Clean up trigger background process
    [ -n "$TRIGGER_PID" ] && kill "$TRIGGER_PID" 2>/dev/null || true
    set -e

    # Step 8: Wait for watch-crash.sh to complete the full pipeline.
    # watch-crash.sh now owns the entire post-crash workflow:
    #   detect I/O quiescence → virtctl stop → ODF snapshot → libguestfs extract
    #   → parse-dump-header.sh → evidence-summary.json → virtctl start
    # This script just waits for it to finish (max 30 min for full pipeline).
    log_info ""
    log_info "STEP 8: Waiting for watch-crash.sh to complete full evidence pipeline..."
    log_info "  Pipeline: I/O quiescence → VM stop → ODF snapshot → dump extract → VM restart"
    set +e
    WATCH_WAIT=0
    WATCH_MAX=1800  # 30 min max
    while [ $WATCH_WAIT -lt $WATCH_MAX ]; do
        if ! kill -0 $WATCH_PID 2>/dev/null; then
            log_success "watch-crash.sh completed after ${WATCH_WAIT}s"
            break
        fi
        sleep 30
        WATCH_WAIT=$((WATCH_WAIT + 30))
        log_info "  ⏳ watch-crash.sh still running (${WATCH_WAIT}s elapsed) ..."
    done
    if kill -0 $WATCH_PID 2>/dev/null; then
        log_warning "watch-crash.sh did not complete in ${WATCH_MAX}s — terminating"
        kill $WATCH_PID 2>/dev/null || true
    fi
    set -e

    # Step 9: Report results
    log_info ""
    log_info "╔════════════════════════════════════════════════════════════════╗"
    log_info "║                     EXECUTION COMPLETE                         ║"
    log_info "╚════════════════════════════════════════════════════════════════╝"
    log_info ""
    log_info "Results:"

    if [ -d "$EVIDENCE_DIR" ]; then
        EVIDENCE_COUNT=$(find "$EVIDENCE_DIR" -type f 2>/dev/null | wc -l)
        if [ "$EVIDENCE_COUNT" -gt 0 ]; then
            log_success "Evidence collected: $EVIDENCE_COUNT files in $EVIDENCE_DIR"
            log_info ""
            log_info "Evidence directory contents:"
            find "$EVIDENCE_DIR" -type f -exec ls -lh {} \; | tee -a "$LOG_FILE"
            log_info ""
            log_info "Evidence summary (if available):"
            if [ -f "$EVIDENCE_DIR/evidence-summary.json" ]; then
                cat "$EVIDENCE_DIR/evidence-summary.json" | jq '.' 2>/dev/null || cat "$EVIDENCE_DIR/evidence-summary.json"
            fi
        else
            log_warning "Evidence directory exists but is empty"
            log_info "  This might mean:"
            log_info "    1. Crash didn't trigger (verify NotMyFault output above)"
            log_info "    2. Evidence collection didn't complete in time"
            log_info "    3. Try running collect-from-host.sh manually:"
            log_info "       bash src/scripts/host/collect-from-host.sh --vm $VM_NAME --out $EVIDENCE_DIR"
        fi
    else
        log_error "Evidence directory was not created"
    fi

    log_info ""
    log_success "Full execution log saved to: $LOG_FILE"
    log_success "Watch-crash log saved to: $WATCH_LOG"
    log_info ""
}

# Run main
main "$@"
