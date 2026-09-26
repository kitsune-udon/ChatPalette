# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime=New-TestRuntime
$fixture=Join-Path $runtime 'tests'
New-Item -ItemType Directory -Path $fixture | Out-Null
$runner=Join-Path $fixture 'run.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run.ps1') -Destination $runner
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'support.ps1') -Destination $fixture
$headless=Join-Path $fixture 'test-alpha.ps1'
$desktop=Join-Path $fixture 'test-beta.ps1'
[IO.File]::WriteAllText($headless,"# Test-Session: Headless`r`nWrite-Output 'fixture-alpha'`r`n",[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText($desktop,"# Test-Session: Desktop`r`nWrite-Output 'fixture-beta'`r`n",[Text.UTF8Encoding]::new($true))
$base=Join-Path $fixture '.tmp'
$oldRoot=$env:HELPER_TEST_ROOT
$oldAhk=$env:AHK_EXE
$listed=@(& $runner -Name 'test-alpha.ps1' -List)
if ($listed.Count -ne 1 -or $listed[0] -ne 'test-alpha.ps1' -or (Test-Path -LiteralPath $base)) { throw 'Named listing did not select exactly one test without preparing a runtime' }
foreach ($arguments in @(@{Name='missing.ps1'},@{Name='test-beta.ps1';Group='Headless'},@{Name=''},@{Nmae='test-alpha.ps1'})) {
    $rejected=$false
    try { & $runner @arguments | Out-Null } catch { $rejected=$true }
    if (!$rejected -or (Test-Path -LiteralPath $base)) { throw 'Invalid selection started a test or created a runtime' }
}
$output=@(& $runner -Name 'test-alpha.ps1')
if ($output -notcontains 'fixture-alpha' -or $output -contains 'fixture-beta' -or ($output -join "`n") -notmatch 'PASS: test-alpha\.ps1 / 1 test groups') { throw 'Named run did not execute exactly the selected test' }
if (@(Get-ChildItem -LiteralPath $base -Directory).Count -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk) { throw 'Successful named run did not clean up or restore its environment' }
$output=@(& $runner -Group Desktop)
if ($output -notcontains 'fixture-beta' -or $output -contains 'fixture-alpha' -or ($output -join "`n") -notmatch 'PASS: Desktop / 1 test groups') { throw 'Group selection changed' }
$output=@(& $runner)
if ($output -notcontains 'fixture-alpha' -or $output -notcontains 'fixture-beta' -or ($output -join "`n") -notmatch 'PASS: All / 2 test groups') { throw 'Default run did not execute every test' }
[IO.File]::WriteAllText($headless,"# Test-Session: Headless`r`nthrow 'fixture failure'`r`n",[Text.UTF8Encoding]::new($true))
$failed=$false
try { & $runner -Name 'test-alpha.ps1' -AutoHotkeyPath 'fixture-runtime.exe' -WarningAction SilentlyContinue | Out-Null } catch { $failed=$true }
$retained=@(Get-ChildItem -LiteralPath $base -Directory)
if (!$failed -or $retained.Count -ne 1 -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk) { throw 'Failed named run did not retain evidence or restore its environment' }
$stderr=Join-Path $retained[0].FullName 'test-alpha.ps1.stderr.txt'
if (!(Test-Path -LiteralPath $stderr) -or [IO.File]::ReadAllText($stderr) -notmatch 'fixture failure') { throw 'Failed test stderr was not retained' }
# A callback or adapted property may swallow exceptions and even exit statements.
# Failure evidence must survive that boundary, and finally blocks must still run.
foreach ($kind in @('stderr','assertion','callback-assertion','property-assertion','method-assertion','caught')) {
    $source=@'
# Test-Session: Headless
. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $PSScriptRoot '..\src\browser\page_actions.ps1')
if ($script:checks -ne 0) { throw 'Assertion count was not reset' }
Assert $true 'first check'
if ($script:checks -ne 1) { throw 'Successful assertion was not counted' }
try {
'@ + "`r`n" + $(switch ($kind) {
        'stderr' { "[Console]::Error.WriteLine('PowerShell fixture failure')" }
        'assertion' { "Assert `$false 'PowerShell fixture failure'" }
        'callback-assertion' { @'
function Test-ReactionForeground { Assert $false 'PowerShell fixture failure' }
$null=Invoke-PageAction @{Seq=1;Window=123;Mode='chat_focus'}
'@ }
        'property-assertion' { @'
$target=[pscustomobject]@{}
$target | Add-Member ScriptProperty Current { Assert $false 'PowerShell fixture failure' }
$null=$target.Current
'@ }
        'method-assertion' { @'
$target=[pscustomobject]@{}
$target | Add-Member ScriptMethod Read { Assert $false 'PowerShell fixture failure' }
try { $null=$target.Read() } catch { }
'@ }
        'caught' { "try { throw 'injected failure' } catch { }" }
    }) + @'

} finally { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'probe-cleanup.txt'),[string]$script:checks) }
'@
    [IO.File]::WriteAllText($headless,$source,[Text.UTF8Encoding]::new($true))
    $cleanup=Join-Path $fixture 'probe-cleanup.txt'
    if (Test-Path -LiteralPath $cleanup) { Remove-Item -LiteralPath $cleanup }
    $before=@(Get-ChildItem -LiteralPath $base -Directory | Select-Object -ExpandProperty FullName)
    $failed=$false
    try { & $runner -Name 'test-alpha.ps1' -WarningAction SilentlyContinue | Out-Null } catch { $failed=$true }
    if ([IO.File]::ReadAllText($cleanup) -ne '1') { throw "PowerShell $kind lost cleanup or counted a failed assertion" }
    $retained=@(Get-ChildItem -LiteralPath $base -Directory | Where-Object FullName -NotIn $before)
    if ($kind -eq 'caught') {
        if ($failed -or $retained.Count) { throw 'A caught injected exception failed the test' }
    } else {
        if (!$failed -or $retained.Count -ne 1) { throw "PowerShell $kind failure was swallowed" }
        $stderr=[IO.File]::ReadAllText((Join-Path $retained[0].FullName 'test-alpha.ps1.stderr.txt'))
        if ($stderr -notmatch 'PowerShell fixture failure') { throw "PowerShell $kind failure evidence was lost" }
        if ($kind -ne 'stderr' -and $stderr -notmatch 'test-alpha\.ps1:\d+') { throw 'Assertion caller was not recorded' }
    }
}
# Benchmark options use the same binding boundary as the test runner.
foreach ($benchmark in @('benchmark-storage.ps1','benchmark-ui.ps1')) {
    $benchmarkPath=Join-Path $fixture $benchmark
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $benchmark) -Destination $benchmarkPath
    $arguments=if ($benchmark -eq 'benchmark-storage.ps1') { @{SourceRoot=(Join-Path $fixture 'missing');SourceRoto='unused'} }
        else { @{Counts=0;Countz=1} }
    $rejected=$false
    try { & $benchmarkPath @arguments | Out-Null }
    catch [Management.Automation.ParameterBindingException] { $rejected=$true }
    if (!$rejected) { throw "$benchmark did not reject a misspelled option before executing" }
}
# The same process owner handles successful, failing and unfinished child processes.
$probe=Join-Path $runtime 'process-probe.ps1'
[IO.File]::WriteAllText($probe,@'
param([string]$Mode)
[Console]::Out.WriteLine('probe stdout')
[Console]::Error.WriteLine('probe stderr')
if ($Mode -in @('timeout','invalid-timeout')) { Start-Sleep -Seconds 30 }
if ($Mode -eq 'failure') { exit 17 }
exit 0
'@,[Text.UTF8Encoding]::new($true))
foreach ($mode in @('success','failure','timeout','invalid-timeout')) {
    $stdout=Join-Path $runtime ($mode+'.stdout.txt')
    $stderr=Join-Path $runtime ($mode+'.stderr.txt')
    $process=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$probe+'"'),'-Mode',$mode -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null=$process.Handle
    $handle=$process.SafeHandle
    $probeId=$process.Id
    $probeStarted=$process.StartTime
    $live=$null
    try {
        $failure=''
        $timeout=if ($mode -eq 'invalid-timeout') { 0 } else { 5000 }
        try { $code=Wait-TestProcess -Process $process -TimeoutMs $timeout }
        catch { $failure=$_.Exception.Message }
        if (!$handle.IsClosed) { throw "Process handle retained after $mode" }
        $live=Get-Process -Id $probeId -ErrorAction SilentlyContinue
        if ($live -and $live.StartTime -eq $probeStarted) { throw "Child process survived $mode" }
        if ($mode -eq 'invalid-timeout') {
            if ($failure -ne 'Test process timeout must be positive.') { throw 'Invalid timeout did not fail with cleanup' }
        } elseif ($mode -eq 'timeout') {
            if ($failure -notmatch '^Test process timed out after 5000ms') { throw "Timeout did not fail with cleanup: $failure" }
        } else {
            $expected=if ($mode -eq 'failure') { 17 } else { 0 }
            if ($failure -or $code -ne $expected) { throw "Child exit code was lost: $mode / $failure" }
        }
        if ($mode -ne 'invalid-timeout' -and ([IO.File]::ReadAllText($stdout).Trim() -ne 'probe stdout' -or [IO.File]::ReadAllText($stderr).Trim() -ne 'probe stderr')) { throw "Child output was lost after $mode" }
    } finally {
        # If an assertion exposes a lifecycle bug, clean up only this exact child.
        if (!$handle.IsClosed) {
            try { if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() } }
            finally { $process.Dispose() }
        }
        if ($live) {
            try { if ($live.StartTime -eq $probeStarted -and !$live.HasExited) { $live.Kill(); $live.WaitForExit() } }
            finally { $live.Dispose() }
        }
    }
}
# Unhandled AHK failures must reach stderr and the process exit code, even from timers.
foreach ($kind in @('synchronous','timer','assertion','callback-assertion','stderr','caught')) {
    $ahkRuntime=Join-Path $runtime ('ahk-'+$kind)
    New-Item -ItemType Directory -Path $ahkRuntime | Out-Null
    $source=@'
#Requires AutoHotkey v2.0
OnExit((reason,code) => FileAppend(reason "," code,A_ScriptDir "\exit.txt"))
TriggerFixtureFailure(*) {
    throw Error("AHK fixture failure")
}
'@
    $source += "`r`n" + $(if ($kind -eq 'timer') {
        "SetTimer(TriggerFixtureFailure,-10)`r`nSleep(1000)`r`nExitApp(0)`r`n"
    } elseif ($kind -eq 'assertion') {
@'
if Checks != 0
    throw Error("Assertion count leaked across runtimes")
Assert(true,"first check")
if Checks != 1
    throw Error("Successful assertion was not counted")
Assert(false,"AHK fixture failure")
ExitApp(0)
'@
    } elseif ($kind -eq 'callback-assertion') {
@'
#Include %A_ScriptDir%\..\src\app\runtime_ports.ahk
#Include %A_ScriptDir%\..\src\input\text_input.ahk
RuntimePorts.Text := (*) => Assert(false,"AHK fixture failure")
; The product catches transport errors, but a failed test condition must still fail the test.
SendInputText("fixture")
ExitApp(0)
'@
    } elseif ($kind -eq 'stderr') {
        "FileAppend('AHK fixture failure', '**')`r`nExitApp(0)`r`n"
    } elseif ($kind -eq 'caught') {
        "try TriggerFixtureFailure()`r`ncatch {`r`n    FileAppend('caught fixture failure', '*')`r`n}`r`nExitApp(0)`r`n"
    } else { "TriggerFixtureFailure()`r`nExitApp(0)`r`n" })
    $failure=''
    try { Invoke-AhkTest -Runtime $ahkRuntime -Source $source -TimeoutMs 5000 | Out-Null }
    catch { $failure=$_.Exception.Message }
    $stderr=[IO.File]::ReadAllText((Join-Path $ahkRuntime 'stderr.txt'))
    $exitFile=Join-Path $ahkRuntime 'exit.txt'
    if (!(Test-Path -LiteralPath $exitFile)) { throw "AHK $kind failure skipped normal exit cleanup: $failure" }
    if ($kind -eq 'caught') {
        if ($failure -or $stderr -or [IO.File]::ReadAllText($exitFile) -ne 'Exit,0') { throw 'Caught AHK exception was incorrectly treated as unhandled' }
    } elseif ($kind -eq 'stderr') {
        if ($failure -notmatch '^Test failed \(0\):' -or $stderr -ne 'AHK fixture failure' -or [IO.File]::ReadAllText($exitFile) -ne 'Exit,0') {
            throw 'AHK stderr was accepted or its output and normal exit cleanup were lost'
        }
    } else {
        if ($failure -notmatch '^Test failed \(1\):' -or $stderr -notmatch 'AHK fixture failure' -or $stderr -notmatch 'test\.ahk:\d+' -or [IO.File]::ReadAllText($exitFile) -ne 'Exit,1') {
            throw "AHK $kind failure did not record its location and exit with cleanup: $failure"
        }
        if ($kind -in @('assertion','callback-assertion')) {
            $entry=Join-Path $ahkRuntime 'test.ahk'
            $assertionLine=(Select-String -LiteralPath $entry -SimpleMatch 'Assert(false,"AHK fixture failure")').LineNumber
            if (!$stderr.Contains("${entry}:$assertionLine")) { throw 'Assertion failure did not identify its caller' }
        }
    }
}
Write-Output 'PASS: test selection, cleanup, failure evidence, process ownership and PowerShell/AHK assertion failures'
