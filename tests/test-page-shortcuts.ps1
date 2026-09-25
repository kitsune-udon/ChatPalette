# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    global PageCalls := [], ClearCalls := 0, PageForeground := true, PageFailure := "", PageSwitch := false
    global FocusFailure := "", PageFocusToken := "clear-proof", PageTargetChanged := false
    RuntimePorts.BrowserRequest := PageRequest
    RuntimePorts.Foreground := (hwnd) => PageForeground && hwnd=123
    RuntimePorts.ClearChat := () => CountClear()
    Assert(RunPageAction("chat_focus",123) && PageCalls.Length=1 && PageCalls[1].Mode="chat_focus" && !ClearCalls,"focus never clears or sends")
    PageCalls := []
    Assert(RunPageAction("reactions_show",123) && PageCalls.Length=1 && PageCalls[1].Mode="reactions_show" && !ClearCalls,"show is a distinct non-sending request")
    PageCalls := []
    Assert(RunPageAction("chat_clear",123) && ClearCalls=1 && PageCalls.Length=2,"clear focuses and verifies before one deletion")
    Assert(LastBrowserOperation.Mode="chat_clear" && LastBrowserOperation.State="cleared" && LastBrowserOperation.Stage="クリアキー送信","diagnostics describe complete clear action")
    Assert(PageCalls[2].Mode="verify_chat" && PageCalls[2].Video="abcdefghijk","clear pins video from focus result")
    Assert(PageCalls[2].Extra="FocusToken=clear-proof","clear pins the exact element from focus result")
    PageTargetChanged := true
    Assert(!RunPageAction("chat_clear",123) && ClearCalls=1,"another chat in the same video is not cleared")
    PageTargetChanged := false, PageFocusToken := "", PageCalls := []
    Assert(!RunPageAction("chat_clear",123) && ClearCalls=1 && PageCalls.Length=1,"missing focus identity prevents deletion before verification")
    PageFocusToken := "clear-proof"
    for state in ["wrong_input","changed","unavailable","unknown"] {
        PageFailure := state, PageCalls := []
        Assert(!RunPageAction("chat_clear",123) && ClearCalls=1,"failed verification prevents deletion: " state)
    }
    Assert(LastBrowserOperation.Mode="chat_clear" && LastBrowserOperation.Stage="クリア前の確認","failure retains action and failed stage")
    PageFailure := ""
    for state,message in Map("chat_missing","見つかりません","chat_ambiguous","複数","focus_failed","フォーカス移動") {
        FocusFailure := state, PageCalls := []
        Assert(!RunPageAction("chat_clear",123) && ClearCalls=1 && PageCalls.Length=1,"failed focus never clears: " state)
        Assert(InStr(PaletteHint.Text,message) && LastBrowserOperation.State=state,"failure reason is retained in hint and diagnostics")
    }
    FocusFailure := ""
    PageFailure := "", PageSwitch := true
    Assert(!RunPageAction("chat_clear",123) && ClearCalls=1,"foreground change during verification prevents deletion")
    PageSwitch := false, PageForeground := true, PageCalls := []
    IsBrowserOperationBusy := true
    Assert(!RunPageAction("chat_clear",123) && !PageCalls.Length,"busy action is rejected before requesting focus")
    IsBrowserOperationBusy := false
    ActiveReactionJob := CreateReactionJob({Mode:"queued"})
    Assert(!RunPageAction("reactions_show",123) && !PageCalls.Length,"page actions do not interfere with running reactions")
    ActiveReactionJob := 0
    ShowManagement(1)
    ShowShortcutManager()
    Assert(!RunPageAction("chat_focus",123) && !PageCalls.Length,"editor prevents page actions")
    WinClose("ahk_id " ActiveEditorDialog.Window.Hwnd)
    Sleep(30)
    for action in ["chat_focus","chat_clear","reactions_show"] {
        keys := CurrentShortcutMap(), keys["reaction"] := keys[action]
        rejected := false
        try ValidateShortcutMap(keys)
        catch
            rejected := true
        Assert(rejected,"duplicate reaction/page assignment rejected before registration")
    }
'@ -Helpers @'
PageRequest(hwnd,mode,video,extra) {
    global PageForeground
    PageCalls.Push({Mode:mode,Video:video,Extra:extra})
    if mode="chat_focus"
        return {State:FocusFailure!="" ? FocusFailure : "focused",Video:"abcdefghijk",Detail:PageFocusToken}
    if mode="verify_chat" {
        if PageTargetChanged && extra="FocusToken=clear-proof"
            return {State:"wrong_input",Video:video}
        if PageSwitch
            PageForeground := false
        return {State:PageFailure!="" ? PageFailure : "ok",Video:video}
    }
    return {State:"hovered",Video:"abcdefghijk"}
}
CountClear() {
    global ClearCalls
    ClearCalls++
}
'@


# Page actions retain the same exclusion from key release through result publication.
Invoke-AppFixture -Body @'
    global OwnerScenario := "", OwnerProbes := [], OwnerRequests := 0, OwnerClears := 0
    global OwnerThrowClock := false, OwnerProbePublication := false, OwnerReplacement := 0, OwnerReplacementResult := 0
    RuntimePorts.Foreground := (hwnd) => hwnd=123
    RuntimePorts.ShortcutRelease := OwnerRelease
    RuntimePorts.BrowserRequest := OwnerRequest
    RuntimePorts.ClearChat := OwnerClear
    RuntimePorts.Clock := OwnerClock
    for action in ["chat_clear","chat_focus","reactions_show"] {
        for scenario in ["success","release_failed","request_failed","notification_failed"] {
            OwnerScenario := scenario, OwnerProbes := [], OwnerRequests := 0, OwnerClears := 0, OwnerThrowClock := false, OwnerProbePublication := false
            escaped := false, result := false
            try result := RunPageAction(action,123,GetShortcutKey(action))
            catch
                escaped := true
            Assert(OwnerProbes.Length>=1,"page lifecycle reaches the release boundary: " action "/" scenario)
            for probe in OwnerProbes {
                Assert(!probe.Input && !probe.Edit && !probe.Reaction && !probe.Preferences,"all conflicting operations remain blocked at " probe.Boundary ": " action "/" scenario)
                Assert(!probe.Nested && probe.RequestsBefore=probe.RequestsAfter,"another page action never reenters at " probe.Boundary ": " action "/" scenario)
                if probe.Boundary="result publication"
                    Assert(!probe.LateQueue,"result publication cannot accept an input that will never be drained: " action "/" scenario)
            }
            Assert(OperationAllowed("input") && OperationAllowed("edit") && OperationAllowed("reaction") && OperationAllowed("preferences"),"success or failure releases page ownership: " action "/" scenario)
            Assert(escaped=(scenario="notification_failed") && result=(scenario="success"),"page completion preserves success and failure meaning: " action "/" scenario)
            Assert(OwnerClears=(action="chat_clear" && (scenario="success" || scenario="notification_failed") ? 1 : 0),"only a verified clear reaches the deletion port once: " action "/" scenario)
        }
    }
    for action in ["chat_clear","chat_focus","reactions_show"] {
        for scenario in ["replacement","replacement_failed"] {
            OwnerScenario := scenario, OwnerProbes := [], OwnerRequests := 0, OwnerClears := 0, OwnerProbePublication := false
            Assert(!RunPageAction(action,123,GetShortcutKey(action)),"superseded page action cannot report success: " action "/" scenario)
            Assert(ActivePageAction=OwnerReplacement && !OperationAllowed("input"),"old cleanup preserves replacement ownership: " action "/" scenario)
            Assert(LastBrowserOperation=OwnerReplacementResult && PaletteHint.Text=="replacement pending","old result cannot overwrite replacement diagnostics or hint: " action "/" scenario)
            Assert(OwnerRequests=1 && !OwnerClears,"superseded action cannot verify, clear or send again: " action "/" scenario)
            ActivePageAction := 0
            RefreshOperationControls()
        }
    }
'@ -Helpers @'
OwnerProbe(boundary) {
    global OwnerProbes
    probe := {Boundary:boundary,Input:OperationAllowed("input"),Edit:OperationAllowed("edit"),
        Reaction:OperationAllowed("reaction"),Preferences:OperationAllowed("preferences"),RequestsBefore:OwnerRequests}
    ; Avoid recursion while recording the pre-fix policy failure.
    probe.Nested := probe.Input ? true : RunPageAction("reactions_show",123)
    probe.RequestsAfter := OwnerRequests
    if boundary="result publication"
        probe.LateQueue := QueueFocusedDanmaku("shared",1,123)
    OwnerProbes.Push(probe)
}
OwnerRelease(keys) {
    global OwnerProbePublication
    OwnerProbe("key release")
    OwnerProbePublication := OwnerScenario="release_failed"
    return OwnerScenario!="release_failed"
}
OwnerRequest(hwnd,mode,video,extra) {
    global OwnerRequests, OwnerThrowClock, OwnerProbePublication, ActivePageAction, OwnerReplacement, OwnerReplacementResult
    OwnerRequests++
    OwnerProbe(mode)
    if OwnerScenario="replacement" || OwnerScenario="replacement_failed" {
        OwnerReplacement := {Window:456,Pending:0,AcceptsPending:false}
        ActivePageAction := OwnerReplacement
        RecordBrowserOperation({Mode:"fixture",State:"pending",Duration:0})
        OwnerReplacementResult := LastBrowserOperation
        PaletteHint.Text := "replacement pending"
        if OwnerScenario="replacement_failed"
            throw Error("superseded page request failure")
    } else
        OwnerProbePublication := true
    if OwnerScenario="request_failed"
        throw Error("page request fixture failure")
    if OwnerScenario="notification_failed"
        OwnerThrowClock := true
    return {State:mode="chat_focus" ? "focused" : (mode="verify_chat" ? "ok" : "hovered"),Video:"abcdefghijk",Detail:"owner-proof"}
}
OwnerClear() {
    global OwnerClears
    OwnerProbe("clear keys")
    OwnerClears++
}
OwnerClock() {
    global OwnerThrowClock, OwnerProbePublication
    if OwnerProbePublication {
        OwnerProbePublication := false
        OwnerProbe("result publication")
    }
    if OwnerThrowClock {
        OwnerThrowClock := false
        throw Error("page notification fixture failure")
    }
    return 100
}
'@
