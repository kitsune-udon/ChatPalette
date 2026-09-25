# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
# Inject only into the isolated runtime: simulate failure just before scheduling a retry.
$controller=Join-Path $release 'src\reactions\reaction_controller.ahk'
$source=[IO.File]::ReadAllText($controller)
$retry='            waiting := ArmReactionTimer(job,ReactionCountdown,-1000)'
if (!$source.Contains($retry)) { throw 'Missing registration retry injection point' }
$source=$source.Replace($retry,"            ReviewBeforeCaptureRetry()`r`n"+$retry)
$queue='        SetTimer(callback, period)'
if (!$source.Contains($queue)) { throw 'Missing quick reaction injection point' }
[IO.File]::WriteAllText($controller,$source.Replace($queue,"        if callback = QuickReaction`r`n            ReviewBeforeQuickStart()`r`n"+$queue),[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global ReviewChecks := 0, ReviewFocusCalls := 0, ReviewFocusChanges := true, ReviewStatusCalls := 0, ReviewContextCalls := 0, ReviewCaptureRetryFailure := false, ReviewQuickStartFailure := false, ReviewTargetChange := false, ReviewReplacementJob := 0
BuildManagement()
initialReactionStatus := ReactionExecutionStatus, initialReactionResult := LastReactionResult
info := ReadDiagnosticSnapshot()
AssertReview(info.PhaseCode="idle" && info.Phase="待機中","diagnostics describe an idle application")
job := CreateReactionJob({Mode:"queued"})
ActiveReactionJob := job
SetReactionStatus("phase snapshot fixture")
info := ReadDiagnosticSnapshot()
AssertReview(info.PhaseCode="queued" && info.Phase="キーを離すのを待っています","diagnostics show the active queued job")
SetReactionJobPhase(job,"waiting")
info := ReadDiagnosticSnapshot()
AssertReview(info.PhaseCode="waiting" && info.Phase="開始・登録待ち","diagnostics read waiting from the job before another message is published")
SetReactionJobPhase(job,"running")
info := ReadDiagnosticSnapshot()
AssertReview(info.PhaseCode="running" && info.Phase="実行中","diagnostics read running from the job rather than the previous display snapshot")
IsBrowserOperationBusy := true
CancelReaction()
info := ReadDiagnosticSnapshot()
AssertReview(info.PhaseCode="stopping" && info.Phase="停止処理中","diagnostics describe cancellation while awaiting the current operation")
IsBrowserOperationBusy := false
CancelReaction()
info := ReadDiagnosticSnapshot()
AssertReview(info.PhaseCode="finished" && info.Phase="終了","diagnostics show the terminal snapshot once the job is released")
ActiveReactionJob := CreateReactionJob({Phase:"fixture_unrecognized_phase"})
info := ReadDiagnosticSnapshot()
AssertReview(info.Phase="不明" && info.PhaseCode="fixture_unrecognized_phase","diagnostics preserve an unrecognized phase code")
AssertReview(InStr(BuildDiagnosticReport(info),"fixture_unrecognized_phase"),"copied diagnostics retain the code needed to investigate an unknown phase")
FinishReactionJob(ActiveReactionJob)
ReactionExecutionStatus := initialReactionStatus, LastReactionResult := initialReactionResult
AutoMode := false
TargetBrowserHwnd := 123
RecordBrowserOperation({Mode:"reaction_send",State:"menu_closed",Duration:100})
RefreshReactionRegistration()
AssertReview(ReviewStatusCalls=1,"display query reaches worker after registration handshake")
AssertReview(LastBrowserOperation.Mode="reaction_send" && LastBrowserOperation.State="menu_closed","display query preserves failure")
for topic in [Help,ShowReactionDetails,ShowDiagnostics] {
    topic.Call()
    Sleep(30)
    active := WinExist("A")
    AssertReview(IsAppWindow(active),"owned auxiliary view belongs to application")
    TargetBrowserHwnd := 123
    ShowPalette()
    AssertReview(TargetBrowserHwnd=123,"palette preserves target from auxiliary view")
    if active != PaletteWindow.Hwnd
        WinClose("ahk_id " active)
    Sleep(30)
}
ReviewQuickStartFailure := true
QueueQuickReaction()
AssertReview(!ActiveReactionJob && LastReactionResult.Reason="unavailable" && LastReactionResult.Detail="quick start failure","quick start failure releases job and preserves error")
Critical("On")
try {
    QueueQuickReaction()
    AssertReview(ActiveReactionJob && ActiveReactionJob.Phase="queued","quick shortcut can be queued again after failure")
    CancelReaction()
    AssertReview(!ActiveReactionJob && LastReactionResult.Reason="cancelled","queued shortcut remains cancellable")
} finally Critical("Off")
AssertReview(!ScheduleReaction("reaction_send",3),"closed browser rejects scheduled start")
AssertReview(!ActiveReactionJob && LastReactionResult.Reason="unavailable","failed activation releases reaction ownership")
AssertReview(!ScheduleReaction("reaction_send",3) && !ActiveReactionJob && ReviewContextCalls=2,"another scheduled attempt reaches browser lookup after failed start")
replacement := CreateReactionJob({Mode:"queued",Window:123})
ReviewReplacementJob := replacement
AssertReview(!ScheduleReaction("reaction_send",3) && ActiveReactionJob=replacement,"context reply cannot overwrite a newer reaction job")
FinishReactionJob(replacement)
browser := Gui()
browser.Show("w200 h100")
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=browser.Hwnd
TargetBrowserHwnd := browser.Hwnd
try {
    ReviewTargetChange := true
    AssertReview(ScheduleReaction("reaction_capture",60),"scheduled registration retains original window across context lookup")
    AssertReview(ActiveReactionJob.Window=browser.Hwnd && TargetBrowserHwnd=123,"job uses the queried window even when palette target changes")
    AssertReview(ActiveReactionJob && ActiveReactionJob.Phase="waiting","successful start retains waiting job")
    CancelReaction()
    AssertReview(!ActiveReactionJob && LastReactionResult.Reason="cancelled","scheduled registration remains cancellable")
} finally {
    CancelReaction()
    browser.Destroy()
    RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
    TargetBrowserHwnd := 123
}
RuntimePorts.Foreground := (hwnd) => hwnd=123
try {
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:123,Video:"abcdefghijk"})
    ReactionCountdown()
    AssertReview(ActiveReactionJob && ActiveReactionJob.Phase="waiting","unsupported capture retains scheduled wait")
    AssertReview(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"registration retry keeps conflicting controls disabled")
    CancelReaction()
    AssertReview(!ActiveReactionJob,"registration wait can be cancelled")
    ReviewCaptureRetryFailure := true
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:123,Video:"abcdefghijk"})
    ReactionCountdown()
    AssertReview(!ActiveReactionJob && LastReactionResult.Reason="unavailable" && LastReactionResult.Detail="capture retry failure","retry preparation failure releases job and preserves error")
    AssertReview(OperationAllowed("reaction") && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"capture failure restores controls when job ownership ends")
} finally {
    CancelReaction()
    RuntimePorts.Foreground := ReviewWindowActive
}
ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:5,Total:10,Interval:0,Cancelled:false})
RunReactionSendLoop(ActiveReactionJob)
AssertReview(!ActiveReactionJob && LastReactionResult.Completed=5 && LastReactionResult.Total=10,"focus stop preserves structured counts")
AssertReview(InStr(LastReactionResult.Message,"5 / 10") && LastReactionResult.Reason="wrong_window","focus stop preserves visible count and reason")
firstJob := CreateReactionJob({Applied:"first settings",StartedAt:0,Total:1})
secondJob := CreateReactionJob({Applied:"second settings",StartedAt:0,Total:1})
ActiveReactionJob := firstJob
ApplyReactionResult(firstJob,{State:"operated"})
AssertReview(InStr(LastReactionResult.Message,"first settings") && !InStr(LastReactionResult.Message,"second settings"),"completion describes its own settings after another job was created")
ActiveReactionJob := secondJob
ApplyReactionResult(secondJob,{State:"operated"})
AssertReview(InStr(LastReactionResult.Message,"second settings"),"next completion describes its own settings")
previous := LastReactionResult
ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:0,Total:10,Interval:0,Cancelled:false})
CancelReaction()
AssertReview(LastReactionResult != previous && LastReactionResult.Detail="" && LastReactionResult.Completed=0,"cancellation publishes fresh result")
failedJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:3,Total:10,Interval:0,Cancelled:false})
ActiveReactionJob := failedJob
ApplyReactionResult(failedJob,{State:"unknown",Detail:"current attempt detail"})
AssertReview(LastReactionResult.Detail="current attempt detail" && LastReactionResult.Completed=3 && LastReactionResult.Reason="unknown"
    && InStr(LastReactionResult.Message,"操作済み 3 / 10 回で停止。"),"failure detail and visible count are from same attempt")
snapshot := LastReactionResult
SetReactionStatus("next attempt running")
AssertReview(LastReactionResult=snapshot,"progress does not mutate previous final result")
ActiveReactionJob := CreateReactionJob({Mode:"queued",Window:123,Cancelled:false})
CancelReaction()
AssertReview(LastReactionResult.Detail="" && LastReactionResult.Mode="queued","queued cancel does not reuse failure detail")
ExecuteDanmakuCommand("add","","",{Name:"visible row",Text:"fixture",Slot:0})
ShowManagement(1)
LayoutManagement(ManagementWindow,0,360,520)
AssertReview(SendMessage(0x1028,0,0,ManagedList.Hwnd)>=1,"minimum management size exposes at least one complete item")
ManagementStatus.Text := "チャンネルと連携しました。自動判別でこの配信者の弾幕を選びます。"
ManagementStatus.GetPos(&sx,&sy,&sw,&sh)
ManagementBack.GetPos(&bx,&by,&bw,&bh)
AssertReview(sw=328 && sh>=44 && sy+sh<=by,"narrow notice uses full width above back button")
AssertReview(ManagementStatus.Type="Edit" && (ControlGetStyle(ManagementStatus.Hwnd)&0x800),"long notification is read-only and selectable")
AssertReview(!!(ControlGetStyle(ManagementStatus.Hwnd)&0x200000),"long notification supports vertical scrolling")
for size in [[360,520],[760,660]] {
    LayoutManagement(ManagementWindow,0,size[1],size[2])
    for control in [ManagedList,ManagementScopeHint,ReactionLoadButton,ManagementSupportButtons["diagnostics"],ManagementStatus,ManagementBack] {
        control.GetPos(&x,&y,&w,&h)
        AssertReview(x>=0 && y>=0 && x+w<=size[1] && y+h<=size[2],"all compact and regular controls fit")
    }
}
FileAppend("PASS: " ReviewChecks " review regression checks; no real browser operations`n","*")
ExitApp(0)
AssertReview(condition,label) {
    global ReviewChecks
    if !condition
        throw Error(label)
    ReviewChecks++
}
ReviewBeforeQuickStart() {
    global ReviewQuickStartFailure
    if ReviewQuickStartFailure {
        ReviewQuickStartFailure := false
        throw Error("quick start failure")
    }
}
ReviewBeforeCaptureRetry() {
    global ReviewCaptureRetryFailure
    if ReviewCaptureRetryFailure {
        ReviewCaptureRetryFailure := false
        throw Error("capture retry failure")
    }
}
ReviewWindowActive(hwnd) {
    global ReviewFocusCalls
    return ++ReviewFocusCalls=1
}
FixtureWorkerRequest(hwnd,mode:="resolve",expectedVideo:="",extra:="") {
    if mode = "reaction_configure"
        return {State:"configured",Author:"",Channel:"",Video:"",Detail:""}
    if mode = "reaction_capture"
        return {State:"unsupported",Author:"",Channel:"",Video:"abcdefghijk",Detail:"menu unavailable"}
    if mode = "browser_context" {
        global ReviewContextCalls, ReviewTargetChange, TargetBrowserHwnd, ReviewReplacementJob, ActiveReactionJob
        ReviewContextCalls++
        if ReviewReplacementJob {
            ActiveReactionJob := ReviewReplacementJob
            ReviewReplacementJob := 0
        }
        if ReviewTargetChange {
            ReviewTargetChange := false
            TargetBrowserHwnd := 123
        }
        return {State:"ok",Author:"",Channel:"",Video:"abcdefghijk",Detail:""}
    }
    global ReviewStatusCalls
    ReviewStatusCalls++
    if mode != "reaction_status"
        throw Error("Unexpected browser operation: " mode)
    return {State:"configured",Author:"",Channel:"",Video:"",Detail:""}
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.Foreground := ReviewWindowActive
RuntimePorts.WorkerRequest := FixtureWorkerRequest
'@

# Independent lifecycle scenario: the final result must describe the queued attempt.
$release = New-TestRuntime
$quickTests = @'
global QuickScenario := "", QuickRequests := 0, QuickChecks := 0, QuickReplacement := 0
DefaultReactionCount := 1, DefaultReactionIntervalMs := 0
for entry in [["changed","changed","lookup detail"], ["unavailable","unavailable","lookup detail"],
    ["request_error","unknown","context exception"], ["release_error","unknown","key exception"],
    ["release_timeout","unavailable",""], ["before_switch","wrong_window",""],
    ["after_switch","wrong_window",""], ["cancel","cancelled",""]] {
    QuickScenario := entry[1], QuickRequests := 0
    queued := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := queued
    SetReactionStatus("waiting for quick fixture")
    QuickReaction()
    CheckQuick(!ActiveReactionJob && queued.Phase="finished" && OperationAllowed("reaction"),"ownership released: " QuickScenario)
    CheckQuick(LastReactionResult.Reason==entry[2] && LastReactionResult.Detail==entry[3],"final cause retained: " QuickScenario)
    CheckQuick(LastReactionResult.Mode="queued" && LastReactionResult.Completed=0 && ReactionExecutionStatus.Phase="finished"
        && ReactionExecutionStatus.Message==LastReactionResult.Message && PaletteStatusControl.Text==LastReactionResult.Message,"visible result belongs to this unstarted attempt: " QuickScenario)
    CheckQuick(QuickRequests=(InStr(QuickScenario,"release_") || QuickScenario="before_switch" ? 0 : 1),"no send or retry after start failure: " QuickScenario)
}
QuickScenario := "replacement", QuickRequests := 0
previousResult := LastReactionResult
queued := CreateReactionJob({Mode:"queued",Window:123})
ActiveReactionJob := queued
QuickReaction()
CheckQuick(ActiveReactionJob=QuickReplacement && QuickReplacement.Phase="queued" && LastReactionResult=previousResult
    && ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message="replacement pending","old start cannot finalize or overwrite replacement")
CancelReaction()
QuickScenario := "success", QuickRequests := 0
ActiveReactionJob := CreateReactionJob({Mode:"queued",Window:123})
QuickReaction()
CheckQuick(!ActiveReactionJob && QuickRequests=2 && LastReactionResult.Reason="completed"
    && LastReactionResult.Mode="reaction_send" && LastReactionResult.Completed=1,"successful handoff keeps the send result")
FileAppend("PASS: " QuickChecks " quick reaction result checks; no real browser operations`n","*")
ExitApp()
CheckQuick(value,message) {
    global QuickChecks
    if !value
        throw Error(message)
    QuickChecks++
}
QuickRelease(keys) {
    if QuickScenario="release_error"
        throw Error("key exception")
    return QuickScenario!="release_timeout"
}
QuickForeground(hwnd) {
    return QuickScenario!="before_switch" && !(QuickScenario="after_switch" && QuickRequests)
}
QuickRequest(hwnd,mode,video,extra) {
    global QuickRequests, QuickReplacement, ActiveReactionJob, IsBrowserOperationBusy
    QuickRequests++
    if mode="reaction_send" {
        if QuickScenario!="success"
            throw Error("unexpected reaction send")
        return {State:"operated"}
    }
    if mode!="browser_context"
        throw Error("unexpected operation")
    if QuickScenario="request_error"
        throw Error("context exception")
    if QuickScenario="cancel" {
        IsBrowserOperationBusy := true
        try CancelReaction()
        finally IsBrowserOperationBusy := false
    }
    if QuickScenario="replacement" {
        QuickReplacement := CreateReactionJob({Mode:"queued",Window:123})
        ActiveReactionJob := QuickReplacement
        SetReactionStatus("replacement pending")
    }
    return {State:QuickScenario="changed" || QuickScenario="unavailable" ? QuickScenario : "ok", Video:"abcdefghijk", Detail:"lookup detail"}
}
'@
Invoke-AppTest -Runtime $release -Body $quickTests -Setup @'
RuntimePorts.ShortcutRelease := QuickRelease
RuntimePorts.Foreground := QuickForeground
RuntimePorts.BrowserRequest := QuickRequest
'@

$ownershipRuntime=New-TestRuntime
$ownershipTests=@'
OnExit(StopBrowserWorker)
BuildManagement()
global OwnershipChecks := 0, OwnershipCase := 0, OwnershipReplacement := 0
global OwnershipForegroundCalls := 0, OwnershipRequests := 0, OwnershipPrecision := ""
for scenario in [{Point:1,Throws:false,Requests:0,Precision:""},
    {Point:1,Throws:true,Requests:0,Precision:""},
    {Point:2,Throws:false,Requests:0,Precision:"BE"},
    {Point:2,Throws:true,Requests:0,Precision:"BE"},
    {Point:0,Throws:true,Requests:1,Precision:"BE"}] {
    OwnershipCase := scenario, OwnershipForegroundCalls := 0, OwnershipRequests := 0, OwnershipPrecision := ""
    job := CreateReactionJob({Window:123,Video:"abcdefghijk",Total:2,Interval:100})
    ActiveReactionJob := job
    SetReactionStatus("original running")
    previousResult := LastReactionResult
    RunReactionSendLoop(job)
    label := scenario.Point "/" scenario.Throws
    CheckOwnership(ActiveReactionJob=OwnershipReplacement && OwnershipReplacement.Phase="queued" && !OwnershipReplacement.Cancelled,"old failure cannot stop replacement: " label)
    CheckOwnership(job.Phase="finished" && OwnershipPrecision==scenario.Precision && OwnershipRequests=scenario.Requests,"old loop finishes and releases only its resources: " label)
    CheckOwnership(ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message=="replacement pending" && LastReactionResult=previousResult,"old result cannot overwrite replacement progress or previous result: " label)
    CheckOwnership(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"replacement keeps operation controls locked: " label)
    FinishReactionJob(OwnershipReplacement)
}
FileAppend("PASS: " OwnershipChecks " send-loop ownership checks; no real browser operations`n","*")
ExitApp()
CheckOwnership(value,label) {
    global OwnershipChecks
    if !value
        throw Error(label)
    OwnershipChecks++
}
ReplaceOwnershipJob() {
    global ActiveReactionJob, OwnershipReplacement
    OwnershipReplacement := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := OwnershipReplacement
    SetReactionStatus("replacement pending")
    if OwnershipCase.Throws
        throw Error("failure from superseded operation")
}
OwnershipForeground(hwnd) {
    global OwnershipForegroundCalls
    OwnershipForegroundCalls++
    if OwnershipCase.Point=OwnershipForegroundCalls {
        ReplaceOwnershipJob()
        return false
    }
    return true
}
OwnershipRequest(hwnd,mode,video,extra) {
    global OwnershipRequests
    OwnershipRequests++
    if OwnershipCase.Point=0
        ReplaceOwnershipJob()
    return {State:"operated"}
}
OwnershipTiming(enabled) {
    global OwnershipPrecision
    OwnershipPrecision .= enabled ? "B" : "E"
    return enabled
}
'@
Invoke-AppTest -Runtime $ownershipRuntime -Body $ownershipTests -Setup @'
RuntimePorts.Foreground := OwnershipForeground
RuntimePorts.BrowserRequest := OwnershipRequest
RuntimePorts.TimingPrecision := OwnershipTiming
'@


$countdownRuntime=New-TestRuntime
$countdownTests=@'
OnExit(StopBrowserWorker)
BuildManagement()
global CountdownChecks := 0, CountdownCase := 0, CountdownReplacement := 0, CountdownRequests := 0
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
        CheckCountdown(CountdownRequests=expectedRequests,"only the original due job may query the browser: " label)
        if scenario.Replace {
            CheckCountdown(ActiveReactionJob=CountdownReplacement && CountdownReplacement.Phase="queued" && !CountdownReplacement.Cancelled && CountdownReplacement.Remaining=7,"replacement ownership and countdown are unchanged: " label)
            CheckCountdown(job.Phase="finished" && ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message=="replacement pending" && LastReactionResult=previousResult,"stale result cannot overwrite current progress: " label)
            CheckCountdown(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"replacement retains control locks: " label)
            FinishReactionJob(CountdownReplacement)
        } else if scenario.Reason!="" {
            CheckCountdown(!ActiveReactionJob && job.Phase="finished","terminal tick releases its owner: " label)
            CheckCountdown(LastReactionResult.Reason==scenario.Reason && LastReactionResult.Mode==scenario.Mode && LastReactionResult.Detail==(scenario.Throws ? "countdown failure" : ""),"terminal result preserves its own reason and details: " label)
            CheckCountdown(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"terminal tick restores controls: " label)
        } else {
            CheckCountdown(ActiveReactionJob=job && job.Phase="waiting" && job.Remaining=scenario.Remaining-1,"ordinary countdown and capture retry retain their owner: " label)
            CheckCountdown(ReactionExecutionStatus.Phase!="finished" && LastReactionResult=previousResult,"waiting does not publish a terminal result: " label)
            CheckCountdown(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"waiting retains control locks: " label)
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
CheckCountdown(CountdownRequests=1 && ActiveReactionJob=CountdownReplacement && CountdownReplacement.Remaining=7,"superseded capture never schedules another tick")
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
        CheckCountdown(!RetryArmed,"retry reaches its status-rendering boundary: " retryCase)
        if retryCase="cancelled" {
            CheckCountdown(!ActiveReactionJob && LastReactionResult.Reason="cancelled","retry rendering preserves cancellation: " retryCase)
            previousResult := LastReactionResult
            ReplaceCountdownRetry()
        }
        CheckCountdown(ActiveReactionJob=CountdownReplacement && LastReactionResult=previousResult
            && ReactionExecutionStatus.Message=="retry successor pending","retry preserves successor progress and the last result: " retryCase)
    } finally Critical(beforeCritical)
    try {
        Sleep(1150)
        CheckCountdown(CountdownRequests=1 && ActiveReactionJob=CountdownReplacement && CountdownReplacement.Remaining=7,"superseded retry leaves no timer that can advance its successor: " retryCase)
        CheckCountdown(job.Phase="finished" && !PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"superseded retry is terminal while successor keeps its controls: " retryCase)
    } finally {
        RetryArmed := false
        if ActiveReactionJob
            FinishReactionJob(ActiveReactionJob)
    }
}
FileAppend("PASS: " CountdownChecks " countdown ownership checks; no real browser operations`n","*")
ExitApp()
CheckCountdown(value,label) {
    global CountdownChecks
    if !value
        throw Error(label)
    CountdownChecks++
}
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

# A suspended start must never schedule or report on behalf of its successor.
$startRuntime=New-TestRuntime
$startTests=@'
OnExit(StopBrowserWorker)
BuildManagement()
global StartChecks := 0, StartCase := 0, StartPoint := "", StartProbeArmed := false, StartProbeReached := false
global StartOriginal := 0, StartReplacement := 0, StartPreservedResult := 0, StartRequests := 0
browser := Gui()
browser.Show("w200 h100")
TargetBrowserHwnd := browser.Hwnd
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

# Re-entry while releasing controls or rendering a final result must preserve the successor.
$resultRuntime=New-TestRuntime
$uiPath=Join-Path $resultRuntime 'src\ui\ui_runtime.ahk'
$uiSource=[IO.File]::ReadAllText($uiPath)
$needle="RefreshOperationControls() {"
if (!$uiSource.Contains($needle)) { throw 'Missing operation-control boundary' }
[IO.File]::WriteAllText($uiPath,$uiSource.Replace($needle,$needle+"`r`n    ProbeResultPublication()"),[Text.UTF8Encoding]::new($true))
$resultTests=@'
OnExit(StopBrowserWorker)
BuildManagement()
global ResultChecks := 0, ResultArmed := false, ResultPoint := "", ResultCase := ""
global ResultReplacement := 0, ResultPreserved := 0
for point in ["release","render"] {
    for scenario in ["completed","unknown","cancelled","countdown","quick"] {
        ResultPoint := point, ResultCase := scenario
        job := CreateReactionJob({Mode:scenario="quick" ? "queued" : scenario="countdown" ? "reaction_capture" : "reaction_send",
            Window:123,Video:"abcdefghijk",Total:1,Interval:0,Remaining:0})
        ActiveReactionJob := job
        SetReactionStatus("original pending")
        ResultReplacement := 0, ResultArmed := true
        if scenario="cancelled"
            CancelReaction()
        else if scenario="countdown"
            ReactionCountdown()
        else if scenario="quick"
            QuickReaction()
        else
            RunReactionSendLoop(job)
        label := point "/" scenario
        CheckResult(!ResultArmed && ResultReplacement && ActiveReactionJob=ResultReplacement,"successor owns execution: " label)
        CheckResult(job.Phase="finished" && ResultReplacement.Phase="queued" && ResultReplacement.Completed=0,"finished attempt does not mutate successor: " label)
        CheckResult(ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message=="successor pending" && LastReactionResult=ResultPreserved,"successor progress and saved result survive: " label)
        CheckResult(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"successor controls remain locked: " label)
        tip := "ahk_class tooltips_class32 ahk_pid " DllCall("GetCurrentProcessId")
        CheckResult(WinExist(tip) && WinGetTitle(tip)=="successor tip","old result does not clear or replace successor notification: " label)
        CheckResult(!SetReactionStatus("late progress",false,"",job) && ReactionExecutionStatus.Message=="successor pending","late progress is rejected at publication boundary: " label)
        FinishReactionJob(ResultReplacement)
        ShowStatusTip()
    }
}
FileAppend("PASS: " ResultChecks " result publication ownership checks; no real browser operations`n","*")
ExitApp()
CheckResult(value,label) {
    global ResultChecks
    if !value
        throw Error(label)
    ResultChecks++
}
ProbeResultPublication() {
    global ResultArmed, ResultReplacement, ResultPreserved, ActiveReactionJob
    if !IsSet(ResultArmed) || !ResultArmed || ActiveReactionJob
        return
    if ResultPoint="render" && ReactionExecutionStatus.Phase!="finished"
        return
    ResultArmed := false
    ResultPreserved := LastReactionResult
    ResultReplacement := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := ResultReplacement
    SetReactionStatus("successor pending")
    ShowStatusTip("successor tip")
}
ResultRequest(hwnd,mode,video,extra) {
    return {State:ResultCase="completed" ? "operated" : "unknown",Detail:"fixture failure"}
}
'@
Invoke-AppTest -Runtime $resultRuntime -Body $resultTests -Setup @'
RuntimePorts.Foreground := (hwnd) => ResultCase!="countdown" && ResultCase!="quick"
RuntimePorts.ShortcutRelease := (key) => true
RuntimePorts.BrowserRequest := ResultRequest
'@
