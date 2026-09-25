# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
OnExit(StopBrowserWorker)
global TimingChecks := 0, TimingMode := "", PrecisionEvents := "", TimingRequests := 0
AssertTiming(ReactionIntervalLabels()[5]="150 ms" && ReactionIntervalLabels()[7]="250 ms", "new choices and labels")
for mode in ["normal","foreground-error","foreground-false","error","cancel","unavailable","nowait","sync_failed","unknown"] {
    TimingMode := mode, PrecisionEvents := "", TimingRequests := 0
    job := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:mode="nowait" ? 0 : 100})
    ActiveReactionJob := job
    RunReactionSendLoop(ActiveReactionJob)
    expected := (mode="nowait" || mode="foreground-error" || mode="foreground-false") ? "" : (mode="unavailable" ? "B" : "BE")
    AssertTiming(PrecisionEvents=expected,"balanced precision: " mode)
    AssertTiming(!ActiveReactionJob && OperationAllowed("reaction"),"job finished and next operation allowed: " mode)
    expectedCount := (mode="error" || mode="sync_failed" || mode="unknown" || mode="foreground-error" || mode="foreground-false") ? 0 : (mode="cancel" ? 1 : 2)
    AssertTiming(job.Completed=expectedCount,"exact completed count on exit: " mode)
    if mode="foreground-error" || mode="foreground-false" {
        AssertTiming(TimingRequests=0,"failed preflight sends no request: " mode)
        AssertTiming(LastReactionResult.Reason=(mode="foreground-error" ? "unknown" : "wrong_window")
            && LastReactionResult.Detail=(mode="foreground-error" ? "fixture foreground failure" : ""),"failed preflight preserves reason and detail: " mode)
    }
    if mode="sync_failed" || mode="unknown"
        AssertTiming(LastReactionResult.Reason=mode,"failure reason preserved: " mode)
}
TimingMode := "random"
SaveReactionDefaults(CreateReactionOptions(RandomReactionKind,10,200))
restored := LoadSettings(SettingsDatabasePath)
AssertTiming(restored.DefaultReactionKind=RandomReactionKind && restored.DefaultReactionIntervalMs=200,"random persistence")
global RandomChoices := []
ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:RandomReactionKind,Completed:0,Total:10,Cancelled:false,Interval:0})
randomJob := ActiveReactionJob
RunReactionSendLoop(ActiveReactionJob)
AssertTiming(randomJob.Completed=10 && randomJob.Choice=RandomReactionKind && RandomChoices.Length=10,"random resolves per operation")
for choice in RandomChoices
    AssertTiming(choice>=1 && choice<=5,"worker receives concrete kind")
Loop 5
    AssertTiming(ResolveReactionKind(A_Index)=A_Index,"fixed kind unchanged")
measured := CreateReactionJob({StartedAt:1000,Completed:0,Total:3,Cancelled:false})
ActiveReactionJob := measured
ApplyReactionResult(measured,{State:"operated"})
AssertTiming(!InStr(ReactionExecutionStatus.Message,"平均開始間隔"),"single operation does not display an average interval")
measured.StartedAt := 1200
ApplyReactionResult(measured,{State:"operated"})
measured.StartedAt := 1400
ApplyReactionResult(measured,{State:"operated"})
AssertTiming(InStr(LastReactionResult.Message,"平均開始間隔 200 ms"),"start timestamps determine mean independently of response time")
TimingMode := "normal"
for interval in [150,250] {
    PrecisionEvents := ""
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:interval})
    job := ActiveReactionJob
    RunReactionSendLoop(ActiveReactionJob)
    AssertTiming(job.Completed=2 && PrecisionEvents="BE","new interval runs: " interval)
}
TimingMode := "normal", PrecisionEvents := "", TimingRequests := 0
stale := CreateReactionJob({Cancelled:true,Phase:"finished",Window:123,Total:2,Interval:100})
replacement := CreateReactionJob({Window:123,Video:"abcdefghijk",Total:2,Interval:100})
ActiveReactionJob := replacement
RunReactionSendLoop(stale)
AssertTiming(ActiveReactionJob=replacement && replacement.Completed=0 && replacement.Phase="waiting","stale send loop cannot run or cancel a replacement job")
AssertTiming(TimingRequests=0 && PrecisionEvents="","stale send loop acquires no timing resources and sends no request")
RunReactionSendLoop(replacement)
AssertTiming(!ActiveReactionJob && replacement.Completed=2 && TimingRequests=2 && PrecisionEvents="BE","explicit current job runs serially and releases precision")
RunReactionSendLoop(stale)
AssertTiming(!ActiveReactionJob && TimingRequests=2 && PrecisionEvents="BE","released job cannot restart the send loop")
cancelled := CreateReactionJob({Cancelled:true,Phase:"stopping",Window:123,Total:2,Interval:100})
ActiveReactionJob := cancelled
RunReactionSendLoop(cancelled)
AssertTiming(ActiveReactionJob=cancelled && cancelled.Phase="stopping" && TimingRequests=2 && PrecisionEvents="BE","cancelled job cannot reenter sending while its cleanup is pending")
FinishReactionJob(cancelled)
global DisplayClock := 4294967290.0
RuntimePorts.Clock := (*) => DisplayClock
SetReactionStatus("clock first")
AssertTiming(PaletteStatusControl.Text="clock first","progress initially renders before 32-bit uptime boundary")
DisplayClock += 100.5
SetReactionStatus("clock after boundary")
AssertTiming(PaletteStatusControl.Text="clock after boundary","progress renders after throttle interval across uptime boundary")
DisplayClock += 0.25
SetReactionStatus("clock pending")
AssertTiming(PaletteStatusControl.Text="clock after boundary","fractional remaining time schedules throttled rendering without a type error")
DisplayClock += 100
RenderReactionStatus()
AssertTiming(PaletteStatusControl.Text="clock pending","throttled progress publishes its latest message")
SetReactionStatus("clock complete",true)
AssertTiming(PaletteStatusControl.Text="clock complete","completion bypasses the progress throttle")
; Publish a new result while the previous snapshot is being rendered.
global DisplayReentry := true, DisplayFailure := false, DisplayClockReads := 0
RuntimePorts.Clock := ReentrantDisplayClock
SetReactionStatus("superseded progress")
deadline := A_TickCount+1000
while PaletteStatusControl.Text!="reentrant complete" && A_TickCount<deadline
    Sleep(10)
AssertTiming(PaletteStatusControl.Text="reentrant complete" && !PaletteStop.Enabled
    && LastReactionResult.Message="reentrant complete","reentrant completion replaces the stale progress and releases stop")
; An explicit refresh fulfills the reservation before its timer is delivered.
Critical("On")
try {
    DisplayReentry := true
    SetReactionStatus("another superseded progress")
    RenderReactionStatus()
    reads := DisplayClockReads
} finally Critical("Off")
Sleep(40)
AssertTiming(DisplayClockReads=reads,"an explicit completed render consumes its pending reservation")
DisplayFailure := true, failed := false
try SetReactionStatus("failed render",true)
catch
    failed := true
SetReactionStatus("recovered render",true)
AssertTiming(failed && PaletteStatusControl.Text="recovered render","render failure releases ownership for the next result")
RuntimePorts.Clock := 0
FileAppend("PASS: " TimingChecks " timing lifecycle checks`n", "*")
TimingMode := "exit", PrecisionEvents := ""
ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:100})
RunReactionSendLoop(ActiveReactionJob)
throw Error("Exit did not terminate")
AssertTiming(value,label) {
    global TimingChecks
    TimingChecks++
    if !value
        throw Error(label)
}
ReentrantDisplayClock() {
    global DisplayReentry, DisplayFailure, DisplayClockReads
    DisplayClockReads++
    if DisplayFailure {
        DisplayFailure := false
        throw Error("fixture rendering clock failure")
    }
    if DisplayReentry {
        DisplayReentry := false
        SetReactionStatus("reentrant complete",true)
    }
    return DisplayClock
}
FixtureTimingForeground(hwnd) {
    if TimingMode="foreground-error"
        throw Error("fixture foreground failure")
    return TimingMode!="foreground-false" && hwnd=123
}
FixtureTimingPrecision(enabled) {
    global PrecisionEvents
    PrecisionEvents .= enabled ? "B" : "E"
    if TimingMode="exit" && !enabled
        FileAppend(PrecisionEvents,A_ScriptDir "\exit-release.txt")
    return enabled && TimingMode!="unavailable"
}
FixtureBrowserOperation(hwnd,mode:="resolve",video:="",extra:="") {
    global TimingRequests
    TimingRequests++
    if TimingMode="random" {
        if !RegExMatch(extra,"^Reaction=([1-5])\n$",&match)
            throw Error("Invalid random worker payload")
        RandomChoices.Push(Integer(match[1]))
    }
    if TimingMode="sync_failed" || TimingMode="unknown"
        return {State:TimingMode}
    if TimingMode="error"
        throw Error("injected failure")
    if TimingMode="exit"
        ExitApp()
    if TimingMode="cancel"
        SetTimer(CancelReaction,-20)
    return {State:"operated"}
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.Foreground := FixtureTimingForeground
RuntimePorts.TimingPrecision := FixtureTimingPrecision
RuntimePorts.BrowserRequest := FixtureBrowserOperation
'@
if ([IO.File]::ReadAllText((Join-Path $release 'exit-release.txt')) -ne 'BE') { throw 'Exit precision cleanup failed' }
Write-Output 'PASS: precision released on application exit'
