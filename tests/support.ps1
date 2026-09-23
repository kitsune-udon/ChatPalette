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

function Invoke-AppTest {
    param([string]$Runtime, [string]$Body, [int]$TimeoutMs = 30000, [string]$Setup = '')
    $source = "#Requires AutoHotkey v2.0`r`n#SingleInstance Force`r`n#Include %A_ScriptDir%\src\app\app_modules.ahk`r`n" + $Setup + "`r`nInitializeApplication()`r`n" + $Body
    Invoke-AhkTest -Runtime $Runtime -Source $source -TimeoutMs $TimeoutMs
}
function Invoke-AhkTest {
    param([string]$Runtime, [string]$Source, [int]$TimeoutMs = 30000)
    $entry = Join-Path $Runtime 'test.ahk'
    [IO.File]::WriteAllText($entry, $source, [Text.UTF8Encoding]::new($true))
    $out = Join-Path $Runtime 'stdout.txt'
    $err = Join-Path $Runtime 'stderr.txt'
    $run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + $entry + '"'), '--smoke' -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $run.Handle
    if (!$run.WaitForExit($TimeoutMs)) {
        $run.Kill()
        $run.WaitForExit()
        throw "Test timed out after ${TimeoutMs}ms: $Runtime"
    }
    Get-Content -LiteralPath $out,$err
    if ($run.ExitCode -ne 0) { throw "Test failed ($($run.ExitCode)): $Runtime" }
}

function Write-TestWorker {
    param([string]$Runtime, [string]$Definitions)
    $source = @'
param([string]$PipeName, [int]$ParentProcessId)
. (Join-Path $PSScriptRoot 'browser_worker.ps1') -Library -PipeName $PipeName -ParentProcessId $ParentProcessId
'@ + "`r`n" + $Definitions + "`r`nStart-BrowserWorker `$PipeName `$ParentProcessId -Handler { param(`$request) Invoke-FixtureRequest `$request }"
    [IO.File]::WriteAllText((Join-Path $Runtime 'src\browser\fixture_worker.ps1'),$source,[Text.UTF8Encoding]::new($true))
}
