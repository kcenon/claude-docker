# test_worktree_path_guard.ps1 - the path comparison that decides which git
# worktrees remove.ps1 and cleanup.ps1 delete (issue #342).
#
# Run:  pwsh -NoProfile -File tests/test_worktree_path_guard.ps1
# Exits non-zero on any failure.
#
# Both removers used to exclude the tree they were standing in with a raw
# string comparison. On Windows that comparison cannot match: git reports
# "D:/Sources/x" and (Get-Location).Path reports "D:\Sources\x". Every listed
# worktree therefore entered the removal branch, and in remove.ps1 a failed
# `git worktree remove` escalated to an unguarded recursive delete.
#
# The mixed-separator case is the regression. It is asserted directly rather
# than through either script, because reproducing it end to end means running
# a remover against a real repository. These functions are pure string work,
# so the assertions hold identically on the Linux runner and on Windows.

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

# Removal sets are compared as a joined string so a wrong count and a wrong
# member both read the same way in the failure output.
function Assert-Set {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$Actual
    )
    Assert-Eq $Label ($Expected -join ' | ') (@($Actual) -join ' | ')
}

Write-Host '== ConvertTo-ComparablePath =='

Assert-Eq 'backslashes fold to forward slashes' 'D:/Sources/claude-docker' `
    (ConvertTo-ComparablePath -Path 'D:\Sources\claude-docker')
Assert-Eq 'forward slashes are left alone' 'D:/Sources/claude-docker' `
    (ConvertTo-ComparablePath -Path 'D:/Sources/claude-docker')
Assert-Eq 'a trailing separator is dropped' 'D:/Sources/claude-docker' `
    (ConvertTo-ComparablePath -Path 'D:\Sources\claude-docker\')
Assert-Eq 'a POSIX path survives unchanged' '/home/u/project' `
    (ConvertTo-ComparablePath -Path '/home/u/project')

# Trimming a root would turn "C:/" into "C:" and "/" into "", neither of which
# is a path. No worktree is ever a root, so the guard just has to not corrupt
# them if one is passed.
Assert-Eq 'a drive root is not trimmed away' 'C:/' (ConvertTo-ComparablePath -Path 'C:\')
Assert-Eq 'the POSIX root is not trimmed away' '/' (ConvertTo-ComparablePath -Path '/')
Assert-Eq 'an empty path stays empty' '' (ConvertTo-ComparablePath -Path '')

Write-Host '== Select-RemovableWorktree: the #342 regression =='

# The exact shape the two removers see on Windows: git porcelain output in
# forward-slash form, the current directory in backslash form. Before the fix
# this returned the main worktree, and remove.ps1 went on to delete it.
$porcelain = @(
    'D:/Sources/claude-docker',
    'D:/Sources/.codex/worktrees/claude-docker-a',
    'D:/Sources/.codex/worktrees/claude-docker-b'
)
Assert-Set 'main tree in forward-slash form is excluded from a backslash cwd' `
    @('D:/Sources/.codex/worktrees/claude-docker-a', 'D:/Sources/.codex/worktrees/claude-docker-b') `
    (Select-RemovableWorktree -WorktreePath $porcelain -CurrentPath 'D:\Sources\claude-docker')

# The single-worktree install is the default one, and it is the case where a
# wrong answer costs the user their repository.
Assert-Set 'a repository with no linked worktrees yields an empty set' `
    @() `
    (Select-RemovableWorktree -WorktreePath @('D:/Sources/claude-docker') `
        -CurrentPath 'D:\Sources\claude-docker')

Assert-Set 'no worktrees at all yields an empty set' `
    @() (Select-RemovableWorktree -WorktreePath @() -CurrentPath 'D:\Sources\claude-docker')

Assert-Set 'a null listing yields an empty set' `
    @() (Select-RemovableWorktree -WorktreePath $null -CurrentPath 'D:\Sources\claude-docker')

Write-Host '== Select-RemovableWorktree: standing in a linked worktree =='

# This is the case that destroyed a repository. git lists the main working
# tree first even when invoked from a linked one, so the caller's own path
# does not identify what is at risk -- the ordering guard does.
Assert-Set 'the main tree is dropped even when the caller is elsewhere' `
    @('D:/Sources/.codex/worktrees/claude-docker-b') `
    (Select-RemovableWorktree -WorktreePath $porcelain `
        -CurrentPath 'D:\Sources\.codex\worktrees\claude-docker-a')

Write-Host '== Select-RemovableWorktree: spelling variance =='

Assert-Set 'a trailing separator on the cwd still matches' `
    @('D:/Sources/.codex/worktrees/claude-docker-a', 'D:/Sources/.codex/worktrees/claude-docker-b') `
    (Select-RemovableWorktree -WorktreePath $porcelain -CurrentPath 'D:\Sources\claude-docker\')

# Windows paths are case-insensitive, and a drive letter reaches these scripts
# in either case depending on how the user typed it into the installer.
Assert-Set 'a case difference still matches' `
    @('D:/Sources/.codex/worktrees/claude-docker-a', 'D:/Sources/.codex/worktrees/claude-docker-b') `
    (Select-RemovableWorktree -WorktreePath $porcelain -CurrentPath 'd:\sources\CLAUDE-DOCKER')

# A prefix must not be mistaken for the same tree, or a sibling worktree whose
# name extends the repository's would silently survive removal.
Assert-Set 'a path that merely shares a prefix is still removable' `
    @('D:/Sources/claude-docker-extra') `
    (Select-RemovableWorktree -WorktreePath @('D:/Sources/claude-docker', 'D:/Sources/claude-docker-extra') `
        -CurrentPath 'D:\Sources\claude-docker')

Write-Host '== Test-OwnedWorktreePath: ownership (issue #344) =='

# Not being the current tree is not the same as being ours. This is the second
# axis: a worktree the user added themselves in the project repository was
# previously removed with --force before any other guard was consulted.
# Mirrors worktree_is_owned in scripts/lib/worktrees.sh; the bash side is
# exercised against real git output by tests/test_worktree_ownership.sh.

$project = 'D:\Sources\myapp'
$envData = @{
    'PROJECT_DIR'          = 'D:/Sources/myapp'
    'PROJECT_DIR_A'        = 'D:/Sources/myapp-a'
    'ISOLATED_WORKSPACE_A' = 'D:/Sources/clones/myapp-iso-a'
    'GH_TOKEN'             = 'placeholder-not-a-path'
}
function Test-Owned {
    param([string]$Path, [hashtable]$Data = $envData)
    return (Test-OwnedWorktreePath -Path $Path -ProjectDir $project -EnvData $Data)
}

Assert-Eq 'a PROJECT_DIR_<X> path is ours' $true (Test-Owned 'D:\Sources\myapp-a')
Assert-Eq 'an ISOLATED_WORKSPACE_<X> path is ours' $true (Test-Owned 'D:/Sources/clones/myapp-iso-a')
Assert-Eq 'a user-added worktree is not ours' $false (Test-Owned 'D:\Sources\myapp-hotfix')
Assert-Eq 'an unrelated directory is not ours' $false (Test-Owned 'D:\Work\somethingelse')

# PROJECT_DIR itself has no letter suffix and must not be read as a workspace
# key, or the project repository would qualify as its own removable worktree.
Assert-Eq 'PROJECT_DIR is not a per-account key' $false (Test-Owned 'D:\Sources\myapp')

# remove.ps1 deletes .env in a later step than the worktrees, and installs
# predating the keys never had them, so the naming pattern must stand alone.
Assert-Eq 'the naming pattern works with no .env' $true (Test-Owned 'D:\Sources\myapp-b' $null)
Assert-Eq 'a clone path is not guessable with no .env' $false `
    (Test-Owned 'D:/Sources/clones/myapp-iso-a' $null)

# The pattern must accept exactly what the generator emits. The account count
# is capped at 702 and index 702 is "zz", so two characters is the ceiling; a
# looser [A-Za-z]+ would claim "<project>-clone" and "<project>-hotfix".
Assert-Eq 'two letters (the ceiling) are ours' $true (Test-Owned 'D:\Sources\myapp-zz')
Assert-Eq 'three letters exceed the range' $false (Test-Owned 'D:\Sources\myapp-abc')
Assert-Eq 'a numeric suffix is not the pattern' $false (Test-Owned 'D:\Sources\myapp-2')

# Separator form must not decide ownership, for the same reason it must not
# decide self-exclusion.
Assert-Eq 'a forward-slash spelling still matches .env' $true (Test-Owned 'D:/Sources/myapp-a')
Assert-Eq 'a trailing separator still matches' $true (Test-Owned 'D:\Sources\myapp-a\')

Write-Host '== both removers route through the shared helpers =='

# The point of the shared functions is that one fix covers both scripts. If
# either grows its own copy of the loop again, everything above keeps passing
# while the defect comes back, so the call sites are asserted too.
foreach ($name in 'remove.ps1', 'cleanup.ps1') {
    $source = Get-Content -LiteralPath (Join-Path $ScriptsDir $name) -Raw
    Assert-Eq "$name calls Select-RemovableWorktree" $true `
        ($source -like '*Select-RemovableWorktree*')
    Assert-Eq "$name checks ownership before removing" $true `
        ($source -like '*Test-OwnedWorktreePath*')
    Assert-Eq "$name no longer compares against a raw `$currentDir" $false `
        ($source -like '*-ne $currentDir*')
}

# The recursive-delete fallback is gone from remove.ps1. git declining to
# remove a worktree it created is information; escalating past that refusal is
# what turned a wrong path into data loss.
$removeSource = Get-Content -LiteralPath (Join-Path $ScriptsDir 'remove.ps1') -Raw
Assert-Eq 'remove.ps1 has no recursive worktree delete' $false `
    ($removeSource -like '*Remove-Item -LiteralPath $wtPath -Recurse*')

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
