# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# Native startup and transport faults do not require settings or application windows.
$startup = New-TestRuntime
$launch = '            if !DllCall("CreateProcessW", "Str", executable'
Edit-TestSource $startup 'src/browser/worker_client.ahk' $launch ('            executable := ProbeWorkerExecutable(executable)' + "`r`n" + $launch)
Invoke-AhkTest -Runtime $startup -Source @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
global WorkerLaunchFailure := true, FailedStartHandles := []
OnExit(StopBrowserWorker)
priorCritical := A_IsCritical, startupFailed := false
Critical(19)
try EnsureWorkerRunning()
catch as failure {
    startupFailed := failure is OSError
    startupCause := failure.Message
}
Assert(startupFailed && FailedStartHandles.Length=2,"native process launch fails after pipe and notification creation")
Assert(!IsWorkerRunning() && !WorkerState.ProcessId && !WorkerState.ProcessHandle && !WorkerState.PipeHandle && !WorkerState.SignalHandle,"failed startup releases all worker ownership")
for handle in FailedStartHandles
    Assert(!DllCall("GetHandleInformation","Ptr",handle,"UInt*",&flags:=0),"failed startup closes its native handle")
Assert(A_IsCritical=19,"failed startup restores caller interruption state")
Critical(priorCritical)
reply := NativeSendWorkerRequest(0,"fixture_no_action")
Assert(reply.State="unavailable" && reply.HasOwnProp("Detail") && reply.Detail==startupCause,"transport preserves the native startup failure in its reply")
Assert(!WorkerState.RequestActive && !WorkerState.ProcessHandle && !WorkerState.PipeHandle && !WorkerState.SignalHandle,"startup failure releases the request gate and all created resources")
WorkerLaunchFailure := false
reply := NativeSendWorkerRequest(0,"fixture_no_action")
Assert(reply.State="unavailable" && reply.Detail="" && IsWorkerRunning() && WorkerState.Sequence=1,"explicit retry receives a non-operating reply from a fresh worker without replay")
Assert(DllCall("GetProcessId","Ptr",WorkerState.ProcessHandle,"UInt")=WorkerState.ProcessId,"retry owns the exact worker process")
handles := [WorkerState.ProcessHandle,WorkerState.PipeHandle,WorkerState.SignalHandle]
StopBrowserWorker()
for handle in handles
    Assert(!DllCall("GetHandleInformation","Ptr",handle,"UInt*",&flags:=0),"retry cleanup closes each owned native handle")
Assert(!FileExist(A_ScriptDir "\data") && !IsSet(PaletteWindow),"startup fault and retry need no settings or application window")
FileAppend("PASS: " Checks " worker startup and retry checks; no application startup`n","*")
ExitApp()
ProbeWorkerExecutable(executable) {
    global FailedStartHandles
    if WorkerLaunchFailure {
        FailedStartHandles := [WorkerState.PipeHandle,WorkerState.SignalHandle]
        return A_ScriptDir "\missing-worker.exe"
    }
    return executable
}
'@
# The connection owns worker lifetime, including an owner that disappears without shutdown.
$pipeRuntime = New-TestRuntime
$workerEntry = Join-Path $pipeRuntime 'src\browser\browser_worker.ps1'
foreach ($scenario in @('disconnect','missing-signal','missing-server')) {
    $pipeName = 'chatpalette-lifetime-' + [guid]::NewGuid().ToString('N')
    $server = $null; $signal = $null; $connection = $null; $process = $null
    try {
        if ($scenario -ne 'missing-server') {
            $server = [IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536)
            $connection = $server.BeginWaitForConnection($null,$null)
        }
        if ($scenario -eq 'disconnect') {
            $signal = [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,$pipeName+'-ready')
        }
        $process = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$workerEntry+'"'),'-PipeName',$pipeName -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $pipeRuntime ($scenario+'.stdout.txt')) -RedirectStandardError (Join-Path $pipeRuntime ($scenario+'.stderr.txt'))
        $null = $process.Handle
        $ownedHandle = $process.SafeHandle
        if ($server) {
            if (!$connection.AsyncWaitHandle.WaitOne(5000)) { throw "Worker did not connect: $scenario" }
            $server.EndWaitForConnection($connection)
        }
        if ($signal) {
            if (!$signal.WaitOne(5000)) { throw 'Worker did not signal readiness' }
            $request = [Text.Encoding]::UTF8.GetBytes("Seq=1`nWindow=0`nMode=fixture_no_action`n")
            $header = [BitConverter]::GetBytes([int]$request.Length)
            $server.Write($header,0,$header.Length)
            $server.Write($request,0,$request.Length)
            $server.Flush()
            if (!$signal.WaitOne(5000)) { throw 'Worker did not reply' }
            $reader = [IO.BinaryReader]::new($server,[Text.Encoding]::UTF8,$true)
            try {
                $size = $reader.ReadInt32()
                if ($size -lt 1 -or $size -gt 32768) { throw 'Invalid worker reply length' }
                $body = $reader.ReadBytes($size)
                $reply = [Text.Encoding]::UTF8.GetString($body)
                if ($body.Length -ne $size -or $reply -notmatch '(?m)^Seq=1$' -or $reply -notmatch '(?m)^State=unavailable$' -or $reply -notmatch '(?m)^Window=0$') { throw 'Worker did not complete the isolated request' }
            } finally { $reader.Dispose() }
            $server.Dispose(); $server = $null
        }
        $owned = $process; $process = $null
        $code = Wait-TestProcess -Process $owned -TimeoutMs 8000
        if ($code -ne 1 -or !$ownedHandle.IsClosed) { throw "Worker did not exit and release its handle: $scenario" }
    } finally {
        if ($server) { $server.Dispose() }
        if ($connection) { $connection.AsyncWaitHandle.Dispose() }
        if ($signal) { $signal.Dispose() }
        if ($process) { Wait-TestProcess -Process $process -TimeoutMs 8000 | Out-Null }
    }
}
Write-Output 'PASS: worker exits on pipe disconnect, missing notification and missing server; isolated protocol only'
