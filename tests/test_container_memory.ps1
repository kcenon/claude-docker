# test_container_memory.ps1 — Node heap limit arithmetic parity for the
# PowerShell layer (issue #335, stage 5).
#
# Run:  pwsh -NoProfile -File tests/test_container_memory.ps1
# Exits non-zero on any failure.
#
# The bash side is covered by tests/test_container_memory.sh. This file exists
# because a Windows user and a Linux user configuring the same repository must
# get the same heap: the two implementations are independent, and the ways they
# can drift are quiet ones. Both parse a byte value by hand, and PowerShell
# differs from bash in exactly the places this arithmetic touches -- a [long]
# cast rounds half to even where bash truncates, [int] overflows at 2 GiB where
# bash does not, and a regex group that did not participate is absent from
# $Matches rather than present and empty. Each of those produces a number
# rather than an error, so the tables below are deliberately the same tables
# the bash test asserts.
#
# Generator sequencing is asserted on the bash side only: generate-compose.ps1
# is Windows-only by design, and this suite runs on Linux in CI.
#
# Every value here is a size; no test writes or prints a credential.

param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $ProjectRoot 'scripts' 'ClaudeDocker.psm1') -Force

$script:Pass = 0
$script:Fail = 0

function Assert-Eq {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object]$Expected,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object]$Actual
    )
    if ([string]$Expected -eq [string]$Actual) {
        Write-Host ("  PASS  {0}" -f $Label)
        $script:Pass++
    } else {
        Write-Host ("  FAIL  {0}`n        expected: {1}`n        actual:   {2}" -f `
            $Label, ([string]$Expected), ([string]$Actual))
        $script:Fail++
    }
}

function Assert-Throws {
    <#
    .SYNOPSIS
    Assert that an action throws, and that it throws the error meant.
    .DESCRIPTION
    -MessageLike is mandatory. Without it these eight cases passed on *any*
    terminating error, including a parameter-binding failure from a renamed
    parameter -- so a refusal that never reached the validation it was testing
    counted as the validation working (#354, item 9).

    test_isolation_modes.ps1's helper already had this shape; this one is
    brought in line with it, and the two hand-written try/catch blocks at the
    end of this file that compare messages collapse into it.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$MessageLike
    )
    try {
        & $Action | Out-Null
        Write-Host ("  FAIL  {0}`n        expected a terminating error, got none" -f $Label)
        $script:Fail++
    }
    catch {
        if ($_.Exception.Message -like $MessageLike) {
            Write-Host ("  PASS  {0}" -f $Label)
            $script:Pass++
        } else {
            Write-Host ("  FAIL  {0}`n        threw, but the message did not match '{1}'`n        actual: {2}" -f `
                $Label, $MessageLike, $_.Exception.Message)
            $script:Fail++
        }
    }
}

Write-Host '== ConvertTo-MebibyteCount =='

# The accepted syntax is not this project's invention: it is what Docker's own
# go-units parser takes for deploy.resources.limits.memory. Narrowing it here
# and not in bash, or the other way round, makes the same .env generate on one
# platform and fail on the other.
# A list of pairs rather than a hashtable: PowerShell hash literal keys are
# case-insensitive, so '4G' and '4g' would collide -- in the very table whose
# purpose is asserting that case does not change the result.
$accepted = @(
    @('4G', 4096),
    @('4g', 4096),
    @('4GB', 4096),
    @('4gb', 4096),
    @('4GiB', 4096),
    @('4 G', 4096),
    @('4096m', 4096),
    @('4096M', 4096),
    @('4194304k', 4096),
    @('4294967296', 4096),
    @('4294967296b', 4096),
    @('1.5G', 1536),
    @('0.5G', 512),
    @('2.25G', 2304),
    # Not extra coverage of the same thing. 1.08G pins base-10 reading of the
    # fraction -- its bash mirror would read 08 as an invalid octal literal
    # without an explicit prefix -- and 1.9999G pins the documented precision
    # cap: the fraction is truncated to three digits, so it resolves the same
    # as 1.999G rather than overflowing at the largest accepted unit.
    @('1.08G', 1105),
    @('1.9999G', 2046),
    @('1T', 1048576),
    @('1536k', 1)
)
foreach ($case in $accepted) {
    Assert-Eq ("parse: {0} -> {1} MiB" -f $case[0], $case[1]) `
        $case[1] (ConvertTo-MebibyteCount -Value $case[0])
}

# Rejected inputs return $null rather than throwing, so the caller can name the
# key the value came from. The wrong number here would be worse than no number:
# it silently moves the cap the heap is validated against.
foreach ($bad in @('', 'bogus', '-1', '4x', '4bb', 'G4', '4G4', '1..5G', '4,096m')) {
    Assert-Eq ("parse: '{0}' rejected" -f $bad) $true `
        ($null -eq (ConvertTo-MebibyteCount -Value $bad))
}

Write-Host '== Get-NodeHeapHeadroomMib =='

# The floor is what makes small caps safe: a flat 25% would leave 256 MiB of a
# 1 GiB container for everything that is not the JavaScript heap, and the fixed
# costs -- V8 itself, the runtime's node processes, git -- do not shrink with
# the cap.
Assert-Eq 'headroom: floor applies at a 1024 MiB cap' 512 (Get-NodeHeapHeadroomMib -CapMib 1024)
Assert-Eq 'headroom: proportion applies at an 8192 MiB cap' 2048 (Get-NodeHeapHeadroomMib -CapMib 8192)

Write-Host '== Resolve-NodeHeapMib =='

$derived = @(
    @('1G', 512),
    @('2G', 1536),
    @('4G', 3072),
    @('8G', 6144),
    @('16G', 12288),
    @('1024m', 512),
    @('513m', 1)
)
foreach ($case in $derived) {
    Assert-Eq ("derive: cap {0} -> heap {1} MiB" -f $case[0], $case[1]) `
        $case[1] (Resolve-NodeHeapMib -MemLimit $case[0])
}

# A cap at or below the headroom floor has no valid heap at all. The message
# has to name CONTAINER_MEM_LIMIT, because that is the key the user edits.
foreach ($cap in @('512m', '256m')) {
    Assert-Throws ("derive: cap {0} refused" -f $cap) `
        { Resolve-NodeHeapMib -MemLimit $cap } '*CONTAINER_MEM_LIMIT*'
}
Assert-Throws 'derive: unparseable cap refused' `
    { Resolve-NodeHeapMib -MemLimit 'four-gigs' } '*CONTAINER_MEM_LIMIT*'

# An explicitly configured heap is used as given when it fits, and refused when
# it does not. The boundary is exact on purpose: one MiB either side of it
# decides whether a stack is generated at all.
Assert-Eq 'explicit: 3584 MiB accepted at a 4G cap (exactly 512 MiB headroom)' `
    3584 (Resolve-NodeHeapMib -MemLimit '4G' -ConfiguredHeapMb '3584')
Assert-Throws 'explicit: 3585 MiB refused at a 4G cap (511 MiB headroom)' `
    { Resolve-NodeHeapMib -MemLimit '4G' -ConfiguredHeapMb '3585' } '*CONTAINER_NODE_HEAP_MB*'
foreach ($bad in @('0', '-512', 'abc', '3.5')) {
    Assert-Throws ("explicit: heap '{0}' rejected" -f $bad) `
        { Resolve-NodeHeapMib -MemLimit '4G' -ConfiguredHeapMb $bad } '*CONTAINER_NODE_HEAP_MB*'
}

# The diagnostic has to name the key the user changes. A refusal that says only
# "invalid" leaves them editing the wrong line. These were two hand-written
# try/catch blocks doing what Assert-Throws now does.
Assert-Throws 'diagnostic: names CONTAINER_NODE_HEAP_MB' `
    { Resolve-NodeHeapMib -MemLimit '4G' -ConfiguredHeapMb '4096' } '*CONTAINER_NODE_HEAP_MB*'
Assert-Throws 'diagnostic: names CONTAINER_MEM_LIMIT' `
    { Resolve-NodeHeapMib -MemLimit '384m' } '*CONTAINER_MEM_LIMIT*'

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
