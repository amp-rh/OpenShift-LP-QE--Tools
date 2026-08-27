# Common.ps1 — shared helpers for BSOD-detector scripts.
# Requires: PowerShell 5.1+ (Windows). Dot-source this from each script:
#   . "$PSScriptRoot\lib\Common.ps1"
#
# Provides:
#   - $DataDir / $RepoRoot path resolution
#   - Get-BsodData      : load a data/*.json source-of-truth file
#   - Get-DumpPaths     : resolve where this guest actually writes crash dumps
#   - Write-JsonResult  : emit a single JSON object to stdout (the script contract)
#   - Fail              : write an error result to stdout and exit non-zero
#
# Convention: every script prints exactly ONE JSON object to stdout. Diagnostic
# chatter goes to the *information*/*error* streams (Write-Host / Write-Error),
# never to stdout, so downstream consumers can parse stdout as pure JSON.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# src/scripts/lib/Common.ps1 -> app root (apps/bsod-detector) is three levels up.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:DataDir  = Join-Path $script:RepoRoot 'src\data'

function Get-BsodData {
    <#
    .SYNOPSIS Load a source-of-truth JSON file from data/.
    .PARAMETER Name File name under data/, e.g. 'bugcheck-codes.json'.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:DataDir $Name
    if (-not (Test-Path $path)) { throw "Data file not found: $path" }
    Get-Content -Raw -Path $path | ConvertFrom-Json
}

function Get-DumpPaths {
    <#
    .SYNOPSIS
        Resolve where this Windows guest actually writes crash dumps.
    .DESCRIPTION
        Reads the live CrashControl config (DumpFile / MinidumpDir /
        DedicatedDumpFile) and falls back to the OS defaults when a value is unset.
        For a NATURALLY-occurring BSOD we never pre-configured the VM, so the dump
        may not be at the default %SystemRoot% location (enterprise images sometimes
        relocate DumpFile or use a DedicatedDumpFile on another volume). Collectors
        should look where the VM is configured to write, not assume C:\Windows.
    .OUTPUTS
        [pscustomobject] with DumpFile, MinidumpDir, DedicatedDumpFile (or $null).
    #>
    $ccPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    $cc = Get-ItemProperty -Path $ccPath -ErrorAction SilentlyContinue

    function Read-CcValue {
        param([string]$Name)
        if ($cc -and ($cc.PSObject.Properties.Name -contains $Name)) {
            $v = $cc.$Name
            if ($v -is [string] -and $v.Trim()) {
                return [Environment]::ExpandEnvironmentVariables($v)
            }
        }
        return $null
    }

    $dumpFile = Read-CcValue 'DumpFile'
    if (-not $dumpFile) { $dumpFile = Join-Path $env:SystemRoot 'MEMORY.DMP' }
    $miniDir = Read-CcValue 'MinidumpDir'
    if (-not $miniDir) { $miniDir = Join-Path $env:SystemRoot 'Minidump' }

    [pscustomobject]@{
        DumpFile          = $dumpFile
        MinidumpDir       = $miniDir
        DedicatedDumpFile = Read-CcValue 'DedicatedDumpFile'
    }
}

function Write-JsonResult {
    <#
    .SYNOPSIS Emit the script's single JSON result object to stdout.
    .PARAMETER Object The object to serialize.
    #>
    param([Parameter(Mandatory)]$Object)
    $Object | ConvertTo-Json -Depth 12
}

function Fail {
    <#
    .SYNOPSIS Emit a structured error result to stdout and exit non-zero.
    #>
    param([Parameter(Mandatory)][string]$Message, [int]$ExitCode = 1)
    Write-JsonResult ([ordered]@{
        ok      = $false
        error   = $Message
        script  = (Split-Path -Leaf $MyInvocation.ScriptName)
    })
    exit $ExitCode
}

function Test-IsAdministrator {
    <# .SYNOPSIS Return $true if the current process is running elevated (Administrator). #>
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
