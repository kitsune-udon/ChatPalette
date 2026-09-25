# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$countdownRuntime=New-TestRuntime
$countdownTests=@'
BuildManagement()
global CountdownCase := 0, CountdownReplacement := 0, CountdownRequests := 0
for scenario in [
    {Point:"foreground",Replace:false,Throws:true,Result:false,Mode:"reaction_check",Remaining:0,Reason:"unavailable"},
    {Point:"foreground",Replace:false,Throws:false,Result:false,Mode:"reaction_check",Remaining:0,Reason:"wrong_window"},
    {Point:"foreground",Replace:true,Throws:false,Result:false,Mode:"reaction_capture",Remaining:3,Reason:""},
    {Point:"foreground",Replace:true,Throws:false,Result:true,Mode:"reaction_capture",Remaining:3,Reason:""},
    {Point:"foreground",Replace:true,Throws:true,Result:false,Mode:"reaction_capture",Remaining:3,Reason:""},
    {Point:"request",Replace:true,Throws:false,Result:true,Mode:"reaction_check",Remaining:0,Reason:""},
    {Point:"request",Replace:true,Throws:true,Result:true,Mode:"reaction_check",Remaining:0,Reason:""},
    {Point:"request",Replace:true,Throws:false,Result:true,Mode:"reaction_capture",Remaining:0,Reason:""},
    {Point:"request",Replace:true,Throws:true,Result:true,Mode:"reaction_capture",Remaining:0,Reason:""},
    {Point:"none",Replace:false,Throws:false,Result:true,Mode:"reaction_check",Remaining:3,Reason:""},
    {Point:"none",Replace:false,Throws:false,Result:true,Mode:"reaction_check",Remaining:0,Reason:"ready"},
    {Point:"cancel",Replace:false,Throws:false,Result:true,Mode:"reaction_check",Remaining:0,Reason:"cancelled"},
    {Point:"cancel",Replace:false,Throws:false,Result:true,Mode:"reaction_capture",Remaining:0,Reason:"cancelled"},
    {Point:"none",Replace:false,Throws:false,Result:true,Mode:"reaction_capture",Remaining:0,Reason:""}] {
    CountdownCase := scenario, CountdownReplacement := 0, CountdownRequests := 0
    job := CreateReactionJob({Mode:scenario.Mode,Window:123,Video:"abcdefghijk",Remaining:scenario.Remaining})
    ActiveReactionJob := job
    SetReactionStatus("countdown pending")
    previousResult := LastReactionResult
    ; Keep timers from racing the explicit tick; their continued activity is tested below.
    Critical("On")
    try {
        ReactionCountdown()
        label := scenario.Point "/" scenario.Replace "/" scenario.Throws "/" scenario.Result "/" scenario.Mode "/" scenario.Remaining
        expectedRequests := scenario.Point="foreground" || scenario.Remaining>0 ? 0 : 1
        Assert(CountdownRequests=expectedRequests,"only the original due job may query the browser: " label)
        if scenario.Replace {
            Assert(ActiveReactionJob=CountdownReplacement && CountdownReplacement.Phase="queued" && !CountdownReplacement.Cancelled && CountdownReplacement.Remaining=7,"replacement ownership and countdown are unchanged: " label)
            Assert(job.Phase="finished" && ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message=="replacement pending" && LastReactionResult=previousResult,"stale result cannot overwrite current progress: " label)
            Assert(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"replacement retains control locks: " label)
            FinishReactionJob(CountdownReplacement)
        } else if scenario.Reason!="" {
            Assert(!ActiveReactionJob && job.Phase="finished","terminal tick releases its owner: " label)
            Assert(LastReactionResult.Reason==scenario.Reason && LastReactionResult.Mode==scenario.Mode && LastReactionResult.Detail==(scenario.Throws ? "countdown failure" : ""),"terminal result preserves its own reason and details: " label)
            Assert(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"terminal tick restores controls: " label)
        } else {
            Assert(ActiveReactionJob=job && job.Phase="waiting" && job.Remaining=scenario.Remaining-1,"ordinary countdown and capture retry retain their owner: " label)
            Assert(ReactionExecutionStatus.Phase!="finished" && LastReactionResult=previousResult,"waiting does not publish a terminal result: " label)
            Assert(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"waiting retains control locks: " label)
            CancelReaction()
        }
    } finally Critical("Off")
}
; A late unsupported reply must not install a retry timer on a replacement job.
CountdownCase := {Point:"request",Replace:true,Throws:false,Result:true,Mode:"reaction_capture"}
CountdownRequests := 0
ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:123})
ReactionCountdown()
Sleep(1150)
Assert(CountdownRequests=1 && ActiveReactionJob=CountdownReplacement && CountdownReplacement.Remaining=7,"superseded capture never schedules another tick")
FinishReactionJob(CountdownReplacement)
; Re-entry during retry status rendering must not arm the shared timer for a successor.
global RetryScenario := "", RetryArmed := false
for retryCase in ["replacement","cancelled"] {
    StopReactionTimers()
    CountdownCase := {Point:"none",Replace:false,Throws:false,Result:true,Mode:"reaction_capture"}
    CountdownRequests := 0, CountdownReplacement := 0
    job := CreateReactionJob({Mode:"reaction_capture",Window:123})
    ActiveReactionJob := job
    SetReactionStatus("capture before retry")
    previousResult := LastReactionResult
    RetryScenario := retryCase, RetryArmed := true
    beforeCritical := A_IsCritical
    Critical("On")
    try {
        ReactionCountdown()
        Assert(!RetryArmed,"retry reaches its status-rendering boundary: " retryCase)
        if retryCase="cancelled" {
            Assert(!ActiveReactionJob && LastReactionResult.Reason="cancelled","retry rendering preserves cancellation: " retryCase)
            previousResult := LastReactionResult
            ReplaceCountdownRetry()
        }
        Assert(ActiveReactionJob=CountdownReplacement && LastReactionResult=previousResult
            && ReactionExecutionStatus.Message=="retry successor pending","retry preserves successor progress and the last result: " retryCase)
    } finally Critical(beforeCritical)
    try {
        Sleep(1150)
        Assert(CountdownRequests=1 && ActiveReactionJob=CountdownReplacement && CountdownReplacement.Remaining=7,"superseded retry leaves no timer that can advance its successor: " retryCase)
        Assert(job.Phase="finished" && !PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"superseded retry is terminal while successor keeps its controls: " retryCase)
    } finally {
        RetryArmed := false
        if ActiveReactionJob
            FinishReactionJob(ActiveReactionJob)
    }
}
FileAppend("PASS: " Checks " countdown ownership checks; no real browser operations`n","*")
ExitApp()
CountdownBoundary(point) {
    global ActiveReactionJob, CountdownReplacement, IsBrowserOperationBusy
    if CountdownCase.Point="cancel" && point="request" {
        previousBusy := IsBrowserOperationBusy
        IsBrowserOperationBusy := true
        try CancelReaction()
        finally IsBrowserOperationBusy := previousBusy
        return
    }
    if CountdownCase.Point!=point
        return
    if CountdownCase.Replace {
        CountdownReplacement := CreateReactionJob({Mode:"queued",Window:123,Remaining:7})
        ActiveReactionJob := CountdownReplacement
        SetReactionStatus("replacement pending")
    }
    if CountdownCase.Throws
        throw Error("countdown failure")
}
ReplaceCountdownRetry() {
    global ActiveReactionJob, CountdownReplacement
    CountdownReplacement := CreateReactionJob({Mode:"queued",Window:123,Remaining:7})
    ActiveReactionJob := CountdownReplacement
    SetReactionStatus("retry successor pending")
}
CountdownClock() {
    global RetryArmed
    if IsSet(RetryArmed) && RetryArmed && InStr(ReactionExecutionStatus.Message,"登録待機中：")=1 {
        RetryArmed := false
        if RetryScenario="cancelled"
            CancelReaction()
        else
            ReplaceCountdownRetry()
    }
    return NativeAppClockMs()
}
CountdownForeground(hwnd) {
    CountdownBoundary("foreground")
    return CountdownCase.Result
}
CountdownRequest(hwnd,mode,video,extra) {
    global CountdownRequests
    CountdownRequests++
    CountdownBoundary("request")
    return {State:mode="reaction_capture" ? "unsupported" : "ready",Detail:""}
}
'@
Invoke-AppTest -Runtime $countdownRuntime -Body $countdownTests -Setup @'
RuntimePorts.Clock := CountdownClock
RuntimePorts.Foreground := CountdownForeground
RuntimePorts.BrowserRequest := CountdownRequest
'@
