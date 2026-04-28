# index.ps1 — Shared account-index helpers (PowerShell port of lib/index.sh).
#
# Dot-source this file with:
#
#   . (Join-Path $PSScriptRoot 'lib' 'index.ps1')
#
# Provides:
#
#   Get-AccountLetter      -Index N   1-based index → Excel-style lowercase (a, z, aa, zz)
#   Get-AccountLetterUpper -Index N   1-based index → Excel-style uppercase (A, Z, AA, ZZ)
#
# Values 1-26 are bit-for-bit identical to the former single-letter
# implementation that used to live in each consumer. The upper bound 702
# matches scripts/install.ps1's NUM_ACCOUNTS validator.

# No re-source guard: PowerShell's `& file.ps1` runs each script in its own
# script scope (sibling, not child, of the caller — the common parent is
# global). A $Global guard set by install.ps1 would make generate-compose.ps1
# skip function definition entirely, leaving Get-AccountLetter unresolved.
# Function definitions are idempotent, so re-sourcing is a no-op anyway.

function Get-AccountLetter {
    <#
    .SYNOPSIS
    Convert a 1-based index to Excel-style lowercase letters (a, z, aa, zz).
    .DESCRIPTION
    Mirrors scripts/lib/index.sh's index_to_letter. Valid range is 1..702.
    Casts to [int] are required because [math]::Floor and `%` can return
    Double/Decimal, which will not implicit-cast to [char].
    .PARAMETER Index
    1-based account index in the range 1..702.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Index)

    if ($Index -lt 1 -or $Index -gt 702) {
        throw "Index $Index out of range (1..702)"
    }

    [int]$n = $Index
    $builder = ''
    while ($n -gt 0) {
        [int]$rem = ($n - 1) % 26
        $builder = [char]([int](97 + $rem)) + $builder
        [int]$n = [math]::Floor(($n - 1) / 26)
    }
    return $builder
}

function Get-AccountLetterUpper {
    <#
    .SYNOPSIS
    Convert a 1-based index to Excel-style uppercase letters (A, Z, AA, ZZ).
    .DESCRIPTION
    Mirrors scripts/lib/index.sh's index_to_upper. Valid range is 1..702.
    .PARAMETER Index
    1-based account index in the range 1..702.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Index)

    if ($Index -lt 1 -or $Index -gt 702) {
        throw "Index $Index out of range (1..702)"
    }

    [int]$n = $Index
    $builder = ''
    while ($n -gt 0) {
        [int]$rem = ($n - 1) % 26
        $builder = [char]([int](65 + $rem)) + $builder
        [int]$n = [math]::Floor(($n - 1) / 26)
    }
    return $builder
}
