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

$warnings = New-Object System.Collections.Generic.List[string]

# Requires the Hyper-V PowerShell module (Get-VM / Mount-VHD).
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Fail 'Hyper-V PowerShell module not available (Get-VM missing). This script requires a Hyper-V host.' 3
}

# 1. Resolve the VM and classify its state.
try {
    $vm = Get-VM -Name $VmName -ErrorAction Stop
} catch {
    Fail "VM '$VmName' not found on this host: $($_.Exception.Message)" 2
}
$state = $vm.State.ToString()   # Running | Off | Saved | Paused | ...

# Heartbeat integration service: 'OK' | 'No Contact' | 'Lost Communication'.
$hb = $null
try {
    $hbSvc = Get-VMIntegrationService -VM $vm -Name 'Heartbeat' -ErrorAction SilentlyContinue
    if ($hbSvc) { $hb = $hbSvc.PrimaryStatusDescription }
} catch { }

# A guest that is Running but not answering its heartbeat is the classic
# BSOD/hang signature: the kernel has stopped scheduling integration services.
$guestState = switch ($state) {
    'Off'     { 'off' }
    'Saved'   { 'hung' }
    'Paused'  { 'hung' }
    'Running' {
        if ($hb -eq 'OK') { 'running' }
        elseif ($hb -in @('No Contact', 'Lost Communication', 'Error')) { 'hung' }
        else { 'unknown' }
    }
    default   { 'unknown' }
}
$crashDetected = ($guestState -eq 'hung')

# 2. Detect-only: report state and stop.
if ($Mode -eq 'detect') {
    Write-JsonResult ([ordered]@{
        ok            = $true
        vm            = $VmName
        mode          = $Mode
        guestState    = $guestState
        crashDetected = $crashDetected
        recovery      = [ordered]@{ method = 'none'; dumpFiles = @(); outputDir = $null }
        warnings      = $warnings
    })
    return
}

# 3. Recovery. Resolve the output dir first (git-ignored; may contain PII).
if (-not $OutputDir) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $OutputDir = Join-Path $script:RepoRoot "output\$stamp"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (-not (Test-IsAdministrator)) {
    $warnings.Add('Not elevated; VHDX mount / LiveKd require Administrator and will likely fail.')
}

$method    = 'none'
$dumpFiles = New-Object System.Collections.Generic.List[string]

# 3a. Preferred, least-invasive: mount the VHDX read-only (needs the VM to be OFF).
if (-not $VhdxPath) {
    try {
        $hd = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Select-Object -First 1
        if ($hd) { $VhdxPath = $hd.Path }
    } catch {
        $warnings.Add("Could not resolve VHDX from VM config: $($_.Exception.Message)")
    }
}

$mounted = $false
if ($VhdxPath -and (Test-Path $VhdxPath)) {
    if ($state -ne 'Off') {
        $warnings.Add("VM is '$state'; the VHDX cannot be mounted read-only while the VM holds it. Power off the guest (or pass -PipeName for LiveKd).")
    } else {
        try {
            $disk = Mount-VHD -Path $VhdxPath -ReadOnly -PassThru -ErrorAction Stop | Get-Disk
            $mounted = $true
            $sysVol = $null
            foreach ($v in ($disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter })) {
                if (Test-Path (Join-Path "$($v.DriveLetter):\" 'Windows\System32\ntoskrnl.exe')) { $sysVol = $v; break }
            }
            if (-not $sysVol) {
                $warnings.Add('Mounted the VHDX but could not locate the Windows system volume.')
            } else {
                $root = "$($sysVol.DriveLetter):\Windows"
                $mem  = Join-Path $root 'MEMORY.DMP'
                $mini = Join-Path $root 'Minidump'
                if (Test-Path $mem) {
                    Copy-Item $mem (Join-Path $OutputDir 'MEMORY.DMP') -Force
                    $dumpFiles.Add('MEMORY.DMP')
                }
                if (Test-Path $mini) {
                    foreach ($m in Get-ChildItem (Join-Path $mini '*.dmp') -ErrorAction SilentlyContinue) {
                        $dest = Join-Path $OutputDir (Join-Path 'Minidump' $m.Name)
                        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                        Copy-Item $m.FullName $dest -Force
                        $dumpFiles.Add((Join-Path 'Minidump' $m.Name))
                    }
                }
                $method = 'vhdx-mount'
                if ($dumpFiles.Count -eq 0) {
                    $warnings.Add('No dump files on the guest volume (Minidump\*.dmp or MEMORY.DMP). Check crash-dump configuration (configure-dumps.ps1).')
                }
            }
        } catch {
            $warnings.Add("VHDX mount/recovery failed: $($_.Exception.Message)")
        } finally {
            if ($mounted) { try { Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue } catch { } }
        }
    }
} elseif ($VhdxPath) {
    $warnings.Add("VHDX path not found: $VhdxPath")
} else {
    $warnings.Add('No VHDX path available for offline recovery.')
}

# 3b. Fallback: LiveKd over a named pipe when the guest is up / at the debugger.
if ($dumpFiles.Count -eq 0 -and $PipeName) {
    $livekd = Get-Command livekd.exe -ErrorAction SilentlyContinue
    $kd     = Get-Command kd.exe -ErrorAction SilentlyContinue
    if ($livekd -and $kd) {
        try {
            $out = Join-Path $OutputDir 'LiveKd-MEMORY.DMP'
            & $livekd.Source -o $out -k $kd.Source -pipe $PipeName -accepteula *> (Join-Path $OutputDir 'livekd.log')
            if (Test-Path $out) {
                $dumpFiles.Add('LiveKd-MEMORY.DMP')
                $method = 'livekd'
            } else {
                $warnings.Add('LiveKd ran but produced no dump (see livekd.log).')
            }
        } catch {
            $warnings.Add("LiveKd failed: $($_.Exception.Message)")
        }
    } else {
        $warnings.Add('LiveKd requested (-PipeName) but livekd.exe/kd.exe were not found on PATH.')
    }
}

# Recovering an actual dump confirms a crash occurred.
if ($dumpFiles.Count -gt 0) { $crashDetected = $true }

# Parsing the recovered dumps is delegated to parse-dump-header.sh /
# analyze-dump.ps1 (the same logic collect-guest.ps1 uses), not duplicated here.
Write-JsonResult ([ordered]@{
    ok            = $true
    vm            = $VmName
    mode          = $Mode
    guestState    = $guestState
    crashDetected = $crashDetected
    recovery      = [ordered]@{
        method    = $method
        dumpFiles = $dumpFiles
        outputDir = $OutputDir
    }
    warnings      = $warnings
})
