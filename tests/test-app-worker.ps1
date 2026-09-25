# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
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

$release = New-TestRuntime
$launch = '            if !DllCall("CreateProcessW", "Str", executable'
Edit-TestSource $release 'src/browser/worker_client.ahk' $launch ('            executable := ProbeWorkerExecutable(executable)' + "`r`n" + $launch)
Invoke-AppFixture -Runtime $release -Body @'
    global WorkerLaunchFailure := true, FailedStartHandles := []
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
    for entry in ["transport","browser"] {
        reply := entry="transport" ? NativeSendWorkerRequest(123,"verify_input") : NativeRequestBrowserOperation(123,"verify_input")
        Assert(reply.State="unavailable" && reply.HasOwnProp("Detail") && reply.Detail==startupCause,entry ": startup failure preserves its cause in the reply")
        Assert(!WorkerState.RequestActive && !IsBrowserOperationBusy && !WorkerState.ProcessHandle && !WorkerState.PipeHandle && !WorkerState.SignalHandle,entry ": startup failure releases request gates and all created resources")
    }
    WorkerLaunchFailure := false
    identityWindow := Gui(), identityHwnd := identityWindow.Hwnd
    Assert(!NativeIsBrowser(identityHwnd),"native identity rejects an existing non-browser window")
    identityWindow.Destroy()
    Assert(!NativeIsBrowser(identityHwnd) && !NativeIsBrowser(0),"native identity rejects closed and absent windows without throwing")
    registrationTokens := "["
    Loop 5
        registrationTokens .= (A_Index>1 ? "," : "") '{"name":"reaction' A_Index '","id":"id' A_Index '","class":"button","type":50000}'
    registrationTokens .= "]"
    SaveReactionRegistration('{"browser":"fixture","tokens":' registrationTokens '}')
    context := RequestBrowserOperation(123, "browser_context")
    Assert(context.State = "ok" && context.Video = "abcdefghijk", "pipe reaction context")
    Assert(IsWorkerRunning() && DllCall("GetProcessId","Ptr",WorkerState.ProcessHandle,"UInt")=WorkerState.ProcessId,"retry owns the exact process that answers the pipe")
    Assert(ReadDiagnosticSnapshot().Worker="起動中","diagnostics observes the owned running process")
    result := RequestBrowserOperation(123, "reaction_check", context.Video)
    Assert(result.State = "ready", "non-sending check through pipe")
    BuildManagement()
    checkJob := CreateReactionJob({Mode:"reaction_check",Window:123,Video:context.Video})
    ActiveReactionJob := checkJob
    SetReactionStatus("送らずに確認中")
    Assert(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"non-sending check disables conflicting controls")
    ReactionCountdown()
    Assert(!ActiveReactionJob && checkJob.Phase="finished" && LastReactionResult.Reason="ready","non-sending check completes and releases job")
    Assert(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"successful check restores controls without reopening windows")
    result := RequestBrowserOperation(123, "reaction_send", "ABCDEFGHIJK", "Reaction=1`n")
    Assert(result.State = "changed", "changed video rejected through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "mock operation through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "no implicit cooldown between operations")
    Assert(IsWorkerRegistrationCurrent(),"running worker owns the synchronized registrations")
    firstPID := WorkerState.ProcessId, crashedHandle := WorkerState.ProcessHandle
    sequenceBeforeCrash := WorkerState.Sequence
    ProcessClose(firstPID)
    ProcessWaitClose(firstPID, 2)
    Assert(DllCall("WaitForSingleObject","Ptr",crashedHandle,"UInt",0,"UInt")=0 && !IsWorkerRunning(),"terminated worker remains identifiable but is not running")
    Assert(ReadDiagnosticSnapshot().Worker="待機中（必要なときに起動）","diagnostics does not mistake an exited process handle for a running worker")
    Assert(!IsWorkerRegistrationCurrent(),"terminated worker is never reported as synchronized")
    recovered := RequestBrowserOperation(123, "browser_context")
    Assert(recovered.State = "ok" && WorkerState.ProcessId != firstPID && WorkerState.Sequence = sequenceBeforeCrash + 1, "crashed worker restarts on next request without replay")
    Assert(!IsWorkerRegistrationCurrent(),"restarted worker cannot inherit the previous synchronization state")
    result := RequestBrowserOperation(123,"reaction_check",context.Video)
    Assert(result.State="ready" && IsWorkerRegistrationCurrent(),"restarted worker becomes current only after restoring committed registrations")
    firstPID := WorkerState.ProcessId
    stoppedHandles := [WorkerState.ProcessHandle,WorkerState.PipeHandle,WorkerState.SignalHandle]
    StopBrowserWorker()
    Assert(!ProcessExist(firstPID) && !WorkerState.ProcessHandle && !WorkerState.ProcessId, "worker shuts down and releases process identity")
    for handle in stoppedHandles
        Assert(!DllCall("GetHandleInformation","Ptr",handle,"UInt*",&flags:=0),"shutdown closes each owned native handle")
    StopBrowserWorker()
    Assert(!IsWorkerRunning(),"repeated shutdown is harmless")
    context := RequestBrowserOperation(123, "browser_context")
    global StoppedWhileWaiting := false
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send", Cancelled:false, Completed:0, Total:1})
    waitingJob := ActiveReactionJob
    SetTimer(CancelDuringFixtureWait, -30)
    ; A changed-video reply exercises the real input preflight without inspecting desktop input.
    delayed := RequestBrowserOperation(123, "verify_input", "ABCDEFGHIJK", "FixtureDelay=250`n")
    Assert(delayed.State = "changed" && StoppedWhileWaiting && waitingJob.Cancelled, "notification wait pumps cancellation before response")
    CancelReaction()
    blockedHandle := WorkerState.ProcessHandle
    timedOut := SendWorkerRequest(123, "verify_input", context.Video, "FixtureDelay=3500`n")
    Assert(timedOut.State = "unavailable" && !WorkerState.ProcessId && !WorkerState.PipeHandle && !WorkerState.SignalHandle, "timeout releases pipe and notification resources")
    Assert(!DllCall("GetHandleInformation","Ptr",blockedHandle,"UInt*",&flags:=0),"timeout closes the terminated process handle")
    Assert(timedOut.HasOwnProp("Detail") && timedOut.Detail="補助プロセスの応答が時間内に届きませんでした。","timeout preserves its cause without exposing request data")
    context := RequestBrowserOperation(123, "browser_context")
    crashed := SendWorkerRequest(123, "reaction_send", context.Video, "FixtureExit=1`nReaction=1`n")
    Assert(crashed.State = "unknown" && !WorkerState.ProcessId && !WorkerState.SignalHandle, "in-flight crash is unknown and never replayed")
    Assert(crashed.HasOwnProp("Detail") && (crashed.Detail="補助プロセスが応答する前に終了しました。" || crashed.Detail="パイプが切断されました。"),
        "in-flight crash preserves the observed process or pipe failure")
    diagnosticJob := CreateReactionJob({Mode:"reaction_send",Window:123,Total:1})
    ActiveReactionJob := diagnosticJob
    ApplyReactionResult(diagnosticJob,crashed)
    Assert(LastReactionResult.Reason="unknown" && LastReactionResult.Detail==crashed.Detail && !ActiveReactionJob,
        "transport failure detail reaches the reaction result without changing outcome certainty")
    Assert(RequestBrowserOperation(123,"browser_context").State = "ok", "notification resources recover after in-flight crash")
    for failedMode in ["verify_input","reaction_send"] {
        beforeSequence := WorkerState.Sequence
        rejected := SendWorkerRequest(123,failedMode,context.Video,Format("{:33000}","x"))
        Assert(rejected.State=(failedMode="reaction_send" ? "unknown" : "unavailable") && rejected.HasOwnProp("Detail")
            && rejected.Detail="依頼サイズが不正です。","framing failure preserves its original cause: " failedMode)
        Assert(WorkerState.Sequence=beforeSequence+1 && !WorkerState.RequestActive && !WorkerState.ProcessHandle
            && !WorkerState.PipeHandle && !WorkerState.SignalHandle,"framing failure cleans up once without replay: " failedMode)
    }
    beforeSequence := WorkerState.Sequence
    mismatched := SendWorkerRequest(123,"browser_context",context.Video,"Seq=0`n")
    Assert(mismatched.State="unavailable" && mismatched.HasOwnProp("Detail") && mismatched.Detail="依頼と応答が一致しません。",
        "mismatched reply preserves its validation failure")
    Assert(WorkerState.Sequence=beforeSequence+1 && !WorkerState.RequestActive && !WorkerState.ProcessHandle
        && !WorkerState.PipeHandle && !WorkerState.SignalHandle,"mismatched reply cleans up without replay")
    Assert(RequestBrowserOperation(123,"browser_context").State="ok","transport recovers after rejected request frames")
    StopBrowserWorker()
    ActiveReactionJob := CreateReactionJob({Mode: "queued", Cancelled: false, Window: 0})
    SetReactionStatus("文言を変更した開始待ち", false)
    PaletteStatusControl.Text := "表示だけを書き換えた文言"
    QuickReaction()
    Assert(!ActiveReactionJob && ReactionExecutionStatus.Phase = "finished", "early exit finalizes regardless of displayed wording")
    Assert(LastReactionResult.Reason="wrong_window" && InStr(ReactionExecutionStatus.Message, "操作先が変わった"), "early exit preserves the specific target failure")
    ActiveReactionJob := CreateReactionJob({Mode: "queued", Cancelled: false, Window: 0})
    SetReactionStatus("開始待ち", false)
    CancelReaction()
    cancelledMessage := ReactionExecutionStatus.Message
    QuickReaction()
    Assert(ReactionExecutionStatus.Message = cancelledMessage, "queued cancellation result is retained")
    for released in [false, true] {
        replacementJob := CreateReactionJob({Mode:"queued", Cancelled:false, Window:0})
        RuntimePorts.ShortcutRelease := ReplaceShortcutJob.Bind(replacementJob,released)
        ActiveReactionJob := CreateReactionJob({Mode:"queued", Cancelled:false, Window:0})
        SetReactionStatus("新しい開始待ち", false)
        QuickReaction()
        Assert(ActiveReactionJob = replacementJob && ReactionExecutionStatus.Phase = "queued", "old shortcut cleanup preserves replacement job")
    }
    RuntimePorts.ShortcutRelease := 0
    CancelReaction()
    global FixtureStarts := []
    RuntimePorts.BrowserRequest := RecordReactionStart
    Assert(ReactionIntervalLabels()[1] = "待機なし", "待機なし is an explicit UI option")
    clockJob := {Interval:25, StartedAt:100}
    Assert(ReactionWaitRemaining(clockJob, 110) = 15, "processing time is included in interval")
    Assert(ReactionWaitRemaining(clockJob, 140) = 0, "overrun has no extra wait or catch-up debt")
    Assert(ReactionWaitRemaining({Interval:0, StartedAt:100}, 100) = 0, "待機なし never adds delay")
    for interval in [0, 25] {
        FixtureStarts := []
        job := CreateReactionJob({Mode:"reaction_send", Window:123, Video:"abcdefghijk", Choice:1, Total:4, Completed:0, Cancelled:false, Interval:interval})
        ActiveReactionJob := job
        RunReactionSendLoop(ActiveReactionJob)
        Assert(job.Completed = 4 && !ActiveReactionJob && FixtureStarts.Length = 4, "serial batch completes " interval " completed=" job.Completed " starts=" FixtureStarts.Length " detail=" LastReactionResult.Detail " result=" LastReactionResult.Message)
        if interval {
            Loop 3
                Assert(FixtureStarts[A_Index+1] - FixtureStarts[A_Index] >= interval - 0.1, "minimum start-to-start target respected")
        }
    }
    RuntimePorts.BrowserRequest := 0
    job := CreateReactionJob({Mode:"reaction_send", Window:123, Video:"abcdefghijk", Choice:1, Total:10000, Completed:0, Cancelled:false, Interval:0})
    ActiveReactionJob := job
    SetTimer(CancelReaction, -30)
    RunReactionSendLoop(ActiveReactionJob)
    Assert(job.Cancelled && !ActiveReactionJob && job.Completed < 10000, "待機なし pumps Esc cancellation")
    job := CreateReactionJob({Interval:1000, StartedAt:AppClockMs(), Cancelled:false})
    ActiveReactionJob := job
    SetTimer(CancelReaction, -30)
    Assert(!WaitReactionInterval(job) && !ActiveReactionJob, "long interval wait is cancellable")
    owner := Gui(, "ChatPalette test owner"), other := Gui(, "ChatPalette test other")
    target := owner.AddButton("w100", "Fixture")
    owner.Show("NoActivate"), other.Show("NoActivate w120 h80")
    for enabled in [1, 0] {
        target.Enabled := enabled
        reply := SendWorkerRequest(123, "fixture_native", "", "Element=" target.Hwnd "`nParent=" owner.Hwnd "`nOther=" other.Hwnd "`nEnabled=" enabled "`n")
        Assert(reply.State = "ok", "real UIA cache refresh and wrong-window rejection " enabled)
    }
    owner.Destroy(), other.Destroy()
    global TransportClock := 4294967280
    RuntimePorts.Clock := AdvancingTransportClock
    try {
        timedOut := NativeRequestBrowserOperation(123,"verify_input",context.Video,"FixtureDelay=3500`n")
        Assert(timedOut.State="unavailable" && !WorkerState.ProcessHandle && !WorkerState.PipeHandle && !WorkerState.SignalHandle,"elapsed timeout across 32-bit uptime releases all transport resources")
        Assert(LastBrowserOperation.Duration>=2500 && LastBrowserOperation.Duration<10000 && IsInteger(LastBrowserOperation.Duration),"request duration remains positive integer milliseconds across uptime boundary")
    } finally RuntimePorts.Clock := 0
    Assert(RequestBrowserOperation(123,"browser_context").State="ok","transport recovers after the simulated long-uptime timeout")
    StopBrowserWorker()

'@ -Helpers @'
; Model Esc and a replacement shortcut while the original KeyWait is suspended.
ReplaceShortcutJob(replacement, released, keys) {
    global ActiveReactionJob := replacement
    return released
}
RecordReactionStart(hwnd,mode,video,extra) {
    if mode = "reaction_send" && ActiveReactionJob
        FixtureStarts.Push(ActiveReactionJob.StartedAt)
    return NativeRequestBrowserOperation(hwnd,mode,video,extra)
}
AdvancingTransportClock() {
    global TransportClock
    now := TransportClock
    TransportClock += 1000
    return now
}
ProbeWorkerExecutable(executable) {
    global FailedStartHandles
    if WorkerLaunchFailure {
        FailedStartHandles := [WorkerState.PipeHandle,WorkerState.SignalHandle]
        return A_ScriptDir "\missing-worker.exe"
    }
    return executable
}
CancelDuringFixtureWait() {
    global StoppedWhileWaiting := IsBrowserOperationBusy
    CancelReaction()
}
'@

# Cleanup failures must remain visible and preserve ownership for a later retry.
$cleanupRuntime = New-TestRuntime
$stopObservation = '            if state != 0'
Edit-TestSource $cleanupRuntime 'src/browser/worker_client.ahk' $stopObservation ('            state := ObserveWorkerStop(state)' + "`r`n" + $stopObservation)
Invoke-AppFixture -Runtime $cleanupRuntime -Body @'
    global StopFaultArmed := false, StopChecks := 0, StopOwned := false, StopNestedState := "", StopClock := 0
    BuildManagement()
    for entry in ["transport","browser","startup","registration","capture-sync"] {
        for scenario in (entry="transport" || entry="browser" ? ["timeout","crash","oversize","restart"] : ["restart"]) {
            Assert(SendWorkerRequest(123,"browser_context").State="ok","prepare live worker for " entry "/" scenario)
            handle := WorkerState.ProcessHandle
            StopChecks := 0, StopOwned := false, StopNestedState := "", StopClock := 0
            if scenario="restart" {
                DllCall("TerminateProcess","Ptr",handle,"UInt",1)
                Assert(DllCall("WaitForSingleObject","Ptr",handle,"UInt",2000,"UInt")=0,entry ": previous worker is stopped before restart")
            }
            StopFaultArmed := true
            if scenario="timeout"
                RuntimePorts.Clock := StopDeadlineClock
            extra := scenario="timeout" ? "FixtureDelay=3500`n" : (scenario="crash" ? "FixtureExit=1`n" : (scenario="oversize" ? Format("{:33000}","x") : ""))
            failed := false
            try {
                if entry="startup"
                    EnsureWorkerRunning()
                else if entry="registration" {
                    reply := NativeRequestBrowserOperation(123,"reaction_check")
                    failed := reply.State="sync_failed" && InStr(reply.Detail,"補助プロセスの終了を確認できませんでした") > 0
                } else if entry="capture-sync" {
                    reply := SynchronizeCapturedReactionRegistration(123,{State:"saved"})
                    failed := reply.State="sync_failed" && InStr(reply.Detail,"補助プロセスの終了を確認できませんでした") > 0
                } else {
                    reply := entry="transport" ? NativeSendWorkerRequest(123,"verify_input","abcdefghijk",extra)
                        : NativeRequestBrowserOperation(123,"verify_input","abcdefghijk",extra)
                    failed := reply.State="unavailable" && reply.HasOwnProp("Detail")
                        && InStr(reply.Detail,"補助プロセスの終了を確認できませんでした") > 0
                }
            } catch as failure {
                failed := InStr(failure.Message,"補助プロセスの終了を確認できませんでした") > 0
            } finally {
                StopFaultArmed := false
                RuntimePorts.Clock := 0
            }
            label := entry "/" scenario
            Assert(failed && StopChecks=1,label ": unconfirmed cleanup is surfaced without an implicit retry")
            Assert(entry="transport" || entry="browser" ? (StopOwned && StopNestedState="unavailable") : !StopOwned,label ": cleanup preserves its caller request gate and rejects nested requests")
            Assert(WorkerState.ProcessHandle=handle && DllCall("GetHandleInformation","Ptr",handle,"UInt*",&flags:=0),label ": unconfirmed process handle remains owned")
            Assert(!WorkerState.PipeHandle && !WorkerState.SignalHandle,label ": pipe and signal are already released")
            Assert(!WorkerState.RequestActive && !IsBrowserOperationBusy,label ": cleanup failure releases both request gates")
            Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),label ": cleanup failure restores parent windows")
            StopBrowserWorker()
            Assert(!WorkerState.ProcessHandle && !WorkerState.ProcessId,label ": explicit cleanup retry releases retained ownership")
            Assert(SendWorkerRequest(123,"browser_context").State="ok",label ": the next request succeeds with a fresh worker")
            StopBrowserWorker()
        }
    }
'@ -Helpers @'
ObserveWorkerStop(state) {
    global StopChecks, StopOwned, StopNestedState
    if StopFaultArmed {
        StopChecks++
        StopOwned := WorkerState.RequestActive
        if StopOwned
            StopNestedState := NativeSendWorkerRequest(123,"browser_context").State
        ; The real process is stopped, but its first wait result cannot confirm that.
        if StopChecks=1
            return 0xFFFFFFFF
    }
    return state
}
StopDeadlineClock() {
    global StopClock
    now := StopClock
    StopClock += 1000
    return now
}
'@
