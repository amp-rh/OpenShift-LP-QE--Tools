<#
.SYNOPSIS
    Unpack the uploaded toolkit archive into C:\bsod-detector in the guest.

.DESCRIPTION
    scripts\guest\collect-guest.ps1, scripts\guest\analyze-dump.ps1,
    scripts\lib\Common.ps1 and the guest-staged data tables must all be present in
    the guest for the in-guest collectors to resolve. On the cluster there is no scp,
    so the workflow is: zip the toolkit src/ tree on the host, upload it with
    guest-agent.py put to C:\Windows\Temp\bsod-src.zip, then run this to expand it.

    Wipes and recreates C:\bsod-detector, expands the zip, and verifies the key files.
    Expected layout afterwards: C:\bsod-detector\src\scripts\guest\,
    \src\scripts\lib\, \src\data\ (bugcheck-codes.json) and \src\data\guest\.

    Only the guest side needs staging: src\data\host\ and src\scripts\host\ are
    host-only and never have to be shipped into the guest.

    Runs on: the GUEST VM.
#>
$ErrorActionPreference='Stop'
$root='C:\bsod-detector'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null
Expand-Archive -Path 'C:\Windows\Temp\bsod-src.zip' -DestinationPath $root -Force
Write-Output ("collect-guest present : {0}" -f (Test-Path "$root\src\scripts\guest\collect-guest.ps1"))
Write-Output ("Common.ps1 present    : {0}" -f (Test-Path "$root\src\scripts\lib\Common.ps1"))
Write-Output ("data dir present      : {0}" -f (Test-Path "$root\src\data\bugcheck-codes.json"))
Write-Output ("guest data present    : {0}" -f (Test-Path "$root\src\data\guest\crash-control.json"))
