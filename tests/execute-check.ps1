[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
# This process owns the output encoding; do not change the invoking shell's console.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$global:LASTEXITCODE = 0
& $Path
exit $LASTEXITCODE
