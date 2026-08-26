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

$cfg = Get-BsodData 'crash-control.json'

# 1. Resolve + validate the requested dump type.
$type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
$typeNames = $cfg.crashDumpTypes.PSObject.Properties.Name
if ($typeNames -notcontains $type) {
    Fail "Unknown dump type '$type'. Valid: $($typeNames -join ', ')." 2
}
$typeEnabledValue = [int]$cfg.crashDumpTypes.$type.CrashDumpEnabled

# 2. Build the desired value set: the recommended values, with CrashDumpEnabled
#    driven by the selected dump type.
$regPath = $cfg.registryPath
$desired = [ordered]@{}
foreach ($p in $cfg.recommended.values.PSObject.Properties) { $desired[$p.Name] = $p.Value }
$desired['CrashDumpEnabled'] = $typeEnabledValue

# --- helpers ---------------------------------------------------------------
function Get-RegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($item -and ($item.PSObject.Properties.Name -contains $Name)) { return $item.$Name }
    return $null
}
function Expand-IfString { param($Value)
    if ($Value -is [string]) { return [Environment]::ExpandEnvironmentVariables($Value) }
    return $Value
}
# Compare after expanding env vars: the registry stores %SystemRoot%\... as
# REG_EXPAND_SZ but Get-ItemProperty returns it already expanded.
function Values-Match { param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    (Expand-IfString $A).ToString() -eq (Expand-IfString $B).ToString()
}
function Read-Current {
    $c = [ordered]@{}
    foreach ($k in $desired.Keys) { $c[$k] = Get-RegValue -Path $regPath -Name $k }
    return $c
}

# 3. Snapshot the live values before touching anything.
$currentBefore = Read-Current

# 4. Apply the recommended settings unless the caller only wants a report.
$action         = 'verified'
$applied        = $null
$rebootRequired = $false
if (-not $VerifyOnly) {
    if (-not (Test-IsAdministrator)) {
        Fail 'configure-dumps.ps1 must run elevated (Administrator) to write CrashControl.' 3
    }
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    foreach ($k in $desired.Keys) {
        $v = $desired[$k]
        if ($v -is [string]) {
            # Path values -> REG_EXPAND_SZ so %SystemRoot% resolves at read time.
            New-ItemProperty -Path $regPath -Name $k -Value $v -PropertyType ExpandString -Force | Out-Null
        } else {
            New-ItemProperty -Path $regPath -Name $k -Value ([int]$v) -PropertyType DWord -Force | Out-Null
        }
    }
    $action  = 'applied'
    $applied = $desired
    # A change to the dump type (CrashDumpEnabled) only takes effect after reboot.
    $rebootRequired = -not (Values-Match $currentBefore['CrashDumpEnabled'] $typeEnabledValue)
}

# 5. Re-read the live values (post-apply, or unchanged under -VerifyOnly).
$current = Read-Current

# 6. Does the live config match the recommendation for this dump type?
$matchesRecommended = $true
foreach ($k in $desired.Keys) {
    if (-not (Values-Match $current[$k] $desired[$k])) { $matchesRecommended = $false; break }
}

# 7. Page-file adequacy for the selected dump type.
$mmPath    = $cfg.pageFile.path
$pfName    = $cfg.pageFile.value          # 'PagingFiles' (REG_MULTI_SZ)
$pfRaw     = Get-RegValue -Path $mmPath -Name $pfName
$pfEntries = @()
if ($pfRaw) { $pfEntries = @($pfRaw) }
$pfConfigured = if ($pfEntries.Count) { ($pfEntries -join '; ') } else { $null }
$dedicated    = Get-RegValue -Path $regPath -Name 'DedicatedDumpFile'

$ramBytes = $null
try { $ramBytes = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { }

$pfAdequate = $null
if ($dedicated) {
    # A dedicated dump file bypasses the page-file sizing requirement.
    $pfAdequate = $true
} elseif ($pfEntries.Count -eq 0) {
    # No page file and no dedicated dump file: nothing to stage a dump through.
    $pfAdequate = $false
} elseif ($type -eq 'complete') {
    # Complete dump needs a page file >= RAM (+1MB) on the system volume. We can
    # only judge when a fixed maximum size is set; system-managed stays unknown.
    $maxMb = $null
    foreach ($e in $pfEntries) {
        $nums = @(($e -split '\s+') | Where-Object { $_ -match '^\d+$' })
        if ($nums.Count -ge 2) { $maxMb = [int]$nums[1] }
    }
    if ($null -ne $ramBytes -and $null -ne $maxMb -and $maxMb -gt 0) {
        $pfAdequate = (([int64]$maxMb * 1MB) -ge ($ramBytes + 1MB))
    } else {
        $pfAdequate = $null
    }
} else {
    # kernel / automatic / small: an existing page file on the system volume suffices.
    $pfAdequate = $true
}

# 8. Emit the single JSON result.
Write-JsonResult ([ordered]@{
    ok                 = $true
    action             = $action
    requestedDumpType  = $type
    applied            = $applied
    current            = $current
    matchesRecommended = $matchesRecommended
    rebootRequired     = $rebootRequired
    pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $pfAdequate }
})
