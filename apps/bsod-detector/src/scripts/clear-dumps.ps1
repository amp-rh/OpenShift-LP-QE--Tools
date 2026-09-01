<#
.SYNOPSIS
    Delete existing crash dumps so a test captures only the new one.

.DESCRIPTION
    Removes the guest's minidumps and full dump, then confirms both are gone. Run
    this BEFORE triggering a BSOD so the resulting evidence package contains exactly
    the dump from this run (this mirrors the lead's guidance to clear minidumps
    before the test rather than diffing a baseline). Honors the VM's configured
    dump paths (CrashControl DumpFile / MinidumpDir) instead of assuming C:\Windows,
    falling back to the OS defaults.

    Runs on: the GUEST VM. Requires elevation.
#>
. "$PSScriptRoot\lib\Common.ps1"
# Common.ps1 sets ErrorActionPreference=Stop; we want removals of absent dumps to
# stay quiet, so relax it here (after dot-sourcing) and guard each removal.
$ErrorActionPreference='SilentlyContinue'
$paths   = Get-DumpPaths
$miniDir = $paths.MinidumpDir
Remove-Item (Join-Path $miniDir '*.dmp') -Force -ErrorAction SilentlyContinue
foreach ($full in @($paths.DumpFile, $paths.DedicatedDumpFile)) {
    if ($full) { Remove-Item $full -Force -ErrorAction SilentlyContinue }
}
$md=@(Get-ChildItem (Join-Path $miniDir '*.dmp') -EA SilentlyContinue).Count
Write-Output ("minidumps after clear: {0}" -f $md)
Write-Output ("MEMORY.DMP after clear: {0}" -f (Test-Path $paths.DumpFile))
