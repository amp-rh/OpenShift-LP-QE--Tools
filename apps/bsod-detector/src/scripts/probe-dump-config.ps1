<#
.SYNOPSIS
    Report the guest's crash-dump configuration and current dump inventory.

.DESCRIPTION
    A quick pre/post-test snapshot: CrashControl settings (CrashDumpEnabled,
    AlwaysKeepMemoryDump, DumpFile, MinidumpDir), how many minidumps exist and
    whether MEMORY.DMP is present, free space on C:, RAM, last boot time, and whether
    the toolkit is staged. Read-only -- changes nothing (use configure-dumps.ps1 to
    apply settings). Useful to confirm CrashDumpEnabled=7 (automatic) before a run and
    to see the new dump + a fresh LastBootUpTime after.

    Runs on: the GUEST VM.
#>
$ErrorActionPreference='SilentlyContinue'
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Write-Output ("CrashDumpEnabled     : {0}" -f $cc.CrashDumpEnabled)
Write-Output ("AlwaysKeepMemoryDump : {0}" -f $cc.AlwaysKeepMemoryDump)
Write-Output ("DumpFile             : {0}" -f $cc.DumpFile)
Write-Output ("MinidumpDir          : {0}" -f $cc.MinidumpDir)
# Resolve the actual configured paths (a naturally-crashed VM may relocate them);
# fall back to the OS defaults when a value is unset.
$miniDir  = if ($cc.MinidumpDir) { [Environment]::ExpandEnvironmentVariables($cc.MinidumpDir) } else { Join-Path $env:SystemRoot 'Minidump' }
$dumpFile = if ($cc.DumpFile)    { [Environment]::ExpandEnvironmentVariables($cc.DumpFile)    } else { Join-Path $env:SystemRoot 'MEMORY.DMP' }
$md = Get-ChildItem (Join-Path $miniDir '*.dmp') -ErrorAction SilentlyContinue
Write-Output ("Minidumps present    : {0}" -f (@($md).Count))
$md | ForEach-Object { Write-Output ("   - {0}  {1}  {2}" -f $_.Name,$_.Length,$_.LastWriteTime) }
$mem = Test-Path $dumpFile
Write-Output ("MEMORY.DMP present   : {0}" -f $mem)
Write-Output ("FreeMB (sys vol)     : {0}" -f [math]::Round((Get-PSDrive C).Free/1MB))
Write-Output ("RAM GB               : {0}" -f [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB))
Write-Output ("LastBootUpTime       : {0}" -f (Get-CimInstance Win32_OperatingSystem).LastBootUpTime)
Write-Output ("Toolkit staged       : {0}" -f (Test-Path 'C:\bsod-detector\src\scripts\collect-guest.ps1'))
