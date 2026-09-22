# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
OnExit(StopBrowserWorker)
global ReviewChecks := 0, ReviewFocusCalls := 0, ReviewFocusChanges := true, ReviewStatusCalls := 0
try {
    BuildManagement()
    AutoMode := false
    TargetBrowserHwnd := 123
    LastBrowserOperation := {Mode:"reaction_send",State:"menu_closed",Duration:100}
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
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Completed:5,Total:10,Interval:0,Cancelled:false})
    ReactionSendNext()
    AssertReview(!ActiveReactionJob && LastReactionResult.Completed=5 && LastReactionResult.Total=10,"focus stop preserves structured counts")
    AssertReview(InStr(LastReactionResult.Message,"5 / 10") && LastReactionResult.Reason="wrong_window","focus stop preserves visible count and reason")
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
ReviewWindowActive(hwnd) {
    global ReviewFocusCalls
    return ++ReviewFocusCalls=1
}
FixtureWorkerRequest(hwnd,mode:="resolve",expectedVideo:="",extra:="") {
    if mode = "reaction_configure"
        return {State:"configured",Author:"",Channel:"",Video:"",Detail:""}
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
