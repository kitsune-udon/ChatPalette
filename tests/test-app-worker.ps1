# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
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
    result := RequestBrowserOperation(123, "reaction_check", context.Video)
    Assert(result.State = "ready", "non-sending check through pipe")
    result := RequestBrowserOperation(123, "reaction_send", "ABCDEFGHIJK", "Reaction=1`n")
    Assert(result.State = "changed", "changed video rejected through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "mock operation through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "no implicit cooldown between operations")
    firstPID := WorkerState.ProcessId
    sequenceBeforeCrash := WorkerState.Sequence
    ProcessClose(firstPID)
    ProcessWaitClose(firstPID, 2)
    recovered := RequestBrowserOperation(123, "browser_context")
    Assert(recovered.State = "ok" && WorkerState.ProcessId != firstPID && WorkerState.Sequence = sequenceBeforeCrash + 1, "crashed worker restarts on next request without replay")
    firstPID := WorkerState.ProcessId
    StopBrowserWorker()
    Assert(!ProcessExist(firstPID), "worker shuts down")
    context := RequestBrowserOperation(123, "browser_context")
    global StoppedWhileWaiting := false
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send", Cancelled:false, Completed:0, Total:1})
    waitingJob := ActiveReactionJob
    SetTimer(CancelDuringFixtureWait, -30)
    delayed := RequestBrowserOperation(123, "verify", context.Video, "FixtureDelay=250`n")
    Assert(delayed.State = "ok" && StoppedWhileWaiting && waitingJob.Cancelled, "notification wait pumps cancellation before response")
    CancelReaction()
    timedOut := SendWorkerRequest(123, "verify", context.Video, "FixtureDelay=3500`n")
    Assert(timedOut.State = "unavailable" && !WorkerState.ProcessId && !WorkerState.PipeHandle && !WorkerState.SignalHandle, "timeout releases pipe and notification resources")
    context := RequestBrowserOperation(123, "browser_context")
    crashed := SendWorkerRequest(123, "reaction_send", context.Video, "FixtureExit=1`nReaction=1`n")
    Assert(crashed.State = "unknown" && !WorkerState.ProcessId && !WorkerState.SignalHandle, "in-flight crash is unknown and never replayed")
    Assert(RequestBrowserOperation(123,"browser_context").State = "ok", "notification resources recover after in-flight crash")
    StopBrowserWorker()
    ActiveReactionJob := CreateReactionJob({Mode: "queued", Cancelled: false, Window: 0})
    SetReactionStatus("文言を変更した開始待ち", false, "queued")
    PaletteStatusControl.Text := "表示だけを書き換えた文言"
    QuickReaction()
    Assert(!ActiveReactionJob && ReactionExecutionStatus.Final && ReactionExecutionStatus.Phase = "finished", "early exit finalizes regardless of displayed wording")
    Assert(InStr(ReactionExecutionStatus.Message, "開始できません"), "early exit records controller outcome")
    ActiveReactionJob := CreateReactionJob({Mode: "queued", Cancelled: false, Window: 0})
    SetReactionStatus("開始待ち", false, "queued")
    CancelReaction()
    cancelledMessage := ReactionExecutionStatus.Message
    QuickReaction()
    Assert(ReactionExecutionStatus.Message = cancelledMessage, "queued cancellation result is retained")
    global ShortcutReleaseReplacement, ShortcutReleaseResult
    for released in [false, true] {
        replacementJob := CreateReactionJob({Mode:"queued", Cancelled:false, Window:0})
        ShortcutReleaseReplacement := replacementJob
        ShortcutReleaseResult := released
        ActiveReactionJob := CreateReactionJob({Mode:"queued", Cancelled:false, Window:0})
        SetReactionStatus("新しい開始待ち", false, "queued")
        QuickReaction()
        Assert(ActiveReactionJob = replacementJob && ReactionExecutionStatus.Phase = "queued", "old shortcut cleanup preserves replacement job")
    }
    ShortcutReleaseReplacement := 0
    CancelReaction()
    global FixtureStarts := []
    Assert(ReactionIntervalLabels()[1] = "待機なし", "待機なし is an explicit UI option")
    clockJob := {Interval:25, StartedAt:100}
    Assert(ReactionWaitRemaining(clockJob, 110) = 15, "processing time is included in interval")
    Assert(ReactionWaitRemaining(clockJob, 140) = 0, "overrun has no extra wait or catch-up debt")
    Assert(ReactionWaitRemaining({Interval:0, StartedAt:100}, 100) = 0, "待機なし never adds delay")
    for interval in [0, 25] {
        FixtureStarts := []
        job := CreateReactionJob({Mode:"reaction_send", Window:123, Video:"abcdefghijk", Choice:1, Total:4, Completed:0, Cancelled:false, Interval:interval})
        ActiveReactionJob := job
        ReactionSendNext()
        Assert(job.Completed = 4 && !ActiveReactionJob && FixtureStarts.Length = 4, "serial batch completes " interval " completed=" job.Completed " starts=" FixtureStarts.Length " detail=" LastReactionResult.Detail " result=" LastReactionResult.Message)
        if interval {
            Loop 3
                Assert(FixtureStarts[A_Index+1] - FixtureStarts[A_Index] >= interval - 0.1, "minimum start-to-start target respected")
        }
    }
    job := CreateReactionJob({Mode:"reaction_send", Window:123, Video:"abcdefghijk", Choice:1, Total:10000, Completed:0, Cancelled:false, Interval:0})
    ActiveReactionJob := job
    SetTimer(CancelReaction, -30)
    ReactionSendNext()
    Assert(job.Cancelled && !ActiveReactionJob && job.Completed < 10000, "待機なし pumps Esc cancellation")
    job := CreateReactionJob({Interval:1000, StartedAt:ReactionClockMs(), Cancelled:false})
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
    StopBrowserWorker()

'@ -Helpers @'
CancelDuringFixtureWait() {
    global StoppedWhileWaiting := IsBrowserOperationBusy
    CancelReaction()
}
'@
