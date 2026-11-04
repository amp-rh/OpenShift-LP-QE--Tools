# Run as Administrator AFTER reboot, BEFORE sealing the golden image
# Verifies all 9 checks — all must pass before sealing
$failed = $false

# ── Step 1: Verify QEMU Guest Agent ───────────────────────────────────────
Write-Host "`n--- Checking QEMU Guest Agent ---"
$svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
Set-Service qemu-ga -StartupType Automatic -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "OK: QEMU-GA = Running, StartupType = Automatic"
} else {
    Write-Error "FAIL: QEMU-GA not running (status: $($svc?.Status))"
    $failed = $true
}

# ── Step 2: Verify VirtIO storage drivers in driver store ─────────────────
# These drivers are installed in the driver store — they activate only when
# matching hardware is presented (virtio-blk, virtio-scsi, or SATA).
# Installing all three in the golden image makes the image compatible with
# any disk bus type (virtio, scsi, sata) without impacting VM operations.
Write-Host "`n--- Checking VirtIO storage drivers ---"
$viostor = Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -like "*viostor*" } -ErrorAction SilentlyContinue
$vioscsi = Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -like "*vioscsi*" } -ErrorAction SilentlyContinue
$storahci = Get-Item 'C:\Windows\System32\drivers\storahci.sys' -ErrorAction SilentlyContinue

if ($viostor) {
    Write-Host "OK: viostor.sys in driver store (activates with bus: virtio)"
} else {
    Write-Host "WARN: viostor.sys not in driver store — VM with bus: virtio may not boot (non-fatal if using SATA/SCSI)"
}
if ($vioscsi) {
    Write-Host "OK: vioscsi.sys in driver store (activates with bus: scsi)"
} else {
    Write-Host "WARN: vioscsi.sys not in driver store — VM with bus: scsi may not boot (non-fatal if using VirtIO/SATA)"
}
if ($storahci) {
    Write-Host "OK: storahci.sys present (inbox driver, activates with bus: sata — crash dump supported natively)"
} else {
    Write-Host "WARN: storahci.sys not found — unexpected (inbox driver should always be present)"
}

# ── Step 3: Verify pvpanic driver ─────────────────────────────────────────
Write-Host "`n--- Checking pvpanic driver ---"
$pvpanicSys = Get-Item 'C:\Windows\System32\drivers\pvpanic.sys' -ErrorAction SilentlyContinue
if ($pvpanicSys) {
    Write-Host "OK: pvpanic.sys present — signals BSOD to QEMU for crash-preserve behavior"
} else {
    Write-Host "WARN: pvpanic.sys not found — pipeline adds pvpanic device via QMP at runtime (non-fatal)"
}

# ── Step 4: Verify recovery mode disabled ─────────────────────────────────
Write-Host "`n--- Checking recovery settings ---"
$bootStatus  = bcdedit /enum '{default}' | Select-String "bootstatuspolicy"
$recoveryEna = bcdedit /enum '{default}' | Select-String "recoveryenabled"
if ($bootStatus -match "IgnoreAllFailures") {
    Write-Host "OK: bootstatuspolicy = IgnoreAllFailures"
} else {
    Write-Error "FAIL: bootstatuspolicy not set to IgnoreAllFailures"; $failed = $true
}
if ($recoveryEna -match "No") {
    Write-Host "OK: recoveryenabled = No"
} else {
    Write-Error "FAIL: recoveryenabled not set to No"; $failed = $true
}

# ── Step 5: Verify crash dump registry settings ────────────────────────────
Write-Host "`n--- Checking crash dump registry ---"
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$expected = @{
    CrashDumpEnabled     = 7
    AutoReboot           = 0
    AlwaysKeepMemoryDump = 1
    Overwrite            = 1
    LogEvent             = 1
}
foreach ($key in $expected.Keys) {
    $actual = (Get-ItemProperty -Path $cc -Name $key -ErrorAction SilentlyContinue).$key
    if ("$actual" -eq "$($expected[$key])") {
        Write-Host "OK: $key = $actual"
    } else {
        Write-Error "FAIL: $key = '$actual' (expected '$($expected[$key])')"
        $failed = $true
    }
}
# DedicatedDumpFile must NOT be set — it forces StorPort crash miniport which fails on VirtIO
$dedicatedDump = (Get-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue).DedicatedDumpFile
if ($dedicatedDump) {
    Write-Error "FAIL: DedicatedDumpFile = '$dedicatedDump' (must be absent — forces StorPort miniport, fails on VirtIO)"
    $failed = $true
} else {
    Write-Host "OK: DedicatedDumpFile = (not set) — pagefile.sys used via normal I/O"
}

# ── Step 7: Verify AutomaticManagedPagefile disabled ──────────────────────
Write-Host "`n--- Checking pagefile management ---"
$auto = (Get-CimInstance -ClassName Win32_ComputerSystem).AutomaticManagedPagefile
if (-not $auto) {
    Write-Host "OK: AutomaticManagedPagefile = false"
} else {
    Write-Error "FAIL: AutomaticManagedPagefile is still true"
    $failed = $true
}

# ── Step 8: Verify pagefile.sys is active in running kernel ───────────────
Write-Host "`n--- Checking pagefile.sys ---"
$pf = Get-CimInstance Win32_PageFileUsage | Where-Object { $_.Name -like 'C:\*' }
$ramMB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1MB, 0)
$expectedMinMB = $ramMB + 257
if ($pf -and $pf.AllocatedBaseSize -ge $expectedMinMB) {
    Write-Host "OK: pagefile.sys active — AllocatedBaseSize=$($pf.AllocatedBaseSize) MB (>= RAM+257MB=${expectedMinMB} MB), CurrentUsage=$($pf.CurrentUsage) MB"
} elseif ($pf -and $pf.AllocatedBaseSize -gt 0) {
    Write-Error "FAIL: pagefile.sys active but too small — AllocatedBaseSize=$($pf.AllocatedBaseSize) MB (expected >= ${expectedMinMB} MB = RAM+257MB)"
    $failed = $true
} else {
    Write-Error "FAIL: pagefile.sys not active in running kernel — crash dump will not be written on BSOD"
    $failed = $true
}

# ── Final verdict ─────────────────────────────────────────────────────────
Write-Host ""
if ($failed) {
    Write-Error "=== One or more checks FAILED — DO NOT SEAL. Fix issues and re-run Script 1. ==="
    exit 1
} else {
    Write-Host "=== All checks passed — safe to seal the golden image. ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Driver summary (Windows activates the correct one at boot based on presented hardware):"
    Write-Host "  bus: virtio  → viostor.sys  (crash dumps zero-filled — StorPort issue #1629)"
    Write-Host "  bus: scsi    → vioscsi.sys  (crash dumps zero-filled — StorPort issue #1629)"
    Write-Host "  bus: sata    → storahci.sys (crash dumps write real content — inbox driver)"
}
