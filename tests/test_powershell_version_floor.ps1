# test_powershell_version_floor.ps1 - the repository declares one PowerShell
# floor and every entry point agrees with it (issues #348, #349).
#
# Run:  pwsh -NoProfile -File tests/test_powershell_version_floor.ps1
# Exits non-zero on any failure.
#
# The tree used to say two things at once. Nine scripts carried
# `#Requires -Version 5.1` and README advertised "PowerShell 5.1+", while four
# dot-source lines passed three positional arguments to Join-Path -- binding to
# -AdditionalChildPath, which exists only in PowerShell 6+. On 5.1 the binder
# threw before the script did any work. Nothing caught it: every PowerShell CI
# step invokes `pwsh`, so the declared floor was never the interpreter under
# test.
#
# Per the decision recorded on #348, the floor is PowerShell 7 and 5.1 is not
# supported. These assertions are static: they read the sources rather than
# running the entry points, because running install.ps1 or cleanup.ps1 to
# observe a #Requires header would mean running an installer or a remover.
#
# What this cannot check is the interpreter itself -- a CI job invoking `pwsh`
# proves 7 works, not that 5.1 is refused. What it can check, and what actually
# regressed here, is that no part of the tree quietly re-advertises 5.1.

param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ScriptsDir = Join-Path $ProjectRoot 'scripts'

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

$RequiredFloor = '7.0'

Write-Host '== Every PowerShell source declares the same floor =='

# -Recurse so a new script under scripts/lib/ is covered without editing a
# list here. A file with no #Requires at all is reported rather than skipped:
# an entry point that inherits nothing is how a 5.1 user reaches a parse error
# instead of a version message.
$psFiles = @(Get-ChildItem -Path $ScriptsDir -Recurse -File -Include '*.ps1', '*.psm1' |
    Sort-Object FullName)

Assert-Eq 'PowerShell sources were found' $true ($psFiles.Count -gt 0)

$missing = @()
$wrong = @()
foreach ($f in $psFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    $m = [regex]::Match($text, '(?m)^#Requires\s+-Version\s+(\S+)')
    $rel = $f.FullName.Substring($ProjectRoot.Length + 1) -replace '\\', '/'
    if (-not $m.Success) {
        $missing += $rel
    } elseif ($m.Groups[1].Value -ne $RequiredFloor) {
        $wrong += ("{0} declares {1}" -f $rel, $m.Groups[1].Value)
    }
}

Assert-Eq "no source declares a floor other than $RequiredFloor" '' ($wrong -join '; ')

# lib/*.ps1 files are dot-sourced into a caller that already declared the
# floor, so they are listed rather than failed -- but they are listed, so a
# new *entry point* without a header is visible instead of silent.
if ($missing.Count -gt 0) {
    Write-Host ("  NOTE  no #Requires header (dot-sourced libraries): {0}" -f ($missing -join ', '))
}

Write-Host '== The cmd wrapper launches the supported interpreter =='

# claude-docker.cmd is the one entry point that chooses an interpreter rather
# than being run by one. `powershell` is always Windows PowerShell 5.1, so a
# bare `powershell` here sends every cmd.exe user straight into the floor it
# cannot meet.
$cmdPath = Join-Path $ScriptsDir 'claude-docker.cmd'
$cmdText = Get-Content -LiteralPath $cmdPath -Raw

Assert-Eq 'claude-docker.cmd invokes pwsh' $true `
    ($cmdText -match '(?m)^\s*pwsh\s')
Assert-Eq 'claude-docker.cmd does not invoke powershell' $false `
    ($cmdText -match '(?m)^\s*powershell(\.exe)?\s')
# pwsh is not guaranteed present on Windows the way powershell is, so its
# absence has to be reported rather than left to cmd's "not recognized".
Assert-Eq 'claude-docker.cmd checks that pwsh exists' $true `
    ($cmdText -match 'where\s+/q\s+pwsh')

Write-Host '== Guidance never points at the unsupported interpreter =='

# The bash platform guards tell a Windows user which PowerShell script to run
# instead. Naming `powershell` there routes them into the interpreter the
# #Requires headers now refuse -- a failure caused by the error message that
# was meant to help.
$guidance = @()
foreach ($f in (Get-ChildItem -Path $ScriptsDir -Recurse -File -Include '*.sh', '*.ps1', '*.psm1', '*.cmd')) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    if ($text -match 'powershell\s+-ExecutionPolicy') {
        $guidance += ($f.FullName.Substring($ProjectRoot.Length + 1) -replace '\\', '/')
    }
}
Assert-Eq 'no script suggests `powershell -ExecutionPolicy`' '' ($guidance -join '; ')

$readme = Get-Content -LiteralPath (Join-Path $ProjectRoot 'README.md') -Raw
Assert-Eq 'README does not suggest `powershell -ExecutionPolicy`' $false `
    ($readme -match 'powershell\s+-ExecutionPolicy')
Assert-Eq 'README does not advertise a 5.1 floor' $false `
    ($readme -match 'PowerShell 5\.1\+')

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
