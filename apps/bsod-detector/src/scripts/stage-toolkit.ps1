<#
.SYNOPSIS
    Unpack the uploaded toolkit archive into C:\bsod-detector in the guest.

.DESCRIPTION
    collect-guest.ps1, analyze-dump.ps1, lib\Common.ps1 and src\data\*.json must all
    be present in the guest for the in-guest collectors to resolve. On the cluster there
    is no scp, so the workflow is: zip the toolkit src/ tree on the host, upload it with
    guest-agent.py put to C:\Windows\Temp\bsod-src.zip, then run this to expand it.

    Wipes and recreates C:\bsod-detector, expands the zip, and verifies the key files.
    Expected layout afterwards: C:\bsod-detector\src\scripts\..., \src\scripts\lib\,
    \src\data\.

    Runs on: the GUEST VM.
#>
$ErrorActionPreference='Stop'
$root='C:\bsod-detector'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null
Expand-Archive -Path 'C:\Windows\Temp\bsod-src.zip' -DestinationPath $root -Force
Write-Output ("collect-guest present : {0}" -f (Test-Path "$root\src\scripts\collect-guest.ps1"))
Write-Output ("Common.ps1 present    : {0}" -f (Test-Path "$root\src\scripts\lib\Common.ps1"))
Write-Output ("data dir present      : {0}" -f (Test-Path "$root\src\data\bugcheck-codes.json"))
