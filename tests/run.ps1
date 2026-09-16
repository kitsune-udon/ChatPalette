param([string]$AutoHotkeyPath)
$ErrorActionPreference = 'Stop'
$base = Join-Path $PSScriptRoot '.tmp'
$runRoot = Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$oldRoot = $env:HELPER_TEST_ROOT
$oldAhk = $env:AHK_EXE
try {
    $env:HELPER_TEST_ROOT = $runRoot
    if ($AutoHotkeyPath) { $env:AHK_EXE = $AutoHotkeyPath }
    foreach ($name in @('test-app.ps1','test-empty-settings.ps1','test-reactions.ps1','test-cache.ps1','test-input.ps1','test-storage.ps1','test-startup.ps1')) {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
        if ($LASTEXITCODE -ne 0) { throw "Failed: $name" }
    }
    Write-Output 'PASS: all tests; no real messages or reactions sent.'
} finally {
    $env:HELPER_TEST_ROOT = $oldRoot
    $env:AHK_EXE = $oldAhk
    $resolved = (Resolve-Path -LiteralPath $runRoot).Path
    if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath $base).Path) { throw 'Unexpected cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
