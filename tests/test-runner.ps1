# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime=New-TestRuntime
$fixture=Join-Path $runtime 'tests'
New-Item -ItemType Directory -Path $fixture | Out-Null
$runner=Join-Path $fixture 'run.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run.ps1') -Destination $runner
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'support.ps1') -Destination $fixture
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'execute-check.ps1') -Destination $fixture
$scripts=Join-Path $runtime 'scripts'
New-Item -ItemType Directory -Path $scripts | Out-Null
$sourceCheck=Join-Path $scripts 'check-source.ps1'
$sourceProbe=@'
$hash=Get-FileHash -LiteralPath $PSCommandPath
if ($hash.Hash.Length -ne 64) { throw 'Source check could not use the standard hashing module' }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\source-ready'),'validated')
Write-Output 'fixture-source'
'@
[IO.File]::WriteAllText($sourceCheck,$sourceProbe,[Text.UTF8Encoding]::new($true))
$headless=Join-Path $fixture 'test-alpha.ps1'
$desktop=Join-Path $fixture 'test-beta.ps1'
[IO.File]::WriteAllText($headless,@'
# Test-Session: Headless
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'Tests must run in Windows PowerShell 5.1' }
if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\source-ready'))) { throw 'Test started before source validation' }
if ((Get-FileHash -LiteralPath $PSCommandPath).Hash.Length -ne 64) { throw 'Test could not use the standard hashing module' }
Write-Output 'fixture-alpha'
'@,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText($desktop,"# Test-Session: Desktop`r`nWrite-Output 'fixture-beta'`r`n",[Text.UTF8Encoding]::new($true))
$base=Join-Path $fixture '.tmp'
$oldRoot=$env:HELPER_TEST_ROOT
$oldAhk=$env:AHK_EXE
$oldModulePath=$env:PSModulePath
$listed=@(& $runner -Name 'test-alpha.ps1' -List)
if ($listed.Count -ne 1 -or $listed[0] -ne 'test-alpha.ps1' -or (Test-Path -LiteralPath $base)) { throw 'Named listing did not select exactly one test without preparing a runtime' }
$listed=@(& $runner -Name 'test-beta.ps1','test-alpha.ps1','test-alpha.ps1' -List)
if (($listed -join ',') -ne 'test-alpha.ps1,test-beta.ps1' -or (Test-Path -LiteralPath $base)) { throw 'Multiple-name listing did not sort and deduplicate without execution' }
foreach ($arguments in @(@{Name='missing.ps1'},@{Name='test-beta.ps1';Group='Headless'},@{Name=''},@{Nmae='test-alpha.ps1'},
    @{Name=@('test-alpha.ps1','missing.ps1')},@{Name=@('test-alpha.ps1','test-beta.ps1');Group='Headless'},
    @{Name=@('test-alpha.ps1','missing.ps1');List=$true})) {
    $rejected=$false
    try { & $runner @arguments | Out-Null } catch { $rejected=$true }
    if (!$rejected -or (Test-Path -LiteralPath $base)) { throw 'Invalid selection started a test or created a runtime' }
}
$output=@(& $runner -Name 'test-alpha.ps1')
if (@($output | Where-Object { $_ -eq 'fixture-source' }).Count -ne 1) { throw 'Named run did not validate source exactly once' }
if ($output -notcontains 'fixture-alpha' -or $output -contains 'fixture-beta' -or ($output -join "`n") -notmatch 'PASS: test-alpha\.ps1 / 1 test groups') { throw 'Named run did not execute exactly the selected test' }
if (@(Get-ChildItem -LiteralPath $base -Directory).Count -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk -or $env:PSModulePath -cne $oldModulePath) { throw 'Successful named run did not clean up or restore its environment' }
$output=@(& $runner -Name 'test-beta.ps1','test-alpha.ps1','test-alpha.ps1')
$runs=@($output | Where-Object { $_ -like 'RUN: *' })
if (($runs -join ',') -ne 'RUN: check-source.ps1,RUN: test-alpha.ps1,RUN: test-beta.ps1' -or
    @($output | Where-Object { $_ -eq 'fixture-source' }).Count -ne 1 -or
    $output -notcontains 'fixture-alpha' -or $output -notcontains 'fixture-beta' -or
    ($output -join "`n") -notmatch 'PASS: test-alpha\.ps1, test-beta\.ps1 / 2 test groups') { throw 'Multiple-name run skipped, repeated or reordered a check' }
if (@(Get-ChildItem -LiteralPath $base -Directory).Count -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk -or $env:PSModulePath -cne $oldModulePath) { throw 'Multiple-name run did not clean up or restore its environment' }
$output=@(& $runner -Group Desktop)
if (@($output | Where-Object { $_ -eq 'fixture-source' }).Count -ne 1) { throw 'Desktop selection skipped or repeated source validation' }
if ($output -notcontains 'fixture-beta' -or $output -contains 'fixture-alpha' -or ($output -join "`n") -notmatch 'PASS: Desktop / 1 test groups') { throw 'Group selection changed' }
$output=@(& $runner)
if (@($output | Where-Object { $_ -eq 'fixture-source' }).Count -ne 1) { throw 'Default run skipped or repeated source validation' }
if ($output -notcontains 'fixture-alpha' -or $output -notcontains 'fixture-beta' -or ($output -join "`n") -notmatch 'PASS: All / 2 test groups') { throw 'Default run did not execute every test' }
[IO.File]::WriteAllText($headless,"# Test-Session: Headless`r`nthrow 'fixture failure'`r`n",[Text.UTF8Encoding]::new($true))
$failed=$false
try { & $runner -Name 'test-alpha.ps1' -AutoHotkeyPath 'fixture-runtime.exe' -WarningAction SilentlyContinue | Out-Null } catch { $failed=$true }
$retained=@(Get-ChildItem -LiteralPath $base -Directory)
if (!$failed -or $retained.Count -ne 1 -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk -or $env:PSModulePath -cne $oldModulePath) { throw 'Failed named run did not retain evidence or restore its environment' }
$stderr=Join-Path $retained[0].FullName 'test-alpha.ps1.stderr.txt'
if (!(Test-Path -LiteralPath $stderr) -or [IO.File]::ReadAllText($stderr) -notmatch 'fixture failure') { throw 'Failed test stderr was not retained' }
# Source failure stops before any selected test starts; listing still remains read-only.
try {
    [IO.File]::WriteAllText($sourceCheck,"throw 'fixture source failure'",[Text.UTF8Encoding]::new($true))
    $before=@(Get-ChildItem -LiteralPath $base -Directory | Select-Object -ExpandProperty FullName)
    $listed=@(& $runner -Name 'test-alpha.ps1' -List)
    if ($listed.Count -ne 1 -or $listed[0] -ne 'test-alpha.ps1') { throw 'Listing ran source validation' }
    $failure=''; $observed=[Collections.Generic.List[string]]::new()
    try { & $runner -Name 'test-alpha.ps1' -WarningAction SilentlyContinue | ForEach-Object { $observed.Add([string]$_) } }
    catch { $failure=$_.Exception.Message }
    $retained=@(Get-ChildItem -LiteralPath $base -Directory | Where-Object FullName -NotIn $before)
    if ($failure -ne 'Failed: check-source.ps1' -or $observed.Contains('RUN: test-alpha.ps1') -or $retained.Count -ne 1) { throw 'Source failure did not stop before the selected tests' }
    if ([IO.File]::ReadAllText((Join-Path $retained[0].FullName 'check-source.ps1.stderr.txt')) -notmatch 'fixture source failure') { throw 'Source failure lost its diagnostic evidence' }
    if ($env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk -or $env:PSModulePath -cne $oldModulePath) { throw 'Source failure changed the caller environment' }
} finally { [IO.File]::WriteAllText($sourceCheck,$sourceProbe,[Text.UTF8Encoding]::new($true)) }
# Earlier successful groups must be gone before the next group starts.
[IO.File]::WriteAllText($headless,@'
# Test-Session: Headless
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'alpha-root.txt'),$env:HELPER_TEST_ROOT)
[IO.File]::WriteAllText((Join-Path $env:HELPER_TEST_ROOT 'successful-copy.txt'),'completed')
Write-Output 'fixture-alpha'
'@,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText($desktop,@'
# Test-Session: Desktop
$earlier=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'alpha-root.txt'))
if (Test-Path -LiteralPath $earlier) { throw 'Successful group artifacts survived into the next group' }
[IO.File]::WriteAllText((Join-Path $env:HELPER_TEST_ROOT 'failed-copy.txt'),'diagnostic evidence')
throw 'fixture beta failure'
'@,[Text.UTF8Encoding]::new($true))
$before=@(Get-ChildItem -LiteralPath $base -Directory | Select-Object -ExpandProperty FullName)
$failed=$false
try { & $runner -Group All -AutoHotkeyPath 'fixture-runtime.exe' -WarningAction SilentlyContinue | Out-Null } catch { $failed=$true }
$retained=@(Get-ChildItem -LiteralPath $base -Directory | Where-Object FullName -NotIn $before)
if (!$failed -or $retained.Count -ne 1 -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk -or $env:PSModulePath -cne $oldModulePath) { throw 'A later group failure lost isolation or environment restoration' }
$failedRoot=$retained[0].FullName
if (!(Test-Path -LiteralPath (Join-Path $failedRoot 'failed-copy.txt')) -or (Test-Path -LiteralPath (Join-Path $failedRoot 'successful-copy.txt'))) { throw 'A later failure did not retain only its own artifacts' }
if ([IO.File]::ReadAllText((Join-Path $failedRoot 'test-beta.ps1.stderr.txt')) -notmatch 'fixture beta failure') { throw 'The later group failure lost its diagnostic output' }
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
        'stderr' { "[Console]::Error.WriteLine('PowerShell fixture failure 日本語 🧪')" }
        'assertion' { "Assert `$false 'PowerShell fixture failure 日本語 🧪'" }
        'callback-assertion' { @'
function Test-BrowserForeground { Assert $false 'PowerShell fixture failure 日本語 🧪' }
$null=Invoke-PageAction @{Seq=1;Window=123;Mode='chat_focus'}
'@ }
        'property-assertion' { @'
$target=[pscustomobject]@{}
$target | Add-Member ScriptProperty Current { Assert $false 'PowerShell fixture failure 日本語 🧪' }
$null=$target.Current
'@ }
        'method-assertion' { @'
$target=[pscustomobject]@{}
$target | Add-Member ScriptMethod Read { Assert $false 'PowerShell fixture failure 日本語 🧪' }
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
        if ($stderr -notmatch 'PowerShell fixture failure 日本語 🧪') { throw "PowerShell $kind failure evidence was lost" }
        if ($kind -ne 'stderr' -and $stderr -notmatch 'test-alpha\.ps1:\d+') { throw 'Assertion caller was not recorded' }
    }
}
# Timeout diagnostics must reach the console as well as the retained files.
$runnerBytes=[IO.File]::ReadAllBytes($runner)
try {
    Edit-TestSource $runtime 'tests/run.ps1' '-TimeoutMs 120000' '-TimeoutMs 5000'
    [IO.File]::WriteAllText($headless,@'
# Test-Session: Headless
Write-Output 'last PowerShell step before timeout 日本語 🧪'
[Console]::Error.WriteLine('PowerShell diagnostic before timeout 日本語 🧪')
Start-Sleep -Seconds 30
'@,[Text.UTF8Encoding]::new($true))
    $before=@(Get-ChildItem -LiteralPath $base -Directory | Select-Object -ExpandProperty FullName)
    $observed=[Collections.Generic.List[string]]::new()
    $failure=''
    try { & $runner -Name 'test-alpha.ps1' -WarningAction SilentlyContinue | ForEach-Object { $observed.Add([string]$_) } }
    catch { $failure=$_.Exception.Message }
    if ($failure -notmatch '^Test process timed out after 5000ms' -or
        !$observed.Contains('last PowerShell step before timeout 日本語 🧪') -or !$observed.Contains('PowerShell diagnostic before timeout 日本語 🧪')) {
        throw 'Group timeout hid its last output or original timeout error'
    }
    $retained=@(Get-ChildItem -LiteralPath $base -Directory | Where-Object FullName -NotIn $before)
    if ($retained.Count -ne 1 -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk -or $env:PSModulePath -cne $oldModulePath) { throw 'Group timeout lost evidence or environment restoration' }
} finally { [IO.File]::WriteAllBytes($runner,$runnerBytes) }
$ahkTimeout=Join-Path $runtime 'ahk-timeout'
New-Item -ItemType Directory -Path $ahkTimeout | Out-Null
$observed=[Collections.Generic.List[string]]::new()
$failure=''
try {
    Invoke-AhkTest -Runtime $ahkTimeout -TimeoutMs 2000 -Source @'
#Requires AutoHotkey v2.0
FileAppend("last AHK step before timeout 日本語 🧪`n","*")
FileAppend("AHK diagnostic before timeout 日本語 🧪`n","**")
Sleep(30000)
'@ | ForEach-Object { $observed.Add([string]$_) }
} catch { $failure=$_.Exception.Message }
if ($failure -notmatch '^Test process timed out after 2000ms' -or
    !$observed.Contains('last AHK step before timeout 日本語 🧪') -or !$observed.Contains('AHK diagnostic before timeout 日本語 🧪')) {
    throw 'AHK timeout hid its last output or original timeout error'
}
# Benchmark options use the same binding boundary as the test runner.
foreach ($benchmark in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'benchmark-*.ps1' -File) {
    $benchmarkPath=Join-Path $fixture $benchmark.Name
    Copy-Item -LiteralPath $benchmark.FullName -Destination $benchmarkPath
    $rejected=$false
    try { & $benchmarkPath -Repeats 1 -Repeets 1 | Out-Null }
    catch [Management.Automation.ParameterBindingException] {
        if ($_.Exception.ParameterName -ne 'Repeets') { throw }
        $rejected=$true
    }
    if (!$rejected) { throw "$($benchmark.Name) did not reject a misspelled option before executing" }
}
# The same process owner handles successful, failing and unfinished child processes.
$probe=Join-Path $runtime 'process-probe.ps1'
[IO.File]::WriteAllText($probe,@'
param([string]$Mode)
[Console]::Out.WriteLine('probe stdout')
[Console]::Error.WriteLine('probe stderr')
if ($Mode -eq 'tree') {
    $child=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Mode','descendant' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $PSScriptRoot 'descendant.stdout.txt') -RedirectStandardError (Join-Path $PSScriptRoot 'descendant.stderr.txt')
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'descendant.txt'),($child.Id.ToString()+','+$child.StartTime.ToUniversalTime().Ticks.ToString()))
}
if ($Mode -in @('timeout','invalid-timeout','tree','descendant')) { Start-Sleep -Seconds 30 }
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
# A timed-out test must not leave its worker behind or stop unrelated instances.
$tree=$null; $descendant=$null; $sibling=$null
try {
    $sibling=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$probe+'"'),'-Mode','descendant' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runtime 'sibling.stdout.txt') -RedirectStandardError (Join-Path $runtime 'sibling.stderr.txt')
    $null=$sibling.Handle
    $tree=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$probe+'"'),'-Mode','tree' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runtime 'tree.stdout.txt') -RedirectStandardError (Join-Path $runtime 'tree.stderr.txt')
    $null=$tree.Handle
    $treeHandle=$tree.SafeHandle
    $identityPath=Join-Path $runtime 'descendant.txt'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while (!(Test-Path -LiteralPath $identityPath) -and !$tree.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    $identity=[IO.File]::ReadAllText($identityPath).Split(',')
    $descendant=Get-Process -Id ([int]$identity[0])
    $null=$descendant.Handle
    if ($descendant.StartTime.ToUniversalTime().Ticks -ne [long]$identity[1]) { throw 'Descendant identity changed before the timeout probe' }
    $failure=''
    try { $null=Wait-TestProcess -Process $tree -TimeoutMs 100 } catch { $failure=$_.Exception.Message }
    if ($failure -notmatch '^Test process timed out after 100ms' -or !$treeHandle.IsClosed) { throw 'Process tree timeout lost its error or root handle cleanup' }
    if (!$descendant.WaitForExit(5000)) { throw 'Timed-out test left its descendant running' }
    if ($sibling.HasExited) { throw 'Test timeout stopped an unrelated instance of the same executable' }
} finally {
    foreach ($owned in @($tree,$descendant,$sibling)) {
        if (!$owned) { continue }
        if ($owned -eq $tree -and $treeHandle.IsClosed) { continue }
        try { if (!$owned.HasExited) { $owned.Kill(); $owned.WaitForExit() } }
        finally { $owned.Dispose() }
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
    throw Error("AHK fixture failure 日本語 🧪")
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
Assert(false,"AHK fixture failure 日本語 🧪")
ExitApp(0)
'@
    } elseif ($kind -eq 'callback-assertion') {
@'
#Include %A_ScriptDir%\..\src\app\runtime_ports.ahk
#Include %A_ScriptDir%\..\src\input\text_input.ahk
RuntimePorts.Text := (*) => Assert(false,"AHK fixture failure 日本語 🧪")
; The product catches transport errors, but a failed test condition must still fail the test.
SendInputText("fixture")
ExitApp(0)
'@
    } elseif ($kind -eq 'stderr') {
        "FileAppend('AHK fixture failure 日本語 🧪', '**')`r`nExitApp(0)`r`n"
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
        if ($failure -notmatch '^Test failed \(0\):' -or $stderr -ne 'AHK fixture failure 日本語 🧪' -or [IO.File]::ReadAllText($exitFile) -ne 'Exit,0') {
            throw 'AHK stderr was accepted or its output and normal exit cleanup were lost'
        }
    } else {
        if ($failure -notmatch '^Test failed \(1\):' -or $stderr -notmatch 'AHK fixture failure 日本語 🧪' -or $stderr -notmatch 'test\.ahk:\d+' -or [IO.File]::ReadAllText($exitFile) -ne 'Exit,1') {
            throw "AHK $kind failure did not record its location and exit with cleanup: $failure"
        }
        if ($kind -in @('assertion','callback-assertion')) {
            $entry=Join-Path $ahkRuntime 'test.ahk'
            $assertionLine=(Select-String -LiteralPath $entry -SimpleMatch 'Assert(false,"AHK fixture failure 日本語 🧪")').LineNumber
            if (!$stderr.Contains("${entry}:$assertionLine")) { throw 'Assertion failure did not identify its caller' }
        }
    }
}
Write-Output 'PASS: test selection, cleanup, failure evidence, process ownership and PowerShell/AHK assertion failures'
