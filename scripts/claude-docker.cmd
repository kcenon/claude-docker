@echo off
REM Batch wrapper for claude-docker.ps1 — allows cmd.exe users to run:
REM   scripts\claude-docker up
REM   scripts\claude-docker claude
powershell -ExecutionPolicy Bypass -File "%~dp0claude-docker.ps1" %*
