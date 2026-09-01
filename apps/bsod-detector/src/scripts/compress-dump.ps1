<#
.SYNOPSIS
    Copy and compress C:\Windows\MEMORY.DMP for extraction over the guest-agent.

.DESCRIPTION
    A full MEMORY.DMP is hundreds of MB but mostly zero pages, so it compresses to
    ~14%. Pulling the compressed zip over the qemu-guest-agent channel (see
    guest-agent.py get) is far faster and less fragile than the raw dump.

    MEMORY.DMP is usually held open by a system process, so Compress-Archive can't
    read it directly -- this stages a shared-read copy first (Copy-Item, falling back
    to robocopy /B backup mode), zips the copy, prints the sizes + SHA256 of the zip
    (verify it after transfer), then removes the staged copy.

    Runs on: the GUEST VM.

.OUTPUTS
    C:\Temp\MEMORY.DMP.zip  (+ orig/zip sizes and sha256 to stdout)
#>
$ErrorActionPreference='Stop'
$src='C:\Windows\MEMORY.DMP'
$tmp='C:\Temp\MEMORY.DMP'
$zip='C:\Temp\MEMORY.DMP.zip'
foreach($f in @($tmp,$zip)){ if(Test-Path $f){ Remove-Item $f -Force } }
# Copy with shared read; fall back to robocopy backup mode if the handle is locked.
try {
  Copy-Item $src $tmp -Force
} catch {
  Write-Output "Copy-Item locked, trying robocopy /B ..."
  robocopy 'C:\Windows' 'C:\Temp' 'MEMORY.DMP' /B /NP /NFL /NDL /NJH /NJS | Out-Null
}
if (-not (Test-Path $tmp)) { throw "could not stage a readable copy of MEMORY.DMP" }
Compress-Archive -Path $tmp -DestinationPath $zip -CompressionLevel Optimal
$o=(Get-Item $tmp).Length; $z=(Get-Item $zip).Length
Write-Output ("orig  bytes : {0}" -f $o)
Write-Output ("zip   bytes : {0}" -f $z)
Write-Output ("ratio       : {0}%" -f [math]::Round(100*$z/$o,1))
Write-Output ("sha256(zip) : " + (Get-FileHash $zip -Algorithm SHA256).Hash)
Remove-Item $tmp -Force
