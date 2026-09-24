# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
# Inject only into the isolated runtime: simulate failure just before scheduling a retry.
$controller=Join-Path $release 'src\reactions\reaction_controller.ahk'
$source=[IO.File]::ReadAllText($controller)
$retry='            SetTimer(ReactionCountdown, -1000)'
if (!$source.Contains($retry)) { throw 'Missing registration retry injection point' }
$source=$source.Replace($retry,"            ReviewBeforeCaptureRetry()`r`n"+$retry)
$queue='        SetTimer(QuickReaction, -1)'
if (!$source.Contains($queue)) { throw 'Missing quick reaction injection point' }
[IO.File]::WriteAllText($controller,$source.Replace($queue,"        ReviewBeforeQuickStart()`r`n"+$queue),[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global ReviewChecks := 0, ReviewFocusCalls := 0, ReviewFocusChanges := true, ReviewStatusCalls := 0, ReviewContextCalls := 0, ReviewCaptureRetryFailure := false, ReviewQuickStartFailure := false, ReviewTargetChange := false, ReviewReplacementJob := 0
try {
    BuildManagement()
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
        CancelReaction()
        AssertReview(!ActiveReactionJob,"registration wait can be cancelled")
        ReviewCaptureRetryFailure := true
        ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:123,Video:"abcdefghijk"})
        ReactionCountdown()
        AssertReview(!ActiveReactionJob && LastReactionResult.Reason="unavailable" && LastReactionResult.Detail="capture retry failure","retry preparation failure releases job and preserves error")
    } finally {
        CancelReaction()
        RuntimePorts.Foreground := ReviewWindowActive
    }
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:5,Total:10,Interval:0,Cancelled:false})
    ReactionSendNext()
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
    AssertReview(LastReactionResult.Detail="current attempt detail" && LastReactionResult.Completed=3 && LastReactionResult.Reason="unknown","failure detail and count are from same attempt")
    snapshot := LastReactionResult
    SetReactionStatus("next attempt running")
    AssertReview(LastReactionResult=snapshot,"progress does not mutate previous final result")
    ActiveReactionJob := CreateReactionJob({Mode:"queued",Window:123,Cancelled:false})
    CancelReaction()
    AssertReview(LastReactionResult.Detail="" && LastReactionResult.Mode="queued","queued cancel does not reuse failure detail")
    ExecuteDanmakuCommand("add","",0,{Name:"visible row",Text:"fixture",Slot:0})
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
    for spec in [
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=20000`n","Text1"],
        ["[General]`nCount=10001`n","Count"],
        ["[General]`nCount=1`n","Name"],
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=100001`n","Count"],
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=1`nText1=   `n","Text1"]] {
        path := A_ScriptDir "\invalid-" A_Index ".ini"
        FileAppend(spec[1],path,"UTF-16")
        original := FileRead(path)
        errorText := ""
        try ReadLegacySettings(path)
        catch as failure
            errorText := failure.Message
        AssertReview(InStr(errorText,spec[2]) && FileRead(path)=original,"invalid counts and missing data rejected without modifying original")
    }
    largePath := A_ScriptDir "\too-large.ini"
    largeFile := FileOpen(largePath,"w")
    largeFile.Length := 32*1024*1024+1
    largeFile.Close()
    rejected := false
    try ReadLegacySettings(largePath)
    catch
        rejected := true
    AssertReview(rejected,"oversized file rejected before parsing")
    FileAppend("PASS: " ReviewChecks " review regression checks; no real browser operations`n","*")
    ExitApp(0)
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.Line "`n","*")
    ExitApp(1)
}
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
