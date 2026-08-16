@echo off
REM Batch wrapper for claude-docker.ps1 - allows cmd.exe users to run:
REM   scripts\claude-docker up
REM   scripts\claude-docker claude
REM
REM pwsh, not powershell. `powershell` is always Windows PowerShell 5.1, which
REM this project no longer supports (see README.md, Platform Support, and the
REM decision recorded on issue #348). Invoking 5.1 here surfaced as a parameter
REM binder error from a library load rather than as anything a user could act
REM on, because 5.1 has no -AdditionalChildPath on Join-Path.
REM
REM pwsh is not guaranteed present on Windows the way powershell is, so its
REM absence is reported here rather than left to cmd's "not recognized".
where /q pwsh
if errorlevel 1 (
    echo Error: PowerShell 7 ^(pwsh^) was not found on PATH.>&2
    echo        claude-docker requires PowerShell 7; Windows PowerShell 5.1 is not supported.>&2
    echo        Install it with:  winget install --id Microsoft.PowerShell>&2
    exit /b 1
)
pwsh -ExecutionPolicy Bypass -File "%~dp0claude-docker.ps1" %*
