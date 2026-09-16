$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
function New-TestRuntime {
    $base = if ($env:HELPER_TEST_ROOT) { $env:HELPER_TEST_ROOT } else { Join-Path $PSScriptRoot '.tmp' }
    $path = Join-Path $base ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Get-ChildItem -LiteralPath $ProjectRoot -File | Where-Object { $_.Extension -in '.ahk','.ps1' -or $_.Name -eq 'VERSION' } | Copy-Item -Destination $path
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'src') -Destination $path -Recurse
    return $path
}
function Get-AutoHotkeyPath {
    if ($env:AHK_EXE -and (Test-Path -LiteralPath $env:AHK_EXE)) { return $env:AHK_EXE }
    $candidates = @((Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'))
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    throw 'AutoHotkey v2 is required. Set AHK_EXE to the full executable path.'
}
