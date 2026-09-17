param([string]$AutoHotkeyPath)
$ErrorActionPreference = 'Stop'
$base = Join-Path $PSScriptRoot '.tmp'
$runRoot = Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$completed = $false
$oldRoot = $env:HELPER_TEST_ROOT
$oldAhk = $env:AHK_EXE
try {
    $env:HELPER_TEST_ROOT = $runRoot
    if ($AutoHotkeyPath) { $env:AHK_EXE = $AutoHotkeyPath }
    foreach ($name in @('test-app.ps1','test-sqlite.ps1','test-registration-storage.ps1','test-palette-return.ps1','test-timing.ps1','test-review-regressions.ps1','test-viewports.ps1','test-list-visibility.ps1','test-empty-settings.ps1','test-settings-integrity.ps1','test-management-order.ps1','test-performance.ps1','test-search-scheduling.ps1','test-reactions.ps1','test-cache.ps1','test-input.ps1','test-storage.ps1','test-startup.ps1','test-release.ps1')) {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
        if ($LASTEXITCODE -ne 0) { throw "Failed: $name" }
    }
    $completed = $true
    Write-Output 'PASS: all tests; no real messages or reactions sent.'
} finally {
    $env:HELPER_TEST_ROOT = $oldRoot
    $env:AHK_EXE = $oldAhk
    $resolved = (Resolve-Path -LiteralPath $runRoot).Path
    if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath $base).Path) { throw 'Unexpected cleanup path' }
    if ($completed) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    else { Write-Warning "Failed test artifacts retained: $resolved" }
}
