# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    global Sent := [], Scenario := "", QueueScope := "shared", Calls := []
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
    for character in [Chr(8),Chr(9)] {
        invalidBody := "prefix" character "suffix"
        invalid := ExecuteDanmakuCommand("add","","",{Name:"control character",Text:invalidBody,Slot:1})
        Sent := [], Calls := []
        Assert(!RunPageAction("chat_focus",123) && !Sent.Length && LastBrowserOperation.State="invalid_text","queued control characters never reach the input adapter")
        Assert(!ActivePageAction && !IsBrowserOperationBusy && InStr(PaletteHint.Text,"弾幕を編集"),"rejected queued text releases ownership and explains the correction")
        Assert(LoadSettings(SettingsDatabasePath).SharedDanmakuItems[invalid.Index].Text==invalidBody,"input rejection preserves the original stored body")
        UndoLibraryCommand()
    }
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
    verificationFailures := Map("changed_field",["wrong_input","入力欄を確認できません"],
        "verified_video_changed",["changed","動画が変わった"],"verified_video_empty",["changed","動画が変わった"])
    for scenarioName in ["failure","throw","expired","release_failed","changed_video","changed_field","missing_token","verified_video_changed","verified_video_empty","expired_after_verify","background","background_after_verify","edited","editor","reaction","send_unknown"] {
        Scenario := scenarioName, Sent := [], Calls := [], ForegroundOk := true
        Assert(!RunPageAction("chat_focus",123) && !Sent.Length,"rejected input has no effect: " Scenario)
        Assert(!ActivePageAction && !IsBrowserOperationBusy,"failed operation releases ownership: " Scenario)
        if verificationFailures.Has(Scenario) {
            expected := verificationFailures[Scenario]
            Assert(LastBrowserOperation.State=expected[1] && InStr(PaletteHint.Text,expected[2]),
                "queued verification preserves its reason in diagnostics and guidance: " Scenario)
            Assert(Calls.Length=3 && Calls[3].Mode="verify_chat","failed queued verification is not retried: " Scenario)
        }
        if Scenario="missing_token"
            Assert(Calls.Length=1,"missing proof prevents target resolution as well as verification")
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
            return {State:Scenario="failure" ? "focus_failed" : "focused",Video:"abcdefghijk",Detail:Scenario="missing_token" ? "" : "proof"}
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
        return {State:Scenario="changed_field" ? "wrong_input" : "ok",Video:Scenario="verified_video_changed" ? "ABCDEFGHIJK" : (Scenario="verified_video_empty" ? "" : video)}
    }
    throw Error("Unexpected request")
}
'@

# Time spent validating the final item still counts toward the pending deadline.
Invoke-AppFixture -Body @'
    global ValidationClock := 1000, ValidationElapsed := 0, ExpireDuringValidation := false, ValidationSent := []
    AutoMode := false
    item := SharedDanmakuItems[1]
    global ValidationText := item.Text
    item.DefineProp("Text",{Get:ReadQueuedValidationText})
    RuntimePorts.Clock := (*) => ValidationClock
    RuntimePorts.Foreground := (hwnd) => hwnd=123
    RuntimePorts.BrowserRequest := RequestQueuedValidation
    RuntimePorts.ShortcutRelease := (*) => true
    RuntimePorts.Text := (text) => ValidationSent.Push(text)
    for elapsed in [4999,5000,5001] {
        for callerCritical in [0,23] {
            ValidationClock := 1000, ValidationElapsed := elapsed, ExpireDuringValidation := false, ValidationSent := []
            try {
                Critical(callerCritical)
                completed := RunPageAction("chat_focus",123)
                Assert(A_IsCritical=callerCritical,"queued deadline restores caller interruption policy")
                expected := elapsed<=5000
                Assert(completed=expected && ValidationSent.Length=(expected ? 1 : 0),"final item validation honours the deadline: " elapsed)
                Assert(LastBrowserOperation.State=(expected ? "inserted" : "input_cancelled"),"deadline result reports whether text was inserted")
                Assert(!ActivePageAction && !IsBrowserOperationBusy,"final validation releases the focus operation")
            } finally Critical("Off")
        }
    }
'@ -Helpers @'
ReadQueuedValidationText(item) {
    global ValidationClock, ExpireDuringValidation
    if ExpireDuringValidation {
        ExpireDuringValidation := false
        ValidationClock += ValidationElapsed
    }
    return ValidationText
}
RequestQueuedValidation(hwnd,mode,video,extra) {
    global ExpireDuringValidation
    if mode="chat_focus" {
        QueueFocusedDanmaku("shared",1,hwnd)
        return {State:"focused",Video:"abcdefghijk",Detail:"validation-token"}
    }
    if mode="browser_context"
        return {State:"ok",Video:"abcdefghijk"}
    if mode="verify_chat" {
        ExpireDuringValidation := true
        return {State:"ok",Video:video}
    }
    throw Error("Unexpected queued validation request")
}
'@
