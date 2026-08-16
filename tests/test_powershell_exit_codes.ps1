# test_powershell_exit_codes.ps1 - the PowerShell CLI reports what docker did
# (issue #355).
#
# Run:  pwsh -NoProfile -File tests/test_powershell_exit_codes.ps1
# Exits non-zero on any failure.
#
# Invoke-Compose ran docker and discarded the result, and the dispatch switch
# is the last statement in claude-docker.ps1, so every docker-backed
# subcommand fell off the end with rc=0 no matter what happened. "Containers
# started." printed after a missing image; "Build complete." after a failed
# build.
#
# $ErrorActionPreference = 'Stop' does not cover this -- a native command's
# non-zero exit is not a PowerShell error:
#
#   pwsh -NoProfile -Command "$ErrorActionPreference='Stop'; & cmd /c exit 7; 'reached'"
#   reached      <- caller sees rc=0
#
# The bash wrapper gets it from `set -euo pipefail`, which is why cmd_up can
# print its success line unguarded and still be correct.
#
# These assertions are structural. claude-docker.ps1 carries a Windows-only
# platform guard, so the CI runner cannot execute a single subcommand of it;
# running it on a Windows runner would mean driving docker from a test. What
# can be checked everywhere, and what actually regressed, is that no compose
# call is left unchecked and no success line is printed before its guard.

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

$cliPath = Join-Path $ScriptsDir 'claude-docker.ps1'
$lines = @(Get-Content -LiteralPath $cliPath)

Write-Host '== Every compose call is checked =='

# A call is "checked" when a Test-ComposeSucceeded appears within the next
# four lines -- wide enough for a blank line and a short comment explaining
# why the guard returns, narrow enough that the guard still has to belong to
# this call rather than to the next one.
$unchecked = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch '^\s*Invoke-Compose\s') { continue }
    $window = @($lines[($i + 1)..([math]::Min($i + 4, $lines.Count - 1))])
    if (-not ($window -match 'Test-ComposeSucceeded')) {
        $unchecked += ("line {0}: {1}" -f ($i + 1), $lines[$i].Trim())
    }
}
Assert-Eq 'no Invoke-Compose call is left unchecked' '' ($unchecked -join ' | ')

# The count is asserted too: a refactor that deleted the calls would satisfy
# the check above vacuously.
$composeCalls = @($lines | Where-Object { $_ -match '^\s*Invoke-Compose\s' }).Count
Assert-Eq 'the file still makes compose calls' $true ($composeCalls -ge 10)

Write-Host '== Success messages are gated on a zero exit =='

# Each of these used to print unconditionally. A guard must appear in the
# three lines before it.
$successLines = @(
    'Containers started.'
    'Containers stopped.'
    'Containers restarted.'
    'Build complete.'
)
foreach ($msg in $successLines) {
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like "*'$msg'*") { $idx = $i; break }
    }
    if ($idx -lt 0) {
        Assert-Eq "'$msg' is present" 'present' 'missing'
        continue
    }
    $before = @($lines[([math]::Max($idx - 3, 0))..($idx - 1)])
    Assert-Eq "'$msg' is preceded by a success guard" $true `
        ([bool]($before -match 'Test-ComposeSucceeded'))
}

Write-Host '== The script exits with what it recorded =='

Assert-Eq 'the exit-code variable is initialized' $true `
    ([bool]($lines -match '^\s*\$script:ExitCode\s*=\s*0\s*$'))
# The dispatch switch is the last statement, so this single line is what
# carries every branch's result out.
Assert-Eq 'the file ends by exiting with it' $true `
    ([bool]($lines -match '^\s*exit \$script:ExitCode\s*$'))
# The runtime subcommands return early, before the switch, and used to mask
# the agent's own exit code with a bare `return`.
$runtimeBranch = ($lines -join "`n")
Assert-Eq 'the runtime subcommand branch exits with it too' $true `
    ($runtimeBranch -match 'Invoke-Agent -Subcommand \$Command\s*\r?\n(\s*#[^\r\n]*\r?\n)*\s*exit \$script:ExitCode')

Write-Host '== setup-worktrees.ps1 stops when git refuses =='

# install.ps1 derives PROJECT_DIR_<X> from the repo path and writes it
# regardless of whether the worktree was created, so a silent `git worktree
# add` failure produced a bind source that does not exist.
$wtPath = Join-Path $ScriptsDir 'setup-worktrees.ps1'
$wt = Get-Content -LiteralPath $wtPath -Raw
Assert-Eq 'the worktree add result is checked' $true `
    ($wt -match 'git worktree add[^\r\n]*\r?\n(\s*#[^\r\n]*\r?\n)*\s*if \(\$LASTEXITCODE -ne 0\)')
Assert-Eq 'the failure throws rather than warning' $true `
    ($wt -match 'throw "git worktree add failed')

Write-Host '== scale validates before it mutates =='

# The bash half of this is exercised end to end by
# tests/test_scale_prevalidation.sh; here it is the PowerShell caller's shape.
$cli = $lines -join "`n"
$validateIdx = $cli.IndexOf('Get-SupportedIsolationMode -ProjectRoot $ProjectRoot -AccountCount $newCount')
$writeIdx = $cli.IndexOf("Set-EnvValue -Path `$envFile -Key 'NUM_ACCOUNTS'")
Assert-Eq 'scale calls the isolation check' $true ($validateIdx -ge 0)
Assert-Eq 'scale writes NUM_ACCOUNTS' $true ($writeIdx -ge 0)
if ($validateIdx -ge 0 -and $writeIdx -ge 0) {
    # Order is the whole point: the generator was already fail-closed, and the
    # caller moved first anyway.
    Assert-Eq 'the check happens before the write' $true ($validateIdx -lt $writeIdx)
}

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
