$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$browser = [IO.File]::ReadAllText((Join-Path $release 'browser_service.ahk'))
$browser = [regex]::Replace($browser, '(?ms)^IsBrowser\(hwnd\) \{.*?^\}', 'IsBrowser(hwnd) {`n    return hwnd = 123`n}'.Replace('`n',"`r`n"))
[IO.File]::WriteAllText((Join-Path $release 'browser_service.ahk'),$browser,[Text.UTF8Encoding]::new($true))
$worker = [IO.File]::ReadAllText((Join-Path $release 'worker_client.ahk')).Replace('SendWorkerRequest(hwnd,','UnusedRealWorkerRequest(hwnd,')
[IO.File]::WriteAllText((Join-Path $release 'worker_client.ahk'),$worker,[Text.UTF8Encoding]::new($true))
$reaction = [IO.File]::ReadAllText((Join-Path $release 'reaction_controller.ahk')).Replace('WinActive("ahk_id " job.Window)','ReviewWindowActive(job.Window)')
[IO.File]::WriteAllText((Join-Path $release 'reaction_controller.ahk'),$reaction,[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global ReviewChecks := 0, ReviewFocusCalls := 0, ReviewFocusChanges := true
try {
    BuildManagement()
    AutoMode := false
    TargetBrowserHwnd := 123
    LastBrowserOperation := {Mode:"reaction_send",State:"menu_closed",Duration:100}
    RefreshReactionRegistration()
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
    ActiveReactionJob := {Mode:"reaction_send",Window:123,Completed:5,Total:10,Interval:0,Cancelled:false}
    ReactionSendNext()
    AssertReview(!ActiveReactionJob && LastReactionResult.Completed=5 && LastReactionResult.Total=10,"focus stop preserves structured counts")
    AssertReview(InStr(LastReactionResult.Message,"5 / 10") && LastReactionResult.Reason="wrong_window","focus stop preserves visible count and reason")
    previous := LastReactionResult
    ActiveReactionJob := {Mode:"reaction_send",Window:123,Completed:0,Total:10,Interval:0,Cancelled:false}
    CancelReaction()
    AssertReview(LastReactionResult != previous && LastReactionResult.Detail="" && LastReactionResult.Completed=0,"cancellation publishes fresh result")
    failedJob := {Mode:"reaction_send",Window:123,Completed:3,Total:10,Interval:0,Cancelled:false}
    ActiveReactionJob := failedJob
    ApplyReactionResult(failedJob,{State:"unknown",Detail:"current attempt detail"})
    AssertReview(LastReactionResult.Detail="current attempt detail" && LastReactionResult.Completed=3 && LastReactionResult.Reason="unknown","failure detail and count are from same attempt")
    snapshot := LastReactionResult
    SetReactionStatus("next attempt running")
    AssertReview(LastReactionResult=snapshot,"progress does not mutate previous final result")
    ActiveReactionJob := {Mode:"queued",Window:123,Cancelled:false}
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
        try ReadSettingsFile(path)
        catch as failure
            errorText := failure.Message
        AssertReview(InStr(errorText,spec[2]) && FileRead(path)=original,"invalid counts and missing data rejected without modifying original")
    }
    largePath := A_ScriptDir "\too-large.ini"
    largeFile := FileOpen(largePath,"w")
    largeFile.Length := 32*1024*1024+1
    largeFile.Close()
    rejected := false
    try ReadSettingsFile(largePath)
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
SendWorkerRequest(hwnd,mode:="resolve",expectedVideo:="",extra:="") {
    if mode != "reaction_status"
        throw Error("Unexpected browser operation: " mode)
    return {State:"configured",Author:"",Channel:"",Video:"",Detail:""}
}
'@
$main = [IO.File]::ReadAllText((Join-Path $release 'main.ahk')).Replace('OnExit(StopBrowserWorker)',$tests)
[IO.File]::WriteAllText((Join-Path $release 'main.ahk'),$main,[Text.UTF8Encoding]::new($true))
$run=Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut',('"'+(Join-Path $release 'main.ahk')+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $release 'out.txt') -RedirectStandardError (Join-Path $release 'error.txt')
$null=$run.Handle
if(!$run.WaitForExit(20000)){$run.Kill();throw 'Regression test timeout'}
Get-Content (Join-Path $release 'out.txt'),(Join-Path $release 'error.txt')
if($run.ExitCode -ne 0){throw 'Review regression test failed'}
