# PowerShell parity coverage for per-account gh-auth and update.
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$script:Pass = 0
$script:Fail = 0

Import-Module (Join-Path $ProjectRoot 'scripts' 'ClaudeDocker.psm1') -Force

function Assert-True([string]$Label, [bool]$Condition) {
    if ($Condition) {
        Write-Host "  PASS  $Label"
        $script:Pass++
    }
    else {
        Write-Host "  FAIL  $Label"
        $script:Fail++
    }
}

function Write-TestFile([string]$Path, [string]$Content) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

# Keep executable shims under the checked-out workspace and bind aliases to
# their absolute paths below. Hosted runners also provide real gh and docker
# commands, which must never win command discovery in this isolated test.
$work = Join-Path $ProjectRoot ".test-github-account-selection-$PID"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$originalPath = $env:PATH
$originalOS = $PSVersionTable.OS

function New-TestSandbox([string]$Name) {
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'tui\internal\config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'bin') -Force | Out-Null
    Copy-Item (Join-Path $ProjectRoot 'scripts') $dir -Recurse
    Copy-Item (Join-Path $ProjectRoot 'tui\internal\config\runtimes.json') `
        (Join-Path $dir 'tui\internal\config\runtimes.json')
    Copy-Item (Join-Path $ProjectRoot 'docker-compose*.yml') $dir
    Copy-Item (Join-Path $ProjectRoot 'VERSION') $dir
    Copy-Item (Join-Path $ScriptDir 'env_fixtures' 'github-per-account.env') (Join-Path $dir '.env')

    $bin = Join-Path $dir 'bin'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Write-TestFile (Join-Path $bin 'gh.cmd') @'
@echo off
echo %*>>"%GH_MOCK_LOG%"
if "%~1 %~2"=="auth status" exit /b 0
if "%~1 %~2"=="auth token" (
  if "%~6"=="replacement-user-b" (
    echo mock-value-b
    exit /b 0
  )
  if "%~6"=="fixture-user-a" (
    echo mock-value-a
    exit /b 0
  )
  if "%~6"=="fixture-user-b" (
    echo mock-value-b
    exit /b 0
  )
)
exit /b 1
'@
        Write-TestFile (Join-Path $bin 'docker.cmd') @'
@echo off
echo %*>>"%DOCKER_MOCK_LOG%"
if "%~1"=="exec" (
  if "%~2"=="cid-a" (
    echo fixture-user-a
    exit /b 0
  )
  if "%~2"=="cid-b" (
    echo replacement-user-b
    exit /b 0
  )
  exit /b 1
)
echo %*| findstr /C:" ps -q claude-a" >nul
if not errorlevel 1 (
  echo cid-a
  exit /b 0
)
echo %*| findstr /C:" ps -q claude-b" >nul
if not errorlevel 1 (
  echo cid-b
  exit /b 0
)
exit /b 0
'@
    }
    else {
        Write-TestFile (Join-Path $bin 'gh') @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_MOCK_LOG"
if [[ "$1 $2" == "auth status" ]]; then exit 0; fi
if [[ "$1 $2" == "auth token" ]]; then
  user=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--user" ]]; then user="$2"; break; fi
    shift
  done
  case "$user" in
    replacement-user-b) printf '%s\n' 'mock-value-b' ;;
    fixture-user-a) printf '%s\n' 'mock-value-a' ;;
    fixture-user-b) printf '%s\n' 'mock-value-b' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
'@
        Write-TestFile (Join-Path $bin 'docker') @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_MOCK_LOG"
if [[ "${1:-}" == "exec" ]]; then
  case "${2:-}" in
    cid-a) printf '%s\n' 'fixture-user-a' ;;
    cid-b) printf '%s\n' 'replacement-user-b' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
case " $* " in
  *" ps -q claude-a "*) printf '%s\n' 'cid-a' ;;
  *" ps -q claude-b "*) printf '%s\n' 'cid-b' ;;
  *" ps -q "*) printf '%s\n' 'cid-a' ;;
esac
exit 0
'@
        & chmod +x (Join-Path $bin 'gh') (Join-Path $bin 'docker')
    }
    return $dir
}

function Invoke-TestCLI([string]$Dir, [string[]]$CLIArgs) {
    $env:GH_MOCK_LOG = Join-Path $Dir 'gh.log'
    $env:DOCKER_MOCK_LOG = Join-Path $Dir 'docker.log'
    $env:PATH = (Join-Path $Dir 'bin') + [System.IO.Path]::PathSeparator + $originalPath
    $mockExtension = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { '.cmd' } else { '' }
    Set-Alias -Name gh -Value (Join-Path $Dir "bin/gh$mockExtension") -Scope Global -Force
    Set-Alias -Name docker -Value (Join-Path $Dir "bin/docker$mockExtension") -Scope Global -Force
    if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.OS -and
        $PSVersionTable.OS -notlike '*Windows*') {
        $PSVersionTable.OS = 'Microsoft Windows'
    }
    $output = & (Join-Path $Dir 'scripts' 'claude-docker.ps1') @CLIArgs 2>&1 | Out-String
    return $output
}

try {
    Write-Host '== selected account =='
    $selected = New-TestSandbox 'selected'
    $selectedOutput = Invoke-TestCLI $selected @('gh-auth', 'b', '--user', 'replacement-user-b')
    $selectedEnv = Read-EnvFile -Path (Join-Path $selected '.env')
    Assert-True 'updates only selected mapping' (
        $selectedEnv['GH_USER_B'] -eq 'replacement-user-b' -and
        $selectedEnv['GH_TOKEN_B'] -eq 'mock-value-b' -and
        $selectedEnv['GH_TOKEN_A'] -eq 'fixture-token-a')
    $ghLog = (Get-Content -Raw (Join-Path $selected 'gh.log')) -replace "`r", ''
    $dockerLog = (Get-Content -Raw (Join-Path $selected 'docker.log')) -replace "`r", ''
    Assert-True 'uses explicit --hostname and --user without switch' (
        $ghLog -match '(?m)^auth token --hostname github\.com --user replacement-user-b$' -and
        $ghLog -notmatch 'auth switch')
    Assert-True 'recreates only selected service' (
        $dockerLog -match '(?m)^.*up .*--force-recreate.*claude-b$' -and
        $dockerLog -notmatch '(?m)^.*up .*--force-recreate.*claude-a.*$')
    Assert-True 'does not print imported value' ($selectedOutput -notmatch 'mock-value-b')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Assert-True 'retains protected Windows ACL' ((Get-Acl (Join-Path $selected '.env')).AreAccessRulesProtected)
    }

    Write-Host '== all accounts =='
    $all = New-TestSandbox 'all'
    $allOutput = Invoke-TestCLI $all @('gh-auth', '--all')
    $allGhLog = (Get-Content -Raw (Join-Path $all 'gh.log')) -replace "`r", ''
    Assert-True '--all selects both configured users' (
        $allGhLog -match '(?m)^auth token --hostname github\.com --user fixture-user-a$' -and
        $allGhLog -match '(?m)^auth token --hostname github\.com --user fixture-user-b$' -and
        $allGhLog -notmatch '(?m)^auth token$')
    Assert-True '--all does not print imported values' ($allOutput -notmatch 'mock-value-a|mock-value-b')

    Write-Host '== update =='
    $update = New-TestSandbox 'update'
    $updateOutput = Invoke-TestCLI $update @('update')
    $updateGhLog = (Get-Content -Raw (Join-Path $update 'gh.log')) -replace "`r", ''
    Assert-True 'update refreshes both configured users' (
        $updateGhLog -match '(?m)^auth token --hostname github\.com --user fixture-user-a$' -and
        $updateGhLog -match '(?m)^auth token --hostname github\.com --user fixture-user-b$')
    Assert-True 'update does not print imported values' ($updateOutput -notmatch 'mock-value-a|mock-value-b')
}
finally {
    $env:PATH = $originalPath
    $env:GH_MOCK_LOG = $null
    $env:DOCKER_MOCK_LOG = $null
    Remove-Item Alias:gh, Alias:docker -Force -ErrorAction SilentlyContinue
    if ($null -ne $originalOS -and $PSVersionTable.ContainsKey('OS')) {
        $PSVersionTable.OS = $originalOS
    }
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

Write-Host ''
Write-Host "== Summary: PASS=$($script:Pass) FAIL=$($script:Fail) =="
if ($script:Fail -gt 0) { exit 1 }
