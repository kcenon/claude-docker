# One host policy implementation for Bash and PowerShell; native argv only.
function Invoke-HostPolicy {
    param([string]$ProjectRoot, [Parameter(ValueFromRemainingArguments)][string[]]$PolicyArgs)
    # Preserve the native exit code even when the calling session opted into
    # PowerShell 7.3+'s native-command ErrorAction integration.
    $PSNativeCommandUseErrorActionPreference = $false
    $python = Get-Command python3, python, py -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1
    if (-not $python) { throw 'Python 3.9+ is required for isolation validation and lifecycle transactions.' }
    $pythonArgs = @()
    if ($python.Name -match '^py(\.exe)?$') { $pythonArgs += '-3' }
    & $python.Source @pythonArgs (Join-Path $PSScriptRoot 'lifecycle.py') --root $ProjectRoot @PolicyArgs
    if ($LASTEXITCODE -ne 0) {
        $failure = [System.Exception]::new("Host policy failed (exit $LASTEXITCODE).")
        $failure.Data['ExitCode'] = $LASTEXITCODE
        throw $failure
    }
}
