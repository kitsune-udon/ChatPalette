[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
# This process owns the output encoding; do not change the invoking shell's console.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$global:LASTEXITCODE = 0
try { & $Path }
catch {
    # PowerShell's default error view can show only this wrapper for runtime failures.
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    throw
}
exit $LASTEXITCODE
