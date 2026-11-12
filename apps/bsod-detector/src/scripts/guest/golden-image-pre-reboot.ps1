# Run as Administrator in the golden image BEFORE sealing
# Supports all disk bus types: virtio (viostor), scsi (vioscsi), sata (storahci — inbox)
# Installing all virtio-win drivers is safe — Windows loads only the one matching the presented hardware.

# ── Step 1: Download virtio-win ISO (skip if already latest) ──────────────
New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$isoUrl  = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
$isoPath = "C:\Temp\virtio-win.iso"

# Check remote Last-Modified via HEAD request
$req = [System.Net.HttpWebRequest]::Create($isoUrl)
$req.Method = "HEAD"
$resp = $req.GetResponse()
$remoteLastModified = $resp.LastModified
$resp.Close()
Write-Host "Remote ISO Last-Modified: $remoteLastModified"

$needDownload = $true
if (Test-Path $isoPath) {
    $localLastModified = (Get-Item $isoPath).LastWriteTimeUtc
    if ($localLastModified -ge $remoteLastModified.ToUniversalTime()) {
        Write-Host "OK: virtio-win ISO already latest (local=$localLastModified >= remote=$($remoteLastModified.ToUniversalTime())) — skipping download"
        $needDownload = $false
    } else {
        Write-Host "ISO outdated (local=$localLastModified, remote=$($remoteLastModified.ToUniversalTime())) — re-downloading"
    }
}
if ($needDownload) {
    Write-Host "Downloading virtio-win ISO..."
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($isoUrl, $isoPath)
    Write-Host "OK: Downloaded $(([math]::Round((Get-Item $isoPath).Length / 1MB, 0))) MB"
}

$iso   = Mount-DiskImage -ImagePath $isoPath -PassThru
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
    # Register pvpanic device in registry so Windows activates it at boot
    $pvpanicReg = 'HKLM:\SYSTEM\CurrentControlSet\Services\pvpanic'
    if (-not (Test-Path $pvpanicReg)) {
        New-Item -Path $pvpanicReg -Force | Out-Null
    }
    Set-ItemProperty -Path $pvpanicReg -Name Start -Value 3 -Type DWord
    Set-ItemProperty -Path $pvpanicReg -Name Type  -Value 1 -Type DWord
    Write-Host "OK: pvpanic registry entry set (Start=3 demand-load, Type=1 kernel driver)"
} else {
    Write-Host "WARN: pvpanic.inf not found in ISO — pipeline will add pvpanic device via QMP at runtime"
}

Dismount-DiskImage -ImagePath $isoPath
# Keep ISO on disk for version check on future runs (only remove if re-downloaded)
if (-not $needDownload) {
    Write-Host "OK: ISO kept for future version checks"
} else {
    Write-Host "OK: ISO unmounted (kept on disk at $isoPath for future version checks)"
}
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

# Remove all existing pagefile registry entries and set fresh value at RAM + 257MB
Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Removing old pagefile entry: $($_.Name)"
    $_ | Remove-CimInstance -Confirm:$false
}
New-CimInstance -ClassName Win32_PageFileSetting -Property @{
    Name        = 'C:\pagefile.sys'
    InitialSize = [uint32]$pagefileSizeMB
    MaximumSize = [uint32]$pagefileSizeMB
} | Out-Null
Write-Host "OK: pagefile.sys registered via WMI (${pagefileSizeMB} MB = RAM + 257MB)"
Write-Host "OK: Pagefile pre-allocation complete — active after reboot"

Write-Host "`n=== All steps complete. Rebooting in 5 seconds... ==="
Start-Sleep -Seconds 5
Restart-Computer -Force
