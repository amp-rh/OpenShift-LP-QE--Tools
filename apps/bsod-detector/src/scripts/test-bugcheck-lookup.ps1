<#
.SYNOPSIS
    Test that the collector's bug-check parsing and lookup resolves every code
    in bugcheck-codes.json. Exercises the exact regex + normalization logic from
    collect-guest.ps1 against synthetic WER event messages.

.DESCRIPTION
    For each code in data/bugcheck-codes.json, fabricates a realistic WER 1001
    message string, runs the same regex and normalization that collect-guest.ps1
    uses, and verifies the code resolves to the expected name.

    This is a data-integrity and parsing test — it does not require a real BSOD
    or any event log entries.

.OUTPUTS
    A single JSON object to stdout:
    {
      "ok": true|false,
      "totalCodes": 25,
      "passed": 25,
      "failed": 0,
      "results": [ { "code": "0x...", "expectedName": "...", "resolvedName": "...", "pass": true }, ... ]
    }
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib\Common.ps1"

$codes = (Get-BsodData 'bugcheck-codes.json').codes
$results = New-Object System.Collections.Generic.List[object]
$passed = 0
$failed = 0

foreach ($codeKey in ($codes.PSObject.Properties.Name | Sort-Object)) {
    $entry = $codes.$codeKey
    $expectedName = $entry.name

    # Fabricate a realistic WER System/1001 message using the code.
    # Real example: "The computer has rebooted from a bugcheck. The bugcheck was: 0x000000d1 (0xffff..., 0x0000..., 0x0000..., 0xfffff...). A dump was saved in: ..."
    # Use lowercase hex in the message (as Windows actually writes it) to test normalization.
    $lowerCode = '0x' + $codeKey.Substring(2).ToLower()
    $fakeMessage = "The computer has rebooted from a bugcheck. The bugcheck was: $lowerCode (0xdeadbeef00000001, 0x0000000000000002, 0x0000000000000000, 0xfffff80000000003). A dump was saved in: C:\WINDOWS\Minidump\test.dmp."

    # === Exact logic from collect-guest.ps1 lines ~100-115 ===
    $resolvedCode = $null
    $resolvedName = $null
    $params = @()

    $codeMatch = [regex]::Match($fakeMessage, 'bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)')
    if (-not $codeMatch.Success) {
        $codeMatch = [regex]::Match($fakeMessage, '(0x[0-9a-fA-F]{8})')
    }
    if ($codeMatch.Success) {
        $norm = '0x' + $codeMatch.Groups[1].Value.Substring(2).ToUpper().PadLeft(8, '0')
        $resolvedCode = $norm
        if ($codes.PSObject.Properties.Name -contains $norm) {
            $resolvedName = $codes.$norm.name
        }
        if ($codeMatch.Groups.Count -gt 2 -and $codeMatch.Groups[2].Success) {
            $params = @(($codeMatch.Groups[2].Value -split ',') | ForEach-Object { $_.Trim() })
        }
    }

    $pass = ($resolvedCode -eq $codeKey) -and ($resolvedName -eq $expectedName) -and ($params.Count -eq 4)
    if ($pass) { $passed++ } else { $failed++ }

    $results.Add([ordered]@{
        code            = $codeKey
        expectedName    = $expectedName
        resolvedCode    = $resolvedCode
        resolvedName    = $resolvedName
        parametersFound = $params.Count
        pass            = $pass
    })
}

# --- Real-world WER messages with actual crash parameters ---
# These are exact strings from production crashes, not synthetic data.
# They test that the regex handles real Windows event log formatting.
$realWorldCases = @(
    @{
        Label   = '0x3D real-world (netkvm ISR)'
        Code    = '0x0000003D'
        Name    = 'INTERRUPT_EXCEPTION_NOT_HANDLED'
        Message = 'The computer has rebooted from a bugcheck. The bugcheck was: 0x0000003d (0xfffff80376bc2cc8, 0xfffff80376bc2510, 0x0000000000000000, 0x0000000000000000). A dump was saved in: C:\WINDOWS\MEMORY.DMP.'
    }
    @{
        Label   = '0x20001 real-world (hypervisor)'
        Code    = '0x00020001'
        Name    = 'HYPERVISOR_ERROR'
        Message = 'The computer has rebooted from a bugcheck. The bugcheck was: 0x00020001 (0x0000000000000032, 0x0000000000000001, 0x0000000000000000, 0x0000000000000000). A dump was saved in: C:\WINDOWS\MEMORY.DMP.'
    }
    @{
        Label   = '0xC2 real-world (netkvm double-free)'
        Code    = '0x000000C2'
        Name    = 'BAD_POOL_CALLER'
        Message = 'The computer has rebooted from a bugcheck. The bugcheck was: 0x000000c2 (0x0000000000000007, 0x0000000000000000, 0x0000000000000000, 0xffffcf067cf551a0). A dump was saved in: C:\WINDOWS\MEMORY.DMP.'
    }
)

foreach ($case in $realWorldCases) {
    $codeMatch = [regex]::Match($case.Message, 'bugcheck was:\s*(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)')
    $resolvedCode = $null
    $resolvedName = $null
    $params = @()
    if ($codeMatch.Success) {
        $norm = '0x' + $codeMatch.Groups[1].Value.Substring(2).ToUpper().PadLeft(8, '0')
        $resolvedCode = $norm
        if ($codes.PSObject.Properties.Name -contains $norm) {
            $resolvedName = $codes.$norm.name
        }
        if ($codeMatch.Groups.Count -gt 2 -and $codeMatch.Groups[2].Success) {
            $params = @(($codeMatch.Groups[2].Value -split ',') | ForEach-Object { $_.Trim() })
        }
    }
    $pass = ($resolvedCode -eq $case.Code) -and ($resolvedName -eq $case.Name) -and ($params.Count -eq 4)
    if ($pass) { $passed++ } else { $failed++ }
    $results.Add([ordered]@{
        code            = $case.Code
        expectedName    = $case.Name
        resolvedCode    = $resolvedCode
        resolvedName    = $resolvedName
        parametersFound = $params.Count
        pass            = $pass
        label           = $case.Label
    })
}

Write-JsonResult ([ordered]@{
    ok         = ($failed -eq 0)
    totalCodes = $results.Count
    passed     = $passed
    failed     = $failed
    results    = $results
})
