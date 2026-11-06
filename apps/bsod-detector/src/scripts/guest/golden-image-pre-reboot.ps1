# Run as Administrator in the golden image BEFORE sealing
# Supports all disk bus types: virtio (viostor), scsi (vioscsi), sata (storahci — inbox)
# Installing all virtio-win drivers is safe — Windows loads only the one matching the presented hardware.

# ── Step 1: Download virtio-win ISO ───────────────────────────────────────
New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
Write-Host "Downloading virtio-win ISO..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$wc = New-Object System.Net.WebClient
$wc.DownloadFile(
    "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso",
    "C:\Temp\virtio-win.iso"
)
Write-Host "OK: Downloaded $(([math]::Round((Get-Item C:\Temp\virtio-win.iso).Length / 1MB, 0))) MB"

$iso   = Mount-DiskImage -ImagePath C:\Temp\virtio-win.iso -PassThru
$drive = ($iso | Get-Volume).DriveLetter
Write-Host "OK: ISO mounted at ${drive}:\"

# ── Step 2: Install QEMU Guest Agent ──────────────────────────────────────
Write-Host "`n--- Installing QEMU Guest Agent ---"
Start-Process msiexec.exe -ArgumentList "/i ${drive}:\guest-agent\qemu-ga-x86_64.msi /quiet /norestart" -Wait
Write-Host "OK: QEMU Guest Agent MSI installed"

# ── Step 3: Install VirtIO storage drivers ────────────────────────────────
# All three drivers are installed — Windows activates only the one matching presented hardware.
# viostor = virtio-blk (bus: virtio)
# vioscsi = virtio-scsi (bus: scsi)
# storahci = SATA/AHCI  (bus: sata) — inbox Windows driver, no install needed
Write-Host "`n--- Installing VirtIO storage drivers ---"
$driverPaths = @(
    @{ Name = "viostor (VirtIO block)";  Pattern = "viostor\w11\amd64\viostor.inf" },
    @{ Name = "vioscsi (VirtIO SCSI)";   Pattern = "vioscsi\w11\amd64\vioscsi.inf" }
)
foreach ($drv in $driverPaths) {
    $inf = Get-Item "${drive}:\$($drv.Pattern)" -ErrorAction SilentlyContinue
    if ($inf) {
        pnputil /add-driver $inf.FullName /install | Out-Null
        Write-Host "OK: $($drv.Name) installed from $($inf.FullName)"
    } else {
        Write-Host "WARN: $($drv.Name) inf not found at ${drive}:\$($drv.Pattern) — trying recursive search"
        $inf = Get-ChildItem "${drive}:\" -Recurse -Filter "$($drv.Pattern.Split('\')[-1])" -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -like "*amd64*" } | Select-Object -First 1
        if ($inf) {
            pnputil /add-driver $inf.FullName /install | Out-Null
            Write-Host "OK: $($drv.Name) installed from $($inf.FullName)"
        } else {
            Write-Host "WARN: $($drv.Name) not found in ISO — skip"
        }
    }
}
Write-Host "NOTE: storahci.sys (SATA) is an inbox Windows driver — no installation needed"

# ── Step 4: Install pvpanic driver ────────────────────────────────────────
# pvpanic signals BSOD to QEMU → enables on_crash=preserve (VM stays frozen for dump capture)
Write-Host "`n--- Installing pvpanic driver ---"
$pvpanicInf = Get-ChildItem "${drive}:\pvpanic" -Recurse -Filter "pvpanic.inf" `
    -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*amd64*" } | Select-Object -First 1
if ($pvpanicInf) {
    pnputil /add-driver $pvpanicInf.FullName /install | Out-Null
    Write-Host "OK: pvpanic.sys installed from $($pvpanicInf.FullName)"
} else {
    Write-Host "WARN: pvpanic.inf not found in ISO — pipeline will add pvpanic device via QMP at runtime"
}

Dismount-DiskImage -ImagePath C:\Temp\virtio-win.iso
Remove-Item C:\Temp\virtio-win.iso -Force
Write-Host "OK: ISO unmounted and removed"

# ── Step 5: Verify and start QEMU Guest Agent ─────────────────────────────
Write-Host "`n--- Verifying QEMU Guest Agent ---"
$svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Error "FAIL: QEMU-GA service not installed — abort"
    exit 1
}
Set-Service QEMU-GA -StartupType Automatic
if ($svc.Status -ne 'Running') {
    Write-Host "QEMU-GA is stopped — starting..."
    Start-Service QEMU-GA -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $svc.Refresh()
}
if ($svc.Status -eq 'Running') {
    Write-Host "OK: QEMU-GA is Running and set to Automatic"
} else {
    Write-Error "FAIL: QEMU-GA could not be started (Status: $($svc.Status)) — abort"
    exit 1
}

# ── Step 6: Disable Windows automatic recovery mode ───────────────────────
# Prevents Win11 from entering WinRE/self-diagnosis loop after BSOD
#Write-Host "`n--- Disabling Windows recovery mode ---"
#bcdedit /set '{default}' bootstatuspolicy IgnoreAllFailures
#bcdedit /set '{default}' recoveryenabled No
#bcdedit /set '{bootmgr}' displaybootmenu No
#reagentc /disable
#Write-Host "OK: Windows automatic recovery disabled"

# ── Step 7: Set crash dump registry parameters ────────────────────────────
# CrashDumpEnabled=7 (Automatic): writes kernel pages to pagefile.sys at crash time via normal I/O.
# No DedicatedDumpFile — that forces StorPort crash miniport which fails on VirtIO (issue #1629).
# pagefile.sys is used naturally for Phase 1 staging (normal I/O, always works on QEMU KVM).
Write-Host "`n--- Setting crash dump registry ---"
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty -Path $cc -Name CrashDumpEnabled     -Value 7                         -Type DWord
Set-ItemProperty -Path $cc -Name AutoReboot            -Value 0                         -Type DWord
Set-ItemProperty -Path $cc -Name AlwaysKeepMemoryDump  -Value 1                         -Type DWord
Set-ItemProperty -Path $cc -Name Overwrite             -Value 1                         -Type DWord
Set-ItemProperty -Path $cc -Name LogEvent              -Value 1                         -Type DWord
Set-ItemProperty -Path $cc -Name DumpFile              -Value '%SystemRoot%\MEMORY.DMP' -Type ExpandString
Set-ItemProperty -Path $cc -Name MinidumpDir           -Value '%SystemRoot%\Minidump'   -Type ExpandString
# Remove DedicatedDumpFile if previously set — it forces StorPort miniport which fails on VirtIO
Remove-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue
Write-Host "OK: Crash dump registry set (CrashDumpEnabled=1, no DedicatedDumpFile)"

# ── Step 8: Pre-allocate pagefile.sys (RAM + 257MB) and disable automatic management
# Complete dump (CrashDumpEnabled=1) requires pagefile >= RAM size.
# +257MB buffer prevents Windows from deallocating the pagefile on systems with high free RAM.
# pagefile.sys uses normal I/O for crash dump staging — works on all drivers (VirtIO, SATA, SCSI).
Write-Host "`n--- Pre-allocating pagefile.sys ---"
$mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
Set-ItemProperty -Path $mm -Name AutomaticManagedPagefile -Value 0 -Type DWord

$ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
$pagefileSizeBytes = $ramBytes + (257 * 1024 * 1024)  # RAM + 257MB
$pagefileSizeMB = [math]::Round($pagefileSizeBytes / 1MB, 0)
$pagefilePath = 'C:\pagefile.sys'
if (-not (Test-Path $pagefilePath)) {
    fsutil file createnew $pagefilePath $pagefileSizeBytes
    Write-Host "OK: Created pagefile.sys = ${pagefileSizeMB} MB ($([math]::Round($pagefileSizeBytes / 1GB, 1)) GB)"
} else {
    Write-Host "OK: pagefile.sys already exists ($([math]::Round((Get-Item $pagefilePath -Force).Length / 1GB, 1)) GB)"
}

$existing = Get-CimInstance Win32_PageFileSetting -Filter "Name='C:\\pagefile.sys'" -ErrorAction SilentlyContinue
if (-not $existing) {
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{
        Name        = 'C:\pagefile.sys'
        InitialSize = $pagefileSizeMB
        MaximumSize = $pagefileSizeMB
    }
    Write-Host "OK: pagefile.sys registered via WMI (${pagefileSizeMB} MB fixed)"
} else {
    Write-Host "OK: pagefile.sys already registered in WMI"
}
Write-Host "OK: Pagefile pre-allocation complete — active after reboot"

Write-Host "`n=== All steps complete. Rebooting in 5 seconds... ==="
Start-Sleep -Seconds 5
Restart-Computer -Force
