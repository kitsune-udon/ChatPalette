# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
# Inject only into the isolated runtime: simulate failure just before scheduling a retry.
$retry='            waiting := ArmReactionTimer(job,ReactionCountdown,-1000)'
Edit-TestSource $release 'src/reactions/reaction_controller.ahk' $retry ("            ReviewBeforeCaptureRetry()`r`n"+$retry)
$queue='        SetTimer(callback, period)'
Edit-TestSource $release 'src/reactions/reaction_controller.ahk' $queue ("        if callback = QuickReaction`r`n            ReviewBeforeQuickStart()`r`n"+$queue)
$tests = @'
global ReviewChecks := 0, ReviewFocusCalls := 0, ReviewUnexpectedRequests := 0, ReviewContextCalls := 0, ReviewCaptureRetryFailure := false, ReviewQuickStartFailure := false, ReviewTargetChange := false, ReviewReplacementJob := 0
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
AssertReview(ReviewUnexpectedRequests=0,"displaying registration never requests a worker operation")
AssertReview(LastBrowserOperation.Mode="reaction_send" && LastBrowserOperation.State="menu_closed","display query preserves failure")
for topic in [{Show:Help,Title:"使い方"},{Show:ShowReactionDetails,Title:"リアクションの実行結果"},{Show:ShowDiagnostics,Title:"診断情報"}] {
    topic.Show.Call()
    active := WinExist(topic.Title " ahk_pid " DllCall("GetCurrentProcessId"))
    AssertReview(IsAppWindow(active),"owned auxiliary view belongs to application: " topic.Title)
    RequireTestWindowActive(active)
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
RuntimePorts.Foreground := (hwnd) => hwnd=123
RuntimePorts.BrowserRequest := (*) => {State:"operated"}
firstJob := CreateReactionJob({Window:123,Applied:"first settings",Total:1})
secondJob := CreateReactionJob({Window:123,Applied:"second settings",Total:1})
ActiveReactionJob := firstJob
RunReactionSendLoop(firstJob)
AssertReview(InStr(LastReactionResult.Message,"first settings") && !InStr(LastReactionResult.Message,"second settings"),"completion describes its own settings after another job was created")
ActiveReactionJob := secondJob
RunReactionSendLoop(secondJob)
AssertReview(InStr(LastReactionResult.Message,"second settings"),"next completion describes its own settings")
previous := LastReactionResult
ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:0,Total:10,Interval:0,Cancelled:false})
CancelReaction()
AssertReview(LastReactionResult != previous && LastReactionResult.Detail="" && LastReactionResult.Completed=0,"cancellation publishes fresh result")
failedJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:3,Total:10,Interval:0,Cancelled:false})
ActiveReactionJob := failedJob
RuntimePorts.BrowserRequest := (*) => {State:"unknown",Detail:"current attempt detail"}
RunReactionSendLoop(failedJob)
RuntimePorts.BrowserRequest := 0
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
    global ReviewUnexpectedRequests
    ReviewUnexpectedRequests++
    throw Error("Unexpected browser operation: " mode)
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.Foreground := ReviewWindowActive
RuntimePorts.WorkerRequest := FixtureWorkerRequest
'@
