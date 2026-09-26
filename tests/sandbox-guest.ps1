[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputRoot, [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$WorkRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$result = @{ ExitCode = 1; Error = ''; ComputerName = $env:COMPUTERNAME }
$stdout = Join-Path $OutputRoot 'stdout.txt'
$stderr = Join-Path $OutputRoot 'stderr.txt'
try {
    # Run on the guest disk: SQLite and test processes must not depend on mapped-folder semantics.
    if (Test-Path -LiteralPath $WorkRoot) { throw "Work directory already exists: $WorkRoot" }
    Copy-Item -LiteralPath (Join-Path $InputRoot 'project') -Destination $WorkRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $InputRoot 'AutoHotkey.exe') -Destination $WorkRoot
    $selection = Get-Content -LiteralPath (Join-Path $InputRoot 'selection.json') -Raw | ConvertFrom-Json
    # Keep invocation out of command-line interpolation; selected names are JSON data.
    $entry = Join-Path $WorkRoot 'sandbox-entry.ps1'
    $body = @'
$selection = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sandbox-selection.json') -Raw | ConvertFrom-Json
& (Join-Path $PSScriptRoot 'tests\run.ps1') -Name $selection.Name -AutoHotkeyPath (Join-Path $PSScriptRoot 'AutoHotkey.exe')
'@
    [IO.File]::WriteAllText($entry,$body,[Text.UTF8Encoding]::new($true))
    $selection | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkRoot 'sandbox-selection.json') -Encoding UTF8
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $WorkRoot 'tests\execute-check.ps1') + '"'),'-Path',('"' + $entry + '"') -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $exitCode = Wait-TestProcess -Process $process -TimeoutMs (120000 * (@($selection.Name).Count + 1) + 30000)
    if ($exitCode -ne 0 -or (Get-Item -LiteralPath $stderr).Length -gt 0) { throw "Test runner failed (exit $exitCode)." }
    $result.ExitCode = 0
} catch { $result.Error = $_.Exception.Message }
finally {
    try {
        $artifacts = Join-Path $WorkRoot 'tests\.tmp'
        if (Test-Path -LiteralPath $artifacts) { Copy-Item -LiteralPath $artifacts -Destination (Join-Path $OutputRoot 'artifacts') -Recurse }
    } catch { $result.ExitCode = 1; $result.Error += " Artifact collection failed: $($_.Exception.Message)" }
    # Publish only after logs are closed and evidence has been collected.
    $pending = Join-Path $OutputRoot 'result.pending.json'
    $result | ConvertTo-Json | Set-Content -LiteralPath $pending -Encoding UTF8
    Move-Item -LiteralPath $pending -Destination (Join-Path $OutputRoot 'result.json')
}
