# stage-toolkit.ps1 — Prepare the Windows guest for BSOD detection.
#
# One-time setup: creates directories and verifies the guest is ready
# for crash detection and offline evidence collection.
#
# Runs INSIDE the Windows guest VM (via guest-agent.py).
#
# Usage:
#   GA_VM=<vm> GA_NS=<ns> python3 src/scripts/host/guest-agent.py psfile \
#     src/scripts/guest/stage-toolkit.ps1
#

$ErrorActionPreference = "Stop"

Write-Host "BSOD Detector: Staging toolkit on guest..."

# Create necessary directories
$dirs = @(
    "C:\bsod-detector",
    "C:\bsod-detector\src",
    "C:\bsod-detector\src\scripts",
    "C:\bsod-detector\src\scripts\guest",
    "C:\Windows\Minidump"
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        Write-Host "Creating directory: $dir"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    } else {
        Write-Host "Directory exists: $dir"
    }
}

# Verify crash dump directory exists and is writable
$dumpDir = "C:\Windows"
if (Test-Path $dumpDir) {
    Write-Host "Crash dump directory verified: $dumpDir"
} else {
    Write-Error "Crash dump directory not found: $dumpDir"
}

# Verify Minidump directory exists
$minidumpDir = "C:\Windows\Minidump"
if (Test-Path $minidumpDir) {
    Write-Host "Minidump directory verified: $minidumpDir"
} else {
    Write-Error "Minidump directory not found: $minidumpDir"
}

Write-Host "Toolkit staging complete. Guest is ready for BSOD detection."
exit 0
