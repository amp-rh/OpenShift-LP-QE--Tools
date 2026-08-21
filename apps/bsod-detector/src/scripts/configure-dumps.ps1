<#
.SYNOPSIS
    Configure Windows crash-dump settings so a dump is written on the next BSOD,
    or verify the current settings without changing them.

.DESCRIPTION
    Reads the recommended CrashControl settings from data/crash-control.json and
    applies them under HKLM\SYSTEM\CurrentControlSet\Control\CrashControl. With
    -VerifyOnly it reports the live settings and whether they match the
    recommendation, changing nothing.

    Runs on: the GUEST VM. Requires Administrator (registry write). A reboot is
    required for some dump-type changes to take effect.

    Prerequisite step: without this, a BSOD may leave no dump to analyze.

.PARAMETER DumpType
    Override the recommended dump type. One of the keys in
    crash-control.json .crashDumpTypes (none|complete|kernel|small|automatic).
    Defaults to the file's recommended.crashDumpType.

.PARAMETER VerifyOnly
    Report current settings without modifying the registry.

.OUTPUTS
    A single JSON object to stdout:
    {
      "ok": true,
      "action": "applied" | "verified",
      "requestedDumpType": "kernel",
      "applied":  { "CrashDumpEnabled": 2, ... },   # present when action=applied
      "current":  { "CrashDumpEnabled": 2, ... },   # live registry values
      "matchesRecommended": true,
      "rebootRequired": false,
      "pageFile": { "configured": "?system-managed?", "adequate": true|null }
    }
#>
[CmdletBinding()]
param(
    [string]$DumpType,
    [switch]$VerifyOnly
)

. "$PSScriptRoot\lib\Common.ps1"

# TODO(impl):
#   1. $cfg = Get-BsodData 'crash-control.json'
#   2. $type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
#      - validate $type is a key in $cfg.crashDumpTypes; Fail if not.
#   3. Read current values from $cfg.registryPath (Get-ItemProperty).
#   4. If -not $VerifyOnly:
#        - require Test-IsAdministrator, else Fail "must run elevated".
#        - Set each of $cfg.recommended.values (expand %SystemRoot% etc.).
#        - determine rebootRequired (dump-type change vs current).
#   5. Inspect page file ($cfg.pageFile) and judge adequacy for $type
#      (complete needs >= RAM+1MB, or a DedicatedDumpFile). Report null if unknown.
#   6. Write-JsonResult with the shape documented in .OUTPUTS.

Fail 'configure-dumps.ps1 is a stub; implementation pending.'
