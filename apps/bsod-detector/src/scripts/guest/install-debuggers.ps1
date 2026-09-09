<#
.SYNOPSIS
    Install the Windows Debugging Tools (cdb) in the guest for deep dump analysis.

.DESCRIPTION
    analyze-dump.ps1 and collect-guest.ps1 -Symbolize need cdb.exe. Golden Windows
    images usually ship without it, so this downloads the Windows 10 SDK web installer
    and installs only the debuggers feature, quietly and without a reboot.

        winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart
    lands cdb at: C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe

    Runs on: the GUEST VM. Requires outbound internet (also to the MS public symbol
    server, msdl, at analysis time). Takes ~5 min -- when driven via guest-agent.py
    run it with a long poll_timeout (e.g. 600) so the exec doesn't time out.
#>
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$cdb='C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
if (Test-Path $cdb) { Write-Output "cdb already present"; exit 0 }
$dir='C:\Temp\sdk'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
$setup="$dir\winsdksetup.exe"
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2164145' -OutFile $setup -UseBasicParsing -TimeoutSec 120
Write-Output ("winsdksetup.exe {0} bytes" -f (Get-Item $setup).Length)
$p = Start-Process -FilePath $setup -ArgumentList '/features','OptionId.WindowsDesktopDebuggers','/quiet','/norestart' -Wait -PassThru
Write-Output ("installer exit: {0}" -f $p.ExitCode)
Write-Output ("cdb present now: {0}" -f (Test-Path $cdb))
