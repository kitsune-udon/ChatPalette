$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
function New-TestRuntime {
    $base = if ($env:HELPER_TEST_ROOT) { $env:HELPER_TEST_ROOT } else { Join-Path $PSScriptRoot '.tmp' }
    $path = Join-Path $base ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Get-ChildItem -LiteralPath $ProjectRoot -File | Where-Object { $_.Extension -in '.ahk','.ps1' -or $_.Name -eq 'VERSION' } | Copy-Item -Destination $path
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'src') -Destination $path -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\library-model.ahk') -Destination (Join-Path $path 'library-model.ahk')
    return $path
}
# Edit only a caller-provided isolated copy; preserve literal, all-match replacement.
function Edit-TestSource {
    param([string]$Runtime, [string]$RelativePath, [string]$Before, [string]$After)
    $path = Join-Path $Runtime $RelativePath
    $source = [IO.File]::ReadAllText($path)
    if (!$source.Contains($Before)) { throw "Missing test injection in ${RelativePath}: $Before" }
    [IO.File]::WriteAllText($path,$source.Replace($Before,$After),[Text.UTF8Encoding]::new($true))
}

function Get-AutoHotkeyPath {
    $candidates = if ($env:AHK_EXE) { @($env:AHK_EXE) } else {
        @((Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'))
    }
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    throw "AutoHotkey v2 executable not found. Checked: $($candidates -join ', '). Set AHK_EXE to the full executable path."
}

# Takes ownership of the started process until exit, including timeout and wait failures.
function Wait-TestProcess {
    param([Diagnostics.Process]$Process, [int]$TimeoutMs)
    try {
        $null = $Process.Handle
        if ($TimeoutMs -lt 1) { throw 'Test process timeout must be positive.' }
        if (!$Process.WaitForExit($TimeoutMs)) { throw "Test process timed out after ${TimeoutMs}ms (PID $($Process.Id))." }
        $Process.WaitForExit()
        return $Process.ExitCode
    } finally {
        try {
            if (!$Process.HasExited) {
                $Process.Kill()
                $Process.WaitForExit()
            }
        } finally { $Process.Dispose() }
    }
}

function Invoke-AppTest {
    param([string]$Runtime, [string]$Body, [int]$TimeoutMs = 30000, [string]$Setup = '')
    $source = "#Requires AutoHotkey v2.0`r`n#SingleInstance Force`r`n#Include %A_ScriptDir%\src\app\app_modules.ahk`r`n#Include %A_ScriptDir%\library-model.ahk`r`n" + $Setup + "`r`nInitializeApplication(false)`r`n" + $Body
    Invoke-AhkTest -Runtime $Runtime -Source $source -TimeoutMs $TimeoutMs
}
function Invoke-AhkTest {
    param([string]$Runtime, [string]$Source, [int]$TimeoutMs = 30000)
    $entry = Join-Path $Runtime 'test.ahk'
    $preamble = @'
#Warn VarUnset, StdOut
global Checks := 0
OnError(FailTest)
Assert(condition, label) {
    global Checks
    if !condition
        FailTest(Error(label,-1))
    Checks++
}
FailTest(failure, *) {
    try {
        detail := failure is Error ? failure.Message " at " failure.File ":" failure.Line " " failure.Extra "`n" failure.Stack
            : (IsObject(failure) ? Type(failure) : failure)
        FileAppend("FAIL: test error: " detail "`n", "**")
    } finally ExitApp(1)
}
; Observe activation without activating or retrying; callers own the action under test.
RequireTestWindowActive(hwnd) {
    if active := WinWaitActive("ahk_id " hwnd,,2)
        return active
    foreground := DllCall("GetForegroundWindow","Ptr"), foregroundPid := 0
    DllCall("GetWindowThreadProcessId","Ptr",foreground,"UInt*",&foregroundPid)
    owner := DllCall("GetWindow","Ptr",hwnd,"UInt",4,"Ptr")
    throw Error("Test window did not become active: exists=" DllCall("IsWindow","Ptr",hwnd)
        . " visible=" DllCall("IsWindowVisible","Ptr",hwnd) " enabled=" DllCall("IsWindowEnabled","Ptr",hwnd)
        . " owner_enabled=" (owner ? DllCall("IsWindowEnabled","Ptr",owner) : "none")
        . " foreground_owned=" (foregroundPid=DllCall("GetCurrentProcessId")))
}
'@
    [IO.File]::WriteAllText($entry, $preamble + "`r`n" + $Source, [Text.UTF8Encoding]::new($true))
    $out = Join-Path $Runtime 'stdout.txt'
    $err = Join-Path $Runtime 'stderr.txt'
    $run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + $entry + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $exitCode = Wait-TestProcess -Process $run -TimeoutMs $TimeoutMs
    Get-Content -LiteralPath $out,$err
    if ($exitCode -ne 0) { throw "Test failed ($exitCode): $Runtime" }
}

function Write-TestWorker {
    param([string]$Runtime, [string]$Definitions)
    $source = @'
param([string]$PipeName)
. (Join-Path $PSScriptRoot 'browser_worker.ps1') -Library -PipeName $PipeName
'@ + "`r`n" + $Definitions + "`r`nStart-BrowserWorker `$PipeName -Handler { param(`$request) Invoke-FixtureRequest `$request }"
    [IO.File]::WriteAllText((Join-Path $Runtime 'src\browser\fixture_worker.ps1'),$source,[Text.UTF8Encoding]::new($true))
}
