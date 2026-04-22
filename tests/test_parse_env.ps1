# test_parse_env.ps1 — Parity tests for ClaudeDocker.psm1 env helpers.
# Run:  pwsh -NoProfile -File tests/test_parse_env.ps1
# Exits non-zero on any failure.

param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$Fixtures = Join-Path $ScriptDir 'env_fixtures'

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

Write-Host '== Get-EnvValue: minimal.env =='
Assert-Eq 'NUM_ACCOUNTS' '2' (Get-EnvValue -Path (Join-Path $Fixtures 'minimal.env') -Key 'NUM_ACCOUNTS')
Assert-Eq 'IMAGE_TAG' 'latest' (Get-EnvValue -Path (Join-Path $Fixtures 'minimal.env') -Key 'IMAGE_TAG')
Assert-Eq 'missing key' $null (Get-EnvValue -Path (Join-Path $Fixtures 'minimal.env') -Key 'NOPE')

Write-Host '== Get-EnvValue: edge-cases.env =='
$ec = Join-Path $Fixtures 'edge-cases.env'
Assert-Eq 'basic int'         '3' (Get-EnvValue -Path $ec -Key 'NUM_ACCOUNTS')
Assert-Eq 'value with space'  '/home/user/my project' (Get-EnvValue -Path $ec -Key 'PROJECT_DIR')
Assert-Eq 'inline comment'    'gho_abc123' (Get-EnvValue -Path $ec -Key 'GH_TOKEN')
Assert-Eq 'double-quoted'     'hello world' (Get-EnvValue -Path $ec -Key 'QUOTED_DOUBLE')
Assert-Eq 'single-quoted'     'single quoted' (Get-EnvValue -Path $ec -Key 'QUOTED_SINGLE')
Assert-Eq 'empty value'       '' (Get-EnvValue -Path $ec -Key 'EMPTY')
Assert-Eq 'equals in value'   'foo=bar=baz' (Get-EnvValue -Path $ec -Key 'EQUALS_IN_VALUE')
Assert-Eq 'hash in quotes'    'value#not-a-comment' (Get-EnvValue -Path $ec -Key 'HASH_IN_QUOTES')
Assert-Eq 'trailing-space'    'keep-me' (Get-EnvValue -Path $ec -Key 'TRAILING_SPACE')

Write-Host '== Get-EnvValue: duplicate keys — last wins =='
$dup = Join-Path $Fixtures 'duplicate-keys.env'
Assert-Eq 'NUM_ACCOUNTS last wins' '5' (Get-EnvValue -Path $dup -Key 'NUM_ACCOUNTS')

Write-Host '== Get-EnvValue: CRLF tolerance =='
$crlfPath = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllBytes(
    $crlfPath,
    [System.Text.Encoding]::UTF8.GetBytes("A=one`r`nB=two`r`n")
)
Assert-Eq 'CRLF A' 'one' (Get-EnvValue -Path $crlfPath -Key 'A')
Assert-Eq 'CRLF B' 'two' (Get-EnvValue -Path $crlfPath -Key 'B')
Remove-Item $crlfPath -Force

Write-Host '== Read-EnvFile: returns hashtable of all keys =='
$allMinimal = Read-EnvFile -Path (Join-Path $Fixtures 'minimal.env')
Assert-Eq 'hashtable NUM_ACCOUNTS' '2' $allMinimal['NUM_ACCOUNTS']
Assert-Eq 'hashtable IMAGE_TAG' 'latest' $allMinimal['IMAGE_TAG']

Write-Host '== Set-EnvValue: update and insert round-trip =='
$setPath = [System.IO.Path]::GetTempFileName()
Copy-Item (Join-Path $Fixtures 'minimal.env') $setPath -Force
Set-EnvValue -Path $setPath -Key 'NUM_ACCOUNTS' -Value '7'
Assert-Eq 'updated value' '7' (Get-EnvValue -Path $setPath -Key 'NUM_ACCOUNTS')
Set-EnvValue -Path $setPath -Key 'NEW_KEY' -Value 'value with spaces'
Assert-Eq 'insert round-trip' 'value with spaces' (Get-EnvValue -Path $setPath -Key 'NEW_KEY')
Set-EnvValue -Path $setPath -Key 'HASH_KEY' -Value 'val#1'
Assert-Eq 'hash value round-trip' 'val#1' (Get-EnvValue -Path $setPath -Key 'HASH_KEY')
Remove-Item $setPath -Force

Write-Host ''
Write-Host ("== Summary: PASS={0} FAIL={1} ==" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
