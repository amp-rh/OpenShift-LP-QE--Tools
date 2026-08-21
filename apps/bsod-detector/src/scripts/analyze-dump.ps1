<#
.SYNOPSIS
    Symbolize a Windows crash dump and extract bucket ID, faulting image, and
    the top call-stack frames.

.DESCRIPTION
    Wraps the Windows debugger (cdb.exe, part of the Debugging Tools for Windows)
    to run `!analyze -v` against a MEMORY.DMP or minidump. Parses the output into
    structured JSON: the failure bucket, IMAGE_NAME (faulting module), MODULE_NAME,
    bugcheck code + parameters, and the top stack frames.

    This is the "deep analysis" step that collect-guest.ps1 intentionally leaves
    out: header parsing gives you the stop code, but only symbolized !analyze -v
    gives the bucket / image attribution (e.g. 0x7a_c0000185_DUMP_VIOSTOR ->
    viostor.sys, or PAGE_HASH_ERRORS_0x1a_3f) needed for root-cause attribution.

    Produces facts only; deciding whether an image is the true culprit vs. an
    I/O-completion attribution is the agent's job.

    Runs on: any Windows host with cdb.exe. Symbols are resolved from the symbol
    path (defaults to the Microsoft public symbol server).

.PARAMETER DumpPath
    Path to the .dmp file to analyze (required).

.PARAMETER CdbPath
    Full path to cdb.exe. Defaults to '' meaning "search the standard install
    locations and PATH".

.PARAMETER SymbolPath
    _NT_SYMBOL_PATH-style symbol path. Defaults to the Microsoft public symbol
    server cached under the output dir.

.PARAMETER OutputDir
    Where to write the raw !analyze -v log. Defaults to <repo>\output\analyze-<timestamp>.

.OUTPUTS
    A single JSON object to stdout:
    {
      "ok": true,
      "dump": "...\\MEMORY.DMP",
      "analyzedAt": "...Z",
      "bugCheckCode": "0x0000007A",
      "bugCheckName": "KERNEL_DATA_INPAGE_ERROR",   # from bugcheck-codes.json
      "parameters": ["0x...", "0x...", "0x...", "0x..."],
      "failureBucket": "0x7a_c0000185_DUMP_VIOSTOR",
      "imageName": "viostor.sys",
      "moduleName": "viostor",
      "faultingModule": "viostor.sys",
      "stack": ["nt!KeBugCheckEx", "nt!MiWaitForInPageComplete", ...],
      "rawLog": "...\\output\\analyze-...\\analyze.txt",
      "warnings": [ ... ]
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DumpPath,
    [string]$CdbPath = '',
    [string]$SymbolPath = '',
    [string]$OutputDir
)

. "$PSScriptRoot\lib\Common.ps1"

$warnings = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path $DumpPath)) { Fail "Dump file not found: $DumpPath" 2 }

# 1. Locate cdb.exe.
function Find-Cdb {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path $Explicit) { return $Explicit }
        throw "cdb.exe not found at -CdbPath '$Explicit'"
    }
    $onPath = Get-Command cdb.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\11\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles}\Windows Kits\11\Debuggers\x64\cdb.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    throw "cdb.exe not found. Install 'Debugging Tools for Windows' (Windows SDK) or pass -CdbPath."
}

try { $cdb = Find-Cdb -Explicit $CdbPath } catch { Fail $_.Exception.Message 3 }

# 2. Resolve output dir + symbol path.
if (-not $OutputDir) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $OutputDir = Join-Path $script:RepoRoot "output\analyze-$stamp"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (-not $SymbolPath) {
    $symCache = Join-Path $OutputDir 'symbols'
    $SymbolPath = "srv*$symCache*https://msdl.microsoft.com/download/symbols"
}
$rawLog = Join-Path $OutputDir 'analyze.txt'

# 3. Run cdb with !analyze -v.
#    -z <dump>  open the crash dump
#    -y <sym>   symbol path
#    -c "..."   commands to run, then quit
$cdbCommand = '!analyze -v; q'
try {
    & $cdb -z $DumpPath -y $SymbolPath -c $cdbCommand *> $rawLog
} catch {
    $warnings.Add("cdb invocation raised: $($_.Exception.Message)")
}
if (-not (Test-Path $rawLog) -or ((Get-Item $rawLog).Length -eq 0)) {
    Fail "cdb produced no output (see $rawLog). Check the dump and symbol path." 4
}
$log = Get-Content -Raw -Path $rawLog

# 4. Parse the structured fields out of !analyze -v output.
$codes = (Get-BsodData 'bugcheck-codes.json').codes

function Get-Field {
    param([string]$Text, [string]$Name)
    $m = [regex]::Match($Text, "(?m)^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
}

$failureBucket = Get-Field $log 'FAILURE_BUCKET_ID'
$imageName     = Get-Field $log 'IMAGE_NAME'
$moduleName    = Get-Field $log 'MODULE_NAME'

# Bugcheck code: "Bugcheck code 0000007A" or "BugCheck 7A, {..}".
$bugCheckCode = $null
$parameters   = @()
$m = [regex]::Match($log, 'BugCheck\s+([0-9A-Fa-f]+),\s*\{([^}]*)\}')
if ($m.Success) {
    $bugCheckCode = '0x' + $m.Groups[1].Value.ToUpper().PadLeft(8, '0')
    $parameters = @(($m.Groups[2].Value -split ',') | ForEach-Object { '0x' + $_.Trim().TrimStart('0x','0X').ToLower() } | ForEach-Object { $_ })
} else {
    $m2 = [regex]::Match($log, '(?m)^\s*Bugcheck code\s+([0-9A-Fa-f]+)\s*$')
    if ($m2.Success) { $bugCheckCode = '0x' + $m2.Groups[1].Value.ToUpper().PadLeft(8, '0') }
}
# Normalize parameters from the "Arg1: ... Arg2: ..." block when present.
$argMatches = [regex]::Matches($log, '(?m)^\s*Arg\d:\s*([0-9a-fA-F`]+)')
if ($argMatches.Count -ge 1) {
    $parameters = @($argMatches | ForEach-Object { '0x' + ($_.Groups[1].Value -replace '`','') })
}

$bugCheckName = $null
if ($bugCheckCode -and ($codes.PSObject.Properties.Name -contains $bugCheckCode)) {
    $bugCheckName = $codes.$bugCheckCode.name
} elseif ($bugCheckCode) {
    $warnings.Add("Bug-check code $bugCheckCode not in bugcheck-codes.json; add it there.")
}

# 5. Extract the top call-stack frames (STACK_TEXT block).
$stack = New-Object System.Collections.Generic.List[string]
$stackBlock = [regex]::Match($log, '(?s)STACK_TEXT:\s*(.+?)\r?\n\r?\n')
if ($stackBlock.Success) {
    foreach ($line in ($stackBlock.Groups[1].Value -split "`n")) {
        # Frame lines end with module!symbol (+offset). Grab that token.
        $fm = [regex]::Match($line, '([A-Za-z0-9_]+!\S+?)(?:\+0x[0-9a-fA-F]+)?\s*$')
        if ($fm.Success) { $stack.Add($fm.Groups[1].Value) }
    }
}
if ($stack.Count -eq 0) {
    # Fallback: any module!symbol tokens in the file, deduped, first 15.
    $seen = @{}
    foreach ($tm in [regex]::Matches($log, '[A-Za-z0-9_]+![A-Za-z0-9_:]+')) {
        $t = $tm.Value
        if (-not $seen.ContainsKey($t)) { $seen[$t] = $true; $stack.Add($t) }
        if ($stack.Count -ge 15) { break }
    }
    if ($stack.Count -gt 0) { $warnings.Add('STACK_TEXT block not found; stack is a best-effort token scan.') }
}

if (-not $failureBucket) { $warnings.Add('FAILURE_BUCKET_ID not found; symbols may be incomplete.') }
if (-not $imageName)     { $warnings.Add('IMAGE_NAME not found; symbols may be incomplete.') }

# 6. Emit the single JSON result.
Write-JsonResult ([ordered]@{
    ok             = $true
    dump           = (Resolve-Path $DumpPath).Path
    analyzedAt     = (Get-Date).ToUniversalTime().ToString('o')
    bugCheckCode   = $bugCheckCode
    bugCheckName   = $bugCheckName
    parameters     = $parameters
    failureBucket  = $failureBucket
    imageName      = $imageName
    moduleName     = $moduleName
    faultingModule = $imageName
    stack          = $stack
    rawLog         = $rawLog
    warnings       = $warnings
})
