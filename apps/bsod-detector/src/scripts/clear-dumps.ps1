<#
.SYNOPSIS
    Delete existing crash dumps so a test captures only the new one.

.DESCRIPTION
    Removes C:\Windows\Minidump\*.dmp and C:\Windows\MEMORY.DMP, then confirms both
    are gone. Run this BEFORE triggering a BSOD so the resulting evidence package
    contains exactly the dump from this run (this mirrors the lead's guidance to clear
    minidumps before the test rather than diffing a baseline).

    Runs on: the GUEST VM. Requires elevation.
#>
$ErrorActionPreference='SilentlyContinue'
Remove-Item 'C:\Windows\Minidump\*.dmp' -Force
Remove-Item 'C:\Windows\MEMORY.DMP' -Force
$md=@(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -EA SilentlyContinue).Count
Write-Output ("minidumps after clear: {0}" -f $md)
Write-Output ("MEMORY.DMP after clear: {0}" -f (Test-Path 'C:\Windows\MEMORY.DMP'))
