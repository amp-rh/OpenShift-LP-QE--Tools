<#
.SYNOPSIS
    Install an SSH public key for passwordless admin login to the guest.

.DESCRIPTION
    Runs INSIDE the guest (elevated). For members of the Administrators group,
    Windows OpenSSH reads authorized keys from
    C:\ProgramData\ssh\administrators_authorized_keys (NOT %USERPROFILE%\.ssh),
    and requires the file to be owned by Administrators/SYSTEM with no other
    write access. This script appends the key (idempotently) and fixes the ACL.

    Idempotent: re-running with the same key is a no-op. Emits one JSON object.

.PARAMETER PublicKey
    The full public key line (e.g. "ssh-ed25519 AAAA... comment").

.OUTPUTS
    { "ok": true, "path": "...", "keyCount": N, "added": bool }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublicKey
)
$ErrorActionPreference = 'Stop'

$dir  = Join-Path $env:ProgramData 'ssh'
$akf  = Join-Path $dir 'administrators_authorized_keys'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$key = $PublicKey.Trim()
$existing = @()
if (Test-Path $akf) { $existing = @(Get-Content $akf | Where-Object { $_.Trim() -ne '' }) }

$added = $false
if ($existing -notcontains $key) {
    Add-Content -Path $akf -Value $key -Encoding ascii
    $added = $true
}

# Lock down ACL: only Administrators + SYSTEM, no inheritance.
icacls $akf /inheritance:r          | Out-Null
icacls $akf /grant 'Administrators:F' 'SYSTEM:F' | Out-Null

# Make sure the OpenSSH service is running and set to auto-start.
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue

$keyCount = @(Get-Content $akf | Where-Object { $_.Trim() -ne '' }).Count

[ordered]@{
    ok       = $true
    path     = $akf
    keyCount = $keyCount
    added    = $added
} | ConvertTo-Json
