# test_cleanup_gate.ps1 - the confirmation gate and age rule cleanup.ps1
# applies before deleting .env backups (issue #345).
#
# Run:  pwsh -NoProfile -File tests/test_cleanup_gate.ps1
# Exits non-zero on any failure.
#
# `cleanup.ps1 -Backups` used to delete .env.backup.* and .env.bak the moment
# the switch was passed, while cleanup.sh refused to touch the same files
# without an explicit answer. Those files are the only recovery point for a
# .env carrying API keys and GitHub tokens.
#
# The policy and the age rule are asserted through the two module functions
# both scripts route through, not by running cleanup.ps1: that script stops
# containers, removes volumes and deletes state directories, so invoking it
# from a test would operate on the checkout it lives in. The one thing that
# can only be observed on the file itself -- the ValidateRange bound, which
# fires at parameter binding rather than in any function -- is read out of the
# script's syntax tree instead.
#
# Every value here is a placeholder; no test writes or prints a credential.

param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ScriptsDir = Join-Path $ProjectRoot 'scripts'

Import-Module (Join-Path $ScriptsDir 'ClaudeDocker.psm1') -Force

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

Write-Host '== Get-CleanupDecision =='

# -Force wins over everything, including a host that could have been asked:
# it is the explicit non-interactive answer.
Assert-Eq 'Force removes, interactive' 'remove' `
    (Get-CleanupDecision -Force $true -Skip $false -Interactive $true)
Assert-Eq 'Force removes, non-interactive' 'remove' `
    (Get-CleanupDecision -Force $true -Skip $false -Interactive $false)

Assert-Eq 'Skip skips, interactive' 'skip' `
    (Get-CleanupDecision -Force $false -Skip $true -Interactive $true)
Assert-Eq 'Skip skips, non-interactive' 'skip' `
    (Get-CleanupDecision -Force $false -Skip $true -Interactive $false)

Assert-Eq 'neither switch on a console asks' 'ask' `
    (Get-CleanupDecision -Force $false -Skip $false -Interactive $true)

# Refusing rather than skipping is the point: a pipeline that meant to clean
# up and quietly did not is its own failure, so the caller is told to choose.
# Defaulting the other way -- proceeding -- would delete the backups.
Assert-Eq 'neither switch off a console refuses' 'refuse' `
    (Get-CleanupDecision -Force $false -Skip $false -Interactive $false)

Write-Host '== Test-FileAgeExceedsDays: parity with find -mtime +N =='

$now = [datetime]'2026-08-16T12:00:00'

# The case the two implementations used to disagree on. `find -mtime +7`
# truncates the age to whole days, so 7.5 days reports 7 and is kept; the old
# PowerShell comparison against an exact now-minus-7d instant deleted it.
# tests/test_cleanup_backups.sh pins the same verdict against real find(1).
Assert-Eq '7.5 days is not older than 7' $false `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddHours(-180) -Now $now -Days 7)
Assert-Eq '8 days is older than 7' $true `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddDays(-8) -Now $now -Days 7)

# Exactly N days is not "more than N", matching find.
Assert-Eq 'exactly 7 days is not older than 7' $false `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddDays(-7) -Now $now -Days 7)
Assert-Eq '7 days plus a second is still not older than 7' $false `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddDays(-7).AddSeconds(-1) -Now $now -Days 7)

Assert-Eq 'a fresh file is never stale' $false `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddMinutes(-1) -Now $now -Days 7)
Assert-Eq '30 days is older than 7' $true `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddDays(-30) -Now $now -Days 7)

# Days = 0 means the same as `find -mtime +0`: at least a whole day old. It is
# an accepted value on both sides, so the two must agree on it.
Assert-Eq 'Days=0 keeps a file younger than a day' $false `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddHours(-23) -Now $now -Days 0)
Assert-Eq 'Days=0 removes a file older than a day' $true `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddHours(-25) -Now $now -Days 0)

# A future mtime yields a negative age, which must not read as stale.
Assert-Eq 'a future timestamp is not stale' $false `
    (Test-FileAgeExceedsDays -LastWriteTime $now.AddDays(1) -Now $now -Days 7)

Write-Host '== cleanup.ps1: the bound on -BackupAgeDays =='

# Read from the syntax tree rather than by invoking the script. ValidateRange
# fires at parameter binding, so observing it means starting cleanup.ps1 --
# which on a Windows host would go on to stop containers and remove volumes in
# whatever checkout the test runs from.
$cleanupPath = Join-Path $ScriptsDir 'cleanup.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $cleanupPath, [ref]$null, [ref]$parseErrors)
Assert-Eq 'cleanup.ps1 parses' 0 (@($parseErrors).Count)

$ageParam = $ast.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'BackupAgeDays' }
Assert-Eq 'BackupAgeDays is declared' 1 (@($ageParam).Count)

$range = @($ageParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' })
Assert-Eq 'BackupAgeDays carries ValidateRange' 1 $range.Count

if ($range.Count -eq 1) {
    $bounds = @($range[0].PositionalArguments | ForEach-Object { $_.Value })
    # A negative value would put the cutoff in the future and sweep every
    # backup; the upper bound matches the one cleanup.sh now enforces.
    Assert-Eq 'lower bound is 0'    0    $bounds[0]
    Assert-Eq 'upper bound is 3650' 3650 $bounds[1]
}

Write-Host '== cleanup.ps1: one gate, both destructive steps =='

# The defect was one script carrying two policies: state-directory removal was
# gated, backup removal was not. Both now call the same helper, so a future
# edit that reintroduces a private copy fails here.
$source = Get-Content -LiteralPath $cleanupPath -Raw
$gateCalls = ([regex]::Matches($source, 'Resolve-Step -Question')).Count
Assert-Eq 'both destructive steps call the shared gate' 2 $gateCalls
Assert-Eq 'the gate delegates to Get-CleanupDecision' $true `
    ($source -like '*Get-CleanupDecision*')
Assert-Eq 'the backup sweep uses the shared age rule' $true `
    ($source -like '*Test-FileAgeExceedsDays*')
# The exact-instant cutoff this replaces must be gone, not merely unused.
Assert-Eq 'the exact-instant cutoff is gone' $false `
    ($source -like '*AddDays(-$BackupAgeDays)*')

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
