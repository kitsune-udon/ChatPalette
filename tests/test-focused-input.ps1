# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    global Sent := [], Scenario := "", QueueScope := "shared", InputVideo := "abcdefghijk", Calls := []
    global ForegroundOk := true, QueueDuringRelease := false
    AutoMode := false
    ExecuteDanmakuCommand("add","","",{Name:"first",Text:"first draft",Slot:1})
    ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second draft",Slot:2})
    RuntimePorts.BrowserRequest := QueueRequest
    RuntimePorts.Foreground := (hwnd) => ForegroundOk && hwnd=123
    RuntimePorts.Text := QueueText
    RuntimePorts.ClearChat := (*) => 0
    RuntimePorts.ShortcutRelease := QueueRelease
    Assert(!QueueFocusedDanmaku("shared",1,123),"ordinary shortcut is not queued without focus")
    Assert(RunPageAction("chat_focus",123) && Sent.Length=1 && Sent[1]="first draft","focus then one input succeeds")
    Assert(Calls.Length=3 && Calls[3].Mode="verify_chat" && Calls[3].Extra="FocusToken=proof","delivery pins exact focus token")
    Assert(!ActivePageAction && !IsBrowserOperationBusy && LastBrowserOperation.State="inserted","completed queue releases state")
    ; Cross the 32-bit uptime boundary without a multi-day or five-second wait.
    global QueueClock := 0
    RuntimePorts.Clock := (*) => QueueClock
    for entry in [["clock_before_deadline",4999,true],["clock_expired",5001,false],["clock_expired_after_verify",5001,false]] {
        Scenario := entry[1], QueueClock := 4294967290, Sent := [], Calls := []
        completed := RunPageAction("chat_focus",123)
        Assert(completed=entry[3] && Sent.Length=(entry[3] ? 1 : 0),"queued input honours elapsed deadline across 32-bit uptime: " Scenario)
        Assert(LastBrowserOperation.Duration=entry[2],"page duration stays nonnegative and uses the same elapsed clock: " Scenario)
        Assert(!ActivePageAction && !IsBrowserOperationBusy,"deadline decision releases focus ownership: " Scenario)
    }
    RuntimePorts.Clock := 0
    for scenarioName in ["failure","throw","expired","release_failed","changed_video","changed_field","expired_after_verify","background","background_after_verify","edited","editor","reaction","send_unknown"] {
        Scenario := scenarioName, Sent := [], Calls := [], ForegroundOk := true
        Assert(!RunPageAction("chat_focus",123) && !Sent.Length,"rejected input has no effect: " Scenario)
        Assert(!ActivePageAction && !IsBrowserOperationBusy,"failed operation releases ownership: " Scenario)
        if Scenario="send_unknown"
            Assert(LastBrowserOperation.State="unknown","uncertain input is not reported as safely cancelled")
        ActiveEditorDialog := false, ActiveReactionJob := 0
    }
    Scenario := "", ForegroundOk := true, Sent := [], QueueDuringRelease := true
    Assert(RunPageAction("chat_focus",123,GetShortcutKey("chat_focus")) && Sent.Length=1,"shortcut during initial modifier release is queued without blocking focus")
    QueueDuringRelease := false
    profile := ExecuteProfileCommand("add","","queued profile","/channel/queued").ProfileId
    ExecuteDanmakuCommand("add",profile,"",{Name:"profile item",Text:"profile draft",Slot:1})
    AutoMode := true, QueueScope := "profile", Sent := []
    RuntimePorts.ResolveChannel := (hwnd) => {State:"ok",Author:"fixture",Channel:"/channel/queued",Video:"abcdefghijk"}
    Assert(RunPageAction("chat_focus",123) && Sent.Length=1 && Sent[1]="profile draft","auto profile resolves against focused video using queued library snapshot")
    QueueScope := "shared", Sent := [], Calls := []
    Assert(RunPageAction("chat_clear",123) && !Sent.Length,"clear operation never accepts deferred danmaku")
'@ -Helpers @'
QueueText(text) {
    if Scenario="send_unknown"
        throw Error("Unknown native input result")
    Sent.Push(text)
}
QueueRelease(keys) {
    if QueueDuringRelease && keys[1]="f" {
        Assert(QueueFocusedDanmaku(QueueScope,1,123),"queue accepted during initial key release")
        Assert(!OperationAllowed("edit") && !OperationAllowed("reaction"),"focus ownership blocks unrelated operations")
    }
    return Scenario != "release_failed"
}
QueueRequest(hwnd,mode,video,extra) {
    global IsBrowserOperationBusy, ForegroundOk, ActiveEditorDialog, ActiveReactionJob, QueueClock
    Calls.Push({Mode:mode,Extra:extra})
    if mode="chat_focus" {
        IsBrowserOperationBusy := true
        try {
            if ActivePageAction && ActivePageAction.AcceptsPending {
                Assert(QueueFocusedDanmaku(QueueScope,1,123),"first input accepted")
                QueueFocusedDanmaku(QueueScope,2,123)
                Assert(ActivePageAction.Pending.Slot=1 && !Sent.Length,"second input cannot replace first or run while focus is pending")
                if Scenario="clock_before_deadline" || Scenario="clock_expired"
                    QueueClock += Scenario="clock_before_deadline" ? 4999 : 5001
                if Scenario="expired"
                    ActivePageAction.Pending.Deadline := AppClockMs()-1
                if Scenario="background"
                    ForegroundOk := false
                if Scenario="reaction"
                    ActiveReactionJob := CreateReactionJob({Mode:"queued"})
                if Scenario="editor"
                    ActiveEditorDialog := {Label:"fixture"}
            } else
                Assert(!QueueFocusedDanmaku(QueueScope,1,123),"non-focus page action cannot queue")
            if Scenario="throw"
                throw Error("synthetic failure")
            return {State:Scenario="failure" ? "focus_failed" : "focused",Video:"abcdefghijk",Detail:"proof"}
        } finally IsBrowserOperationBusy := false
    }
    if mode="browser_context"
        return {State:"ok",Video:Scenario="changed_video" ? "ABCDEFGHIJK" : "abcdefghijk"}
    if mode="verify_chat" {
        if Scenario="clock_expired_after_verify"
            QueueClock += 5001
        if Scenario="expired_after_verify"
            ActivePageAction.Pending.Deadline := AppClockMs()-1
        if Scenario="background_after_verify"
            ForegroundOk := false
        if Scenario="edited" {
            for i,item in SharedDanmakuItems
                if item.Slot=1 {
                    ExecuteDanmakuCommand("edit","",item.Id,{Name:item.Name,Text:"modified draft",Slot:1})
                    break
                }
        }
        return {State:Scenario="changed_field" ? "wrong_input" : "ok",Video:video}
    }
    throw Error("Unexpected request")
}
'@
