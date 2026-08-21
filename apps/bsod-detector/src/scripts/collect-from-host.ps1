<#
.SYNOPSIS
    Detect a guest BSOD from the host and recover the dump when the guest is
    frozen, rebooting, or won't boot.

.DESCRIPTION
    Host-side counterpart to collect-guest.ps1. Covers the cases the guest can't
    handle itself:
      - detect a guest hang/reset via the hypervisor (guest state / heartbeat)
      - attach LiveKd to the guest kernel over a named pipe / virtual serial port
      - mount the guest VHDX offline and pull %SystemRoot%\MEMORY.DMP and
        Minidump\*.dmp when the guest is unbootable
      - optionally hand off to collect-guest.ps1 via PsExec once the guest is up

    Runs on: the HOST. Requires Hyper-V (or equivalent) and Administrator for
    VHDX mount and pipe access.

    Produces facts only; interpreting the crash is the agent's job.

.PARAMETER VmName
    Name of the guest VM (as known to the hypervisor).

.PARAMETER VhdxPath
    Path to the guest's VHDX, for offline dump recovery. If omitted, the script
    tries to resolve it from the VM configuration.

.PARAMETER PipeName
    Named pipe for LiveKd/kd kernel debugging (e.g. '\\.\pipe\vm-debug').
    Optional; only used for live debugging.

.PARAMETER OutputDir
    Directory to copy recovered dumps into. Defaults to <repo>\output\<timestamp>.
    Git-ignored (may contain PII).

.PARAMETER Mode
    'detect'  : report guest state only.
    'recover' : mount VHDX (or use LiveKd) and pull dumps. (default)

.OUTPUTS
    A single JSON object to stdout:
    {
      "ok": true,
      "vm": "win11-test",
      "mode": "recover",
      "guestState": "running" | "off" | "hung" | "rebooting" | "unknown",
      "crashDetected": true|false,
      "recovery": {
        "method": "vhdx-mount" | "livekd" | "none",
        "dumpFiles": ["MEMORY.DMP", "Minidump\\...dmp"],
        "outputDir": "...\\output\\..."
      },
      "warnings": [ "VHDX in use; VM must be off to mount read-only" ]
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmName,
    [string]$VhdxPath,
    [string]$PipeName,
    [string]$OutputDir,
    [ValidateSet('detect','recover')][string]$Mode = 'recover'
)

. "$PSScriptRoot\lib\Common.ps1"

# TODO(impl):
#   1. Detect guest state (Get-VM / heartbeat integration service). Infer
#      crashDetected from a reset without clean shutdown, or a stuck state.
#   2. If Mode = 'detect', Write-JsonResult and return.
#   3. Recovery, prefer least-invasive that works:
#        a. If VM is off and $VhdxPath resolvable: Mount-VHD -ReadOnly, copy
#           <mount>\Windows\MEMORY.DMP and \Windows\Minidump\*.dmp, Dismount-VHD.
#        b. Else if $PipeName set and guest is at the debugger: LiveKd over pipe
#           to save a dump (livekd -o <file> -k <path-to-kd>).
#   4. Copy recovered dumps into $OutputDir (default <repo>\output\yyyyMMdd-HHmmss).
#   5. Parsing of recovered dumps is delegated to the same logic as
#      collect-guest.ps1 (shared parser), not duplicated here.
#   6. Write-JsonResult with the shape in .OUTPUTS.

Fail 'collect-from-host.ps1 is a stub; implementation pending.'
