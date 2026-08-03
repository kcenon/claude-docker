#Requires -Version 5.1
<#
.SYNOPSIS
    E2E test: Tier B concurrent git safety (Windows PowerShell port).
.DESCRIPTION
    PowerShell port of scripts/test-concurrent-git.sh.
    Verifies that two containers can commit to separate worktrees simultaneously
    without conflicts or corruption.
.EXAMPLE
    .\scripts\test-concurrent-git.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Platform guard: PowerShell 7 runs on Linux and macOS, but this Windows harness
# invokes Compose without docker-compose.linux.yml. On Linux that skips UID/GID
# mapping, so a pass can hide incorrect ownership in the generated worktrees.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and $PSVersionTable.OS -notlike '*Windows*') {
    Write-Error "test-concurrent-git.ps1 is Windows-only. Use ./scripts/test-concurrent-git.sh on macOS or Linux."
    exit 1
}

$ScriptDir = $PSScriptRoot
$ProjectDir = Split-Path $ScriptDir -Parent
$TempDir = Join-Path $env:TEMP "claude-docker-test-$(New-Guid)"
$RepoDir = Join-Path $TempDir 'test-repo'

function Invoke-Cleanup {
    Write-Host '=== Cleaning up ==='
    & docker compose -f "$ProjectDir\docker-compose.yml" `
        -f "$ProjectDir\docker-compose.worktree.yml" `
        down --remove-orphans 2>$null
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Done.'
}

try {
    Write-Host '=== Setting up test repository ==='
    New-Item -ItemType Directory -Path $RepoDir -Force | Out-Null
    Push-Location $RepoDir

    & git init
    & git config user.email 'test@example.com'
    & git config user.name 'Test User'
    'initial' | Set-Content -Path 'README.md' -NoNewline
    & git add README.md
    & git commit -m 'Initial commit'

    Pop-Location

    Write-Host '=== Creating worktrees ==='
    & "$ScriptDir\setup-worktrees.ps1" -RepoDir $RepoDir -Branches @('test-branch-a', 'test-branch-b')

    $WorktreeA = "${RepoDir}-a"
    $WorktreeB = "${RepoDir}-b"

    Write-Host '=== Building image ==='
    & docker compose -f "$ProjectDir\docker-compose.yml" build

    Write-Host '=== Starting containers with worktree override ==='
    $env:PROJECT_DIR = $RepoDir
    $env:PROJECT_DIR_A = $WorktreeA
    $env:PROJECT_DIR_B = $WorktreeB

    & docker compose -f "$ProjectDir\docker-compose.yml" `
        -f "$ProjectDir\docker-compose.worktree.yml" `
        up -d

    Write-Host '=== Running parallel commits ==='

    # Each container creates and commits files in its own worktree
    $jobA = Start-Job -ScriptBlock {
        param($ProjectDir, $RepoDir, $WorktreeA, $WorktreeB)
        & docker compose -f "$ProjectDir\docker-compose.yml" `
            -f "$ProjectDir\docker-compose.worktree.yml" `
            exec -T claude-a bash -c @'
git config user.email "a@test.com"
git config user.name "Agent A"
for i in 1 2 3 4 5; do
    echo "commit-a-$i" > "file-a-$i.txt"
    git add "file-a-$i.txt"
    git commit -m "Agent A: commit $i"
done
'@
    } -ArgumentList $ProjectDir, $RepoDir, $WorktreeA, $WorktreeB

    $jobB = Start-Job -ScriptBlock {
        param($ProjectDir, $RepoDir, $WorktreeA, $WorktreeB)
        & docker compose -f "$ProjectDir\docker-compose.yml" `
            -f "$ProjectDir\docker-compose.worktree.yml" `
            exec -T claude-b bash -c @'
git config user.email "b@test.com"
git config user.name "Agent B"
for i in 1 2 3 4 5; do
    echo "commit-b-$i" > "file-b-$i.txt"
    git add "file-b-$i.txt"
    git commit -m "Agent B: commit $i"
done
'@
    } -ArgumentList $ProjectDir, $RepoDir, $WorktreeA, $WorktreeB

    # Set environment for docker compose in jobs
    $env:PROJECT_DIR = $RepoDir
    $env:PROJECT_DIR_A = $WorktreeA
    $env:PROJECT_DIR_B = $WorktreeB

    # Wait for both to complete
    $resultA = Receive-Job $jobA -Wait -AutoRemoveJob
    $resultB = Receive-Job $jobB -Wait -AutoRemoveJob

    if ($jobA.State -eq 'Failed' -or $jobB.State -eq 'Failed') {
        Write-Host 'FAIL: One or both containers failed during parallel commits' -ForegroundColor Red
        exit 1
    }

    Write-Host '=== Verifying results ==='

    # Check worktree A has 5 commits from Agent A
    $countA = (& git -C $WorktreeA log --oneline --author='Agent A').Count
    if ($countA -ne 5) {
        Write-Host "FAIL: Expected 5 commits from Agent A, got $countA" -ForegroundColor Red
        exit 1
    }

    # Check worktree B has 5 commits from Agent B
    $countB = (& git -C $WorktreeB log --oneline --author='Agent B').Count
    if ($countB -ne 5) {
        Write-Host "FAIL: Expected 5 commits from Agent B, got $countB" -ForegroundColor Red
        exit 1
    }

    # Check no cross-contamination
    $crossA = (& git -C $WorktreeA log --oneline --author='Agent B' 2>$null).Count
    $crossB = (& git -C $WorktreeB log --oneline --author='Agent A' 2>$null).Count
    if ($crossA -ne 0 -or $crossB -ne 0) {
        Write-Host 'FAIL: Cross-contamination detected between worktrees' -ForegroundColor Red
        exit 1
    }

    # Check git repo integrity
    & git -C $RepoDir fsck --no-dangling 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'FAIL: Git repository integrity check failed' -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host '=== ALL TESTS PASSED ===' -ForegroundColor Green
    Write-Host "  Worktree A: $countA commits from Agent A (no cross-contamination)"
    Write-Host "  Worktree B: $countB commits from Agent B (no cross-contamination)"
    Write-Host '  Repository integrity: OK'
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
finally {
    # Clean up environment variables
    $env:PROJECT_DIR = $null
    $env:PROJECT_DIR_A = $null
    $env:PROJECT_DIR_B = $null

    Invoke-Cleanup
}
