# index.ps1 — Shared account-index helpers (PowerShell port of lib/index.sh).
#
# Dot-source this file with:
#
#   . (Join-Path $PSScriptRoot 'lib' 'index.ps1')
#
# Provides:
#
#   Get-MaxAccountCount               the upper bound, 702 ("zz")
#   Get-NormalizedAccountCount -Value validated decimal count, or $null
#   Get-AccountLetter      -Index N   1-based index → Excel-style lowercase (a, z, aa, zz)
#   Get-AccountLetterUpper -Index N   1-based index → Excel-style uppercase (A, Z, AA, ZZ)
#
# Values 1-26 are bit-for-bit identical to the former single-letter
# implementation that used to live in each consumer.
#
# This file is the PowerShell side's single definition of the account-index
# rules, matching what scripts/lib/index.sh is for bash. It said so before
# #356 and shipped only two of the three functions index.sh declares shared,
# so the 1..702 rule was re-spelled in generate-compose.ps1, claude-docker.ps1,
# install.ps1 and setup-isolated.ps1 -- four copies of a bound that
# scripts/lib/index.sh had already been made the source of truth for.
# Get-NormalizedAccountCount closes that gap; no other PowerShell file should
# contain the literal 702.

# No re-source guard: PowerShell's `& file.ps1` runs each script in its own
# script scope (sibling, not child, of the caller — the common parent is
# global). A $Global guard set by install.ps1 would make generate-compose.ps1
# skip function definition entirely, leaving Get-AccountLetter unresolved.
# Function definitions are idempotent, so re-sourcing is a no-op anyway.

function Get-MaxAccountCount {
    <#
    .SYNOPSIS
    The highest account index the Excel-style letter scheme can name.
    .DESCRIPTION
    702 is "zz". Mirrors the bound in scripts/lib/index.sh's
    normalize_account_count and config.MaxAccounts in the Go reader.

    A function rather than a variable because a dot-sourced script's
    $Script: scope is the *caller's* script scope, so a variable defined here
    would be invisible to a module that dot-sources this file and then calls
    into it. Function definitions have no such problem.
    #>
    [CmdletBinding()]
    param()
    return 702
}

function Get-NormalizedAccountCount {
    <#
    .SYNOPSIS
    Validate and normalize an account count. Returns the integer, or $null
    when the value is unusable.
    .DESCRIPTION
    Mirrors normalize_account_count in scripts/lib/index.sh, including its
    tolerance for leading zeros: the bash regex is ^0*([0-9]{1,3})$ followed
    by a 10#-prefixed range test, so "008" is 8 and "0000" is 0 and therefore
    rejected. Four or more significant digits never match, which is what
    rejects 1000 before the range check is reached.

    $null rather than a throw, because every caller wants to print its own
    diagnostic naming the value the user typed -- the same shape as bash's
    non-zero return.
    .PARAMETER Value
    The raw value as the user or the environment supplied it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Value)

    if ($null -eq $Value -or $Value -notmatch '^0*([0-9]{1,3})$') { return $null }
    $n = [int]$Matches[1]
    if ($n -lt 1 -or $n -gt (Get-MaxAccountCount)) { return $null }
    return $n
}

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

    if ($Index -lt 1 -or $Index -gt (Get-MaxAccountCount)) {
        throw "Index $Index out of range (1..$(Get-MaxAccountCount))"
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

    if ($Index -lt 1 -or $Index -gt (Get-MaxAccountCount)) {
        throw "Index $Index out of range (1..$(Get-MaxAccountCount))"
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
