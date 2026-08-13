# test_isolation_modes.ps1 — ISOLATION_MODE contract parity for the PowerShell
# layer (issue #335, stages 1 to 4).
#
# Run:  pwsh -NoProfile -File tests/test_isolation_modes.ps1
# Exits non-zero on any failure.
#
# The bash side is covered by tests/test_isolation_modes.sh. This file exists
# because a Windows user and a Linux user configuring the same repository must
# get the same trust boundary: the two implementations are independent, so
# agreement is a property that has to be asserted rather than assumed.
#
# Resolved-mount assertions live only on the bash side. They need the compose
# generator, which refuses to run on Windows by design, and the merge behavior
# under test is Compose's rather than either script's.
#
# Every value here is a placeholder; no test writes or prints a credential.

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
            Write-Host ("  FAIL  {0}`n        message did not match '{1}'`n        actual: {2}" -f `
                $Label, $MessageLike, $_.Exception.Message)
            $script:Fail++
        }
    }
}

# New-Sandbox LINES -- project root with a placeholder .env, returned as a path.
# Each case gets its own directory so a stale .env cannot leak between cases.
$script:Sandboxes = @()
function New-Sandbox {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("cd-isolation-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:Sandboxes += $dir
    if ($Lines.Count -gt 0) {
        Set-Content -Path (Join-Path $dir '.env') -Value $Lines -Encoding utf8
    }
    return $dir
}

# The environment must not leak into resolution: an ISOLATION_MODE left in the
# caller's shell outranks .env by design, which would silently rewrite what
# every case below means.
$savedMode = [Environment]::GetEnvironmentVariable('ISOLATION_MODE')
$savedProjectDirA = [Environment]::GetEnvironmentVariable('PROJECT_DIR_A')
$savedIsolatedA = [Environment]::GetEnvironmentVariable('ISOLATED_WORKSPACE_A')
$savedNetworkMode = [Environment]::GetEnvironmentVariable('ISOLATED_NETWORK_MODE')
$env:ISOLATION_MODE = ''
$env:PROJECT_DIR_A = ''
$env:ISOLATED_WORKSPACE_A = ''
$env:ISOLATED_NETWORK_MODE = ''

try {
    Write-Host '== Test-IsolationModeKnown =='
    foreach ($mode in @('shared', 'worktree', 'isolated')) {
        Assert-Eq "known: $mode" $true (Test-IsolationModeKnown -Mode $mode)
    }
    foreach ($mode in @('', 'bogus', 'Shared', 'per-account')) {
        Assert-Eq "not known: '$mode'" $false (Test-IsolationModeKnown -Mode $mode)
    }

    Write-Host '== Get-IsolationModeSummary =='
    # The worktree summary must keep saying the tier is not a security
    # boundary. That sentence is the only place a user is told what worktree
    # mode does not do, and the issue makes stating it an acceptance criterion.
    Assert-Eq 'worktree summary keeps its disclaimer' $true `
        ((Get-IsolationModeSummary -Mode 'worktree') -like '*not a security boundary*')
    # The isolated summary must state what the mode actually gives, and the
    # independent git metadata is the property that separates it from worktree.
    Assert-Eq 'isolated summary names the independent clone' $true `
        ((Get-IsolationModeSummary -Mode 'isolated') -like '*independent clone*')
    Assert-Eq 'isolated summary names its own git metadata' $true `
        ((Get-IsolationModeSummary -Mode 'isolated') -like '*own git metadata*')

    Write-Host '== Get-IsolationAccountVariable =='
    # One table drives validation, warnings and both generators, so the mapping
    # is asserted directly rather than only through its consumers.
    Assert-Eq 'worktree reads PROJECT_DIR_<X>' 'PROJECT_DIR_B' `
        (Get-IsolationAccountVariable -Mode 'worktree' -Upper 'B')
    Assert-Eq 'isolated reads ISOLATED_WORKSPACE_<X>' 'ISOLATED_WORKSPACE_B' `
        (Get-IsolationAccountVariable -Mode 'isolated' -Upper 'B')
    Assert-Eq 'shared reads no per-account path' '' `
        (Get-IsolationAccountVariable -Mode 'shared' -Upper 'B')

    Write-Host '== Get-IsolationMode: resolution order =='
    Assert-Eq 'no .env at all defaults to shared' 'shared' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @()))

    Assert-Eq 'plain .env defaults to shared' 'shared' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @('PROJECT_DIR=/tmp/p')))

    # Installs predating the key configured Tier B with PROJECT_DIR_A alone.
    # Losing this inference would move every one of them onto the shared mount.
    Assert-Eq 'PROJECT_DIR_A alone infers worktree' 'worktree' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @('PROJECT_DIR=/tmp/p', 'PROJECT_DIR_A=/tmp/wt-a')))

    Assert-Eq 'explicit worktree' 'worktree' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @('ISOLATION_MODE=worktree', 'PROJECT_DIR_A=/tmp/wt-a')))

    Assert-Eq 'explicit shared outranks the inference' 'shared' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @('ISOLATION_MODE=shared', 'PROJECT_DIR_A=/tmp/wt-a')))

    Assert-Eq 'case-insensitive' 'worktree' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @('ISOLATION_MODE=WorkTree')))

    $sharedRoot = New-Sandbox @('ISOLATION_MODE=shared')
    $env:ISOLATION_MODE = 'worktree'
    Assert-Eq 'environment outranks .env' 'worktree' (Get-IsolationMode -ProjectRoot $sharedRoot)
    $env:ISOLATION_MODE = ''

    Write-Host '== Test-IsolatedNetworkModeKnown =='
    foreach ($netMode in @('bridge', 'none')) {
        Assert-Eq "network known: $netMode" $true (Test-IsolatedNetworkModeKnown -Mode $netMode)
    }
    # 'Bridge' is rejected on purpose: the bash `case` is case-sensitive, so
    # accepting it here would let a Windows user configure a value the Linux
    # generator refuses -- the asymmetry this contract exists to prevent.
    foreach ($netMode in @('', 'bogus', 'Bridge', 'internal')) {
        Assert-Eq "network not known: '$netMode'" $false (Test-IsolatedNetworkModeKnown -Mode $netMode)
    }

    Write-Host '== Get-IsolatedNetworkModeSummary =='
    # bridge is the one whose limits are easy to overstate: it separates the
    # accounts from each other, it does not restrict what they can reach
    # outside. The summary has to say the first part without implying the
    # second.
    Assert-Eq 'bridge summary says outbound access still works' $true `
        ((Get-IsolatedNetworkModeSummary -Mode 'bridge') -like '*outbound access works*')
    Assert-Eq 'none summary says there is no outbound access' $true `
        ((Get-IsolatedNetworkModeSummary -Mode 'none') -like '*no outbound*')

    Write-Host '== Get-IsolatedNetworkMode: resolution order =='
    Assert-Eq 'no .env at all defaults to bridge' 'bridge' `
        (Get-IsolatedNetworkMode -ProjectRoot (New-Sandbox @()))
    Assert-Eq 'plain .env defaults to bridge' 'bridge' `
        (Get-IsolatedNetworkMode -ProjectRoot (New-Sandbox @('ISOLATION_MODE=isolated')))
    Assert-Eq 'explicit none' 'none' `
        (Get-IsolatedNetworkMode -ProjectRoot (New-Sandbox @('ISOLATED_NETWORK_MODE=none')))
    Assert-Eq 'case-insensitive input is normalized' 'bridge' `
        (Get-IsolatedNetworkMode -ProjectRoot (New-Sandbox @('ISOLATED_NETWORK_MODE=BRIDGE')))

    $bridgeRoot = New-Sandbox @('ISOLATED_NETWORK_MODE=bridge')
    $env:ISOLATED_NETWORK_MODE = 'none'
    Assert-Eq 'environment outranks .env' 'none' `
        (Get-IsolatedNetworkMode -ProjectRoot $bridgeRoot)
    $env:ISOLATED_NETWORK_MODE = ''

    Write-Host '== rejected configurations =='
    # An unknown network policy must not degrade to bridge. A rejected value
    # that quietly became bridge would attach every account to a network while
    # the user believed they had asked for an offline profile.
    Assert-Throws 'unknown network mode throws and names the accepted values' `
        { Get-IsolatedNetworkMode -ProjectRoot (New-Sandbox @('ISOLATED_NETWORK_MODE=bogus')) } `
        '*must be bridge or none*'

    # An unknown mode must not degrade to shared.
    Assert-Throws 'unknown mode throws and names the accepted values' `
        { Get-IsolationMode -ProjectRoot (New-Sandbox @('ISOLATION_MODE=bogus')) } `
        '*must be shared, worktree or isolated*'

    # isolated now runs, so the refusal moved from "this mode is unimplemented"
    # to "this mode's inputs are missing". It must still name both the variable
    # and the script that produces it.
    $isolatedNoPaths = New-Sandbox @('ISOLATION_MODE=isolated')
    Assert-Eq 'isolated resolves for display' 'isolated' `
        (Get-IsolationMode -ProjectRoot $isolatedNoPaths)
    Assert-Throws 'isolated without clone paths names the variable' `
        { Get-SupportedIsolationMode -ProjectRoot $isolatedNoPaths } `
        '*ISOLATED_WORKSPACE_A is required*'
    Assert-Throws 'isolated without clone paths names the setup script' `
        { Get-SupportedIsolationMode -ProjectRoot $isolatedNoPaths } `
        '*setup-isolated.ps1*'

    # AccountCount is what extends the check past account A. The compose
    # builder only needs A; the generator passes NUM_ACCOUNTS so a path missing
    # for a later account fails before any file is written.
    $isolatedOnlyA = New-Sandbox @('ISOLATION_MODE=isolated', 'ISOLATED_WORKSPACE_A=/tmp/iso-a')
    Assert-Eq 'isolated with only A passes the single-account check' 'isolated' `
        (Get-SupportedIsolationMode -ProjectRoot $isolatedOnlyA)
    Assert-Throws 'isolated with only A fails a two-account check on B' `
        { Get-SupportedIsolationMode -ProjectRoot $isolatedOnlyA -AccountCount 2 } `
        '*ISOLATED_WORKSPACE_B is required*'

    # The same rule now covers worktree, which used to be checked only inside
    # the generator and not by the shared contract.
    $wtOnlyA = New-Sandbox @('ISOLATION_MODE=worktree', 'PROJECT_DIR_A=/tmp/wt-a')
    Assert-Throws 'worktree with only A fails a two-account check on B' `
        { Get-SupportedIsolationMode -ProjectRoot $wtOnlyA -AccountCount 2 } `
        '*PROJECT_DIR_B is required*'

    # There is deliberately no inference from ISOLATED_WORKSPACE_A, unlike the
    # legacy PROJECT_DIR_A one: nothing predates that key, so it must not
    # silently select a stronger boundary than the one declared.
    Assert-Eq 'ISOLATED_WORKSPACE_A alone does not infer isolated' 'shared' `
        (Get-IsolationMode -ProjectRoot (New-Sandbox @('ISOLATED_WORKSPACE_A=/tmp/iso-a')))

    Write-Host '== Get-ComposeArgs: overlay selection =='
    # Get-ComposeArgs only adds the overlay when the file exists, so each case
    # stages the file it expects to be selected.
    $sharedProject = New-Sandbox @('PROJECT_DIR=/tmp/p')
    New-Item -ItemType File -Path (Join-Path $sharedProject 'docker-compose.yml') | Out-Null
    New-Item -ItemType File -Path (Join-Path $sharedProject 'docker-compose.worktree.yml') | Out-Null
    $sharedArgs = Get-ComposeArgs -ProjectRoot $sharedProject
    Assert-Eq 'shared: overlay not selected even though the file exists' $false `
        (($sharedArgs -join ' ') -like '*docker-compose.worktree.yml*')

    $wtProject = New-Sandbox @('PROJECT_DIR=/tmp/p', 'PROJECT_DIR_A=/tmp/wt-a')
    New-Item -ItemType File -Path (Join-Path $wtProject 'docker-compose.yml') | Out-Null
    New-Item -ItemType File -Path (Join-Path $wtProject 'docker-compose.worktree.yml') | Out-Null
    $wtArgs = Get-ComposeArgs -ProjectRoot $wtProject
    Assert-Eq 'worktree: overlay selected' $true `
        (($wtArgs -join ' ') -like '*docker-compose.worktree.yml*')

    # A worktree configuration whose overlay is missing must fail rather than
    # quietly leaving every account on the shared /project mount.
    $wtMissing = New-Sandbox @('PROJECT_DIR=/tmp/p', 'PROJECT_DIR_A=/tmp/wt-a')
    New-Item -ItemType File -Path (Join-Path $wtMissing 'docker-compose.yml') | Out-Null
    Assert-Throws 'worktree with a missing overlay is refused' `
        { Get-ComposeArgs -ProjectRoot $wtMissing } `
        '*docker-compose.worktree.yml is missing*'

    # isolated selects its own overlay, and only its own: composing the
    # worktree overlay as well would let a later -f replace the volume list
    # again and undo the boundary.
    $isoProject = New-Sandbox @('ISOLATION_MODE=isolated', 'ISOLATED_WORKSPACE_A=/tmp/iso-a')
    foreach ($f in 'docker-compose.yml', 'docker-compose.isolated.yml', 'docker-compose.worktree.yml') {
        New-Item -ItemType File -Path (Join-Path $isoProject $f) | Out-Null
    }
    $isoArgs = Get-ComposeArgs -ProjectRoot $isoProject
    Assert-Eq 'isolated: isolated overlay selected' $true `
        (($isoArgs -join ' ') -like '*docker-compose.isolated.yml*')
    Assert-Eq 'isolated: worktree overlay not selected' $false `
        (($isoArgs -join ' ') -like '*docker-compose.worktree.yml*')

    $isoMissing = New-Sandbox @('ISOLATION_MODE=isolated', 'ISOLATED_WORKSPACE_A=/tmp/iso-a')
    New-Item -ItemType File -Path (Join-Path $isoMissing 'docker-compose.yml') | Out-Null
    Assert-Throws 'isolated with a missing overlay is refused' `
        { Get-ComposeArgs -ProjectRoot $isoMissing } `
        '*docker-compose.isolated.yml is missing*'
}
finally {
    $env:ISOLATION_MODE = $savedMode
    $env:PROJECT_DIR_A = $savedProjectDirA
    $env:ISOLATED_WORKSPACE_A = $savedIsolatedA
    $env:ISOLATED_NETWORK_MODE = $savedNetworkMode
    foreach ($dir in $script:Sandboxes) {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
