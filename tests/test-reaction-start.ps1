# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# A suspended start must never schedule or report on behalf of its successor.
$startRuntime=New-TestRuntime
$startTests=@'
BuildManagement()
global StartChecks := 0, StartCase := 0, StartPoint := "", StartProbeArmed := false, StartProbeReached := false
global StartOriginal := 0, StartReplacement := 0, StartPreservedResult := 0, StartRequests := 0
browser := Gui()
browser.Show("w200 h100")
TargetBrowserHwnd := browser.Hwnd
global StartContextReply := 0, StartContextReplace := false
for context in [{State:"unavailable",Detail:"context lookup failed"},
    {State:"changed",Detail:"context changed during lookup"},{State:"unavailable"}] {
    StartContextReply := context, StartRequests := 0
    CheckStart(!ScheduleReaction("reaction_send",3) && !ActiveReactionJob && StartRequests=1,
        "failed context stops before preparing or sending a reaction")
    CheckStart(LastReactionResult.Reason==context.State
        && LastReactionResult.Detail==(context.HasOwnProp("Detail") ? context.Detail : ""),
        "scheduled start preserves this context response, including absent detail")
}
for mode in ["reaction_capture","reaction_check","reaction_send"] {
    for replaced in [false,true] {
        StartContextReplace := replaced, StartContextReply := Error("context request exception"), StartRequests := 0
        StartReplacement := 0, StartPreservedResult := LastReactionResult
        escaped := false, scheduled := false
        try scheduled := ScheduleReaction(mode,30)
        catch
            escaped := true
        label := mode "/" (replaced ? "replacement" : "failure")
        CheckStart(!escaped && !scheduled && StartRequests=1,"context exception is handled without scheduling or retry: " label)
        if replaced {
            CheckStart(ActiveReactionJob=StartReplacement && StartReplacement.Phase="queued"
                && LastReactionResult=StartPreservedResult && ReactionExecutionStatus.Message=="successor pending",
                "context exception cannot publish over a successor: " label)
            FinishReactionJob(StartReplacement)
        } else {
            CheckStart(!ActiveReactionJob && LastReactionResult.Reason="unavailable" && LastReactionResult.Detail="context request exception",
                "context exception is preserved as a failure before starting: " label)
            CheckStart(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"context failure leaves controls usable: " label)
        }
    }
    StartContextReply := 0, StartContextReplace := false, StartRequests := 0
    Critical("On")
    try {
        CheckStart(ScheduleReaction(mode,30) && ActiveReactionJob.Mode=mode && StartRequests=1,"new scheduled request can start after context failure: " mode)
        CancelReaction()
        CheckStart(!ActiveReactionJob,"successful retry can be cancelled before any browser action: " mode)
    } finally Critical("Off")
}
StartContextReply := 0
ShowReactionProgress()
ReactionOverlay.Window.DefineProp("Show",{Call:StartOverlayShow})
try {
    for mode in ["queued","reaction_capture","reaction_send"] {
        for point in ["status","overlay"] {
            for scenario in ["failure","replacement_failure","replacement","cancelled"] {
                StopReactionTimers()
                StartCase := scenario, StartPoint := point, StartProbeArmed := true, StartProbeReached := false
                StartOriginal := 0, StartReplacement := 0, StartRequests := 0
                StartPreservedResult := LastReactionResult
                Critical("On")
                try {
                    if mode="queued"
                        QueueQuickReaction()
                    else
                        CheckStart(!ScheduleReaction(mode,3),"interrupted scheduled start reports failure: " mode "/" point "/" scenario)
                    StartProbeArmed := false
                    label := mode "/" point "/" scenario
                    CheckStart(StartProbeReached,"start reaches progress rendering: " label)
                    if scenario="failure" {
                        CheckStart(!ActiveReactionJob && LastReactionResult.Reason="unavailable" && LastReactionResult.Detail="start display failure","failed start releases owner and preserves cause: " label)
                        CheckStart(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"failed start restores operation controls: " label)
                    } else {
                        if scenario="cancelled" {
                            CheckStart(!ActiveReactionJob && LastReactionResult.Reason="cancelled","cancelled start keeps its cancellation result: " label)
                            StartPreservedResult := LastReactionResult
                            ReplaceStartingJob()
                        }
                        CheckStart(ActiveReactionJob=StartReplacement && StartReplacement.Phase="queued" && StartReplacement.Remaining=7,"successor keeps ownership and state: " label)
                        CheckStart(LastReactionResult=StartPreservedResult && ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message=="successor pending","old start cannot replace the successor's result: " label)
                        CheckStart(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"successor retains operation controls: " label)
                    }
                } finally Critical("Off")
                ; Both the immediate shortcut and the one-second countdown must stay disarmed.
                Sleep(1150)
                CheckStart(StartRequests=0,"old start leaves no timer that can operate on a new job: " label)
                if StartReplacement
                    CheckStart(ActiveReactionJob=StartReplacement && StartReplacement.Remaining=7,"successor is unchanged after the timer deadline: " label)
                if ActiveReactionJob
                    FinishReactionJob(ActiveReactionJob)
                CheckStart(StartOriginal.Phase="finished","original start is terminal: " label)
            }
        }
    }
} finally {
    ReactionOverlay.Window.DeleteProp("Show")
    StartProbeArmed := false
    StopReactionTimers()
    browser.Destroy()
}
FileAppend("PASS: " StartChecks " reaction start ownership checks; no real browser operations`n","*")
ExitApp()
CheckStart(value,label) {
    global StartChecks
    if !value
        throw Error(label)
    StartChecks++
}
ReplaceStartingJob() {
    global ActiveReactionJob, StartReplacement
    StartReplacement := CreateReactionJob({Mode:"queued",Window:TargetBrowserHwnd,Remaining:7})
    ActiveReactionJob := StartReplacement
    SetReactionStatus("successor pending")
}
ProbeReactionStart() {
    global StartProbeArmed, StartProbeReached, StartOriginal
    if StartProbeArmed && ActiveReactionJob {
        StartProbeArmed := false, StartProbeReached := true, StartOriginal := ActiveReactionJob
        if StartCase="cancelled"
            CancelReaction()
        else if StartCase!="failure"
            ReplaceStartingJob()
        if StartCase="failure" || StartCase="replacement_failure"
            throw Error("start display failure")
    }
}
StartClock() {
    if StartPoint="status"
        ProbeReactionStart()
    return NativeAppClockMs()
}
StartOverlayShow(view,options := "") {
    if StartPoint="overlay"
        ProbeReactionStart()
    return Gui.Prototype.Show.Call(view,options)
}
StartRequest(hwnd,mode,video,extra) {
    global StartRequests
    if !StartProbeArmed
        StartRequests++
    if mode="browser_context" && StartContextReply {
        if StartContextReplace
            ReplaceStartingJob()
        if StartContextReply is Error
            throw StartContextReply
        return StartContextReply
    }
    return {State:mode="browser_context" ? "ok" : "unknown",Video:"abcdefghijk"}
}
'@
# Each of the 24 scenarios observes the real one-second timer deadline.
Invoke-AppTest -Runtime $startRuntime -Body $startTests -TimeoutMs 60000 -Setup @'
RuntimePorts.Clock := StartClock
RuntimePorts.BrowserIdentity := (hwnd) => !!hwnd
RuntimePorts.Foreground := (hwnd) => true
RuntimePorts.ShortcutRelease := (keys) => true
RuntimePorts.BrowserRequest := StartRequest
RuntimePorts.TimingPrecision := (enabled) => false
'@
