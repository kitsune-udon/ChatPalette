# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
global Sent := [], Effects := [], Scenario := "", ForegroundOk := true, BrowserCalls := [], Injected := false
global FocusToken := "", FocusConsumed := false, FocusCount := 0, SendAttempts := 0, ReactionCalls := 0
global QueueVideo := "abcdefghijk", QueueClock := 1000, CancelOnValidation := false
AutoMode := false
ExecuteDanmakuCommand("add","","",{Name:"first",Text:"first draft",Slot:1})
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second draft",Slot:2})
global BaseLibrary := {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}
RuntimePorts.BrowserRequest := QueueRequest
RuntimePorts.Foreground := (hwnd) => ForegroundOk && hwnd=123
RuntimePorts.Text := QueueText
RuntimePorts.ClearChat := QueueClear
RuntimePorts.TimingPrecision := (*) => false
DefaultReactionCount := 1, DefaultReactionIntervalMs := 0

RunQueue(["chat_focus","shared1","shared2","shared1","chat_clear","shared2","reactions_show","reaction","shared1"])
Assert(JoinQueueEffects()="focus|first draft|second draft|first draft|focus|clear|second draft|show|reaction|first draft",
    "all command kinds execute in FIFO order, including repeated input and completed reaction")
Assert(Sent.Length=5 && ReactionCalls=1 && !ActiveShortcutCommand && !ShortcutCommands.Length && !ShortcutSession,
    "completed queue releases its session and preserves every input")
Assert(StopHotkeyContext()=false,"stop context ends when queue and reaction finish")

ResetQueue("inject")
RunQueue(["chat_focus"])
Assert(Sent.Length=3 && Sent[1]="first draft" && Sent[2]="second draft" && Sent[3]="first draft",
    "callbacks during a focus request queue every command, including the same key again")

ResetQueue("long_wait")
RuntimePorts.Clock := (*) => QueueClock
RunQueue(["chat_focus","shared1","shared2"])
Assert(Sent.Length=2 && QueueClock=7000,"queue has no focus-specific five-second expiry")
RuntimePorts.Clock := 0

for actions in [["chat_focus","chat_clear","shared1"],["chat_focus","chat_focus","shared1"]] {
    ResetQueue("")
    RunQueue(actions)
    Assert(Sent.Length=1 && FocusConsumed && BrowserCalls[-1]=(actions[2]="chat_focus" ? "verify_chat" : "verify_input"),
        "clear invalidates an old proof and repeated focus uses only the latest proof")
}

for intervening in ["reactions_show","reaction"] {
    ResetQueue("")
    RunQueue(["chat_focus",intervening,"shared1"])
    Assert(Sent.Length=1 && FocusConsumed,"intervening reaction operation preserves exact chat proof: " intervening)
}
ResetQueue("show_changed_field")
RunQueue(["chat_focus","reactions_show","shared1","shared2"])
Assert(!Sent.Length && FocusConsumed && !ShortcutCommands.Length,
    "field change during reaction display fails exact chat verification and discards tail")

for name in ["focus_failed","request_throw","missing_token","changed_video","missing_video","changed_field",
    "verified_video_changed","verified_video_empty","background","background_after_verify","edited","editor",
    "reaction_gate","send_unknown","cancel_final_validation"] {
    ResetQueue(name)
    if name="cancel_final_validation" {
        for candidate in SharedDanmakuItems
            if candidate.Slot=1
                item := candidate
        global OriginalQueueText := item.Text
        item.DefineProp("Text",{Get:ReadQueueText})
    }
    RunQueue(["chat_focus","shared1","shared2"])
    Assert(!Sent.Length && !ShortcutCommands.Length && !ActiveShortcutCommand && !ShortcutSession,
        "failed or cancelled command discards its tail: " name)
    if name="send_unknown"
        Assert(SendAttempts=1,"unknown send is attempted once and never replayed")
    if name="cancel_final_validation"
        item.DefineProp("Text",{Value:OriginalQueueText})
    ActiveEditorDialog := false, ActiveReactionJob := 0
}

; CR/LF are rejected at persistence; the native delivery test covers all four.
for character in [Chr(8),Chr(9)] {
    ResetQueue("")
    invalid := ExecuteDanmakuCommand("add","","",{Name:"invalid",Text:"before" character "after",Slot:1})
    RunQueue(["shared1","shared2"])
    Assert(!SendAttempts && !Sent.Length && InStr(PaletteHint.Text,"弾幕を編集"),"invalid queued text stops before native delivery")
    Assert(LoadSettings(SettingsDatabasePath).SharedDanmakuItems[invalid.Index].Text=="before" character "after",
        "rejected queue preserves stored text")
}

for name in ["stop_new_session","throw_new_session"] {
    ResetQueue(name)
    RunQueue(["chat_focus","shared1"])
    Assert(Sent.Length=1 && Sent[1]="second draft" && !ShortcutSession,
        "old cancellation/failure cannot flush a new session: " name)
}

ResetQueue("")
Critical("On")
try {
    IsBrowserOperationBusy := true
    Assert(EnqueueConfiguredShortcut("shared1",123) && EnqueueConfiguredShortcut("shared1",123),"busy browser accepts repeated keys")
    DrainShortcutQueue()
    Assert(ShortcutCommands.Length=2 && !BrowserCalls.Length && StopHotkeyContext(),"busy operation defers execution and enables stop")
    HandleConfiguredShortcut("stop")
    IsBrowserOperationBusy := false
    DrainShortcutQueue()
    Assert(!Sent.Length && !ShortcutCommands.Length,"stop removes queued keys before they can execute")
} finally Critical("Off")

ResetQueue("")
Critical("On")
try {
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"old-video"})
    EnqueueConfiguredShortcut("shared1",123)
    Assert(ShortcutSession.Video="old-video","enqueue inherits a known active operation video")
    DrainShortcutQueue()
    ActiveReactionJob := 0
    DrainShortcutQueue()
    Assert(!Sent.Length && !ShortcutSession,"queued command rejects a video changed while an existing reaction ran")
} finally Critical("Off")

for gate in ["editor","refresh","transfer"] {
    ResetQueue("")
    if gate="editor"
        ActiveEditorDialog := {Label:"fixture"}
    if gate="refresh"
        PaletteRefresh.Active := true
    if gate="transfer"
        SettingsTransferActive := true
    Assert(!EnqueueConfiguredShortcut("shared1",123) && !ShortcutCommands.Length,"unrelated editing/update is not queued: " gate)
    ActiveEditorDialog := false, PaletteRefresh.Active := false, SettingsTransferActive := false
}

for selectionChange in ["profile","auto"] {
    ResetQueue("")
    Critical("On")
    try {
        SaveInputProfileId("fixture-profile")
        EnqueueConfiguredShortcut("profile1",123)
        if selectionChange="profile"
            SaveInputProfileId("")
        else
            AutoMode := true
        DrainShortcutQueue()
        Assert(!Sent.Length && !ShortcutCommands.Length,"manual profile/mode cannot change a queued selection: " selectionChange)
    } finally Critical("Off")
}
ResetQueue("")
AutoMode := true
RuntimePorts.ResolveChannel := (*) => {State:"ok",Author:"fixture",Channel:"/channel/fixture",Video:"abcdefghijk"}
RunQueue(["chat_focus","profile1","shared2"])
Assert(Sent.Length=2 && Sent[1]="test-one" && Sent[2]="second draft","auto selection uses the queued library and pinned video")

for name in ["reaction_context_failed","reaction_failed","reaction_partial","reaction_cancelled"] {
    ResetQueue(name)
    DefaultReactionCount := name="reaction_partial" ? 2 : 1
    RunQueue(["reaction","shared1"])
    Assert(!Sent.Length && !ShortcutCommands.Length && !ActiveReactionJob,"reaction failure/cancellation stops its tail: " name)
    if name="reaction_partial"
        Assert(LastReactionResult.Completed=1 && LastReactionResult.Reason="unknown","partial reaction outcome is retained without replay")
}
ResetQueue("")
Assert(!EnqueueConfiguredShortcut("shared1",456),"shortcut rejects a different foreground window")
'@ -Helpers @'
RunQueue(actions) {
    Critical(23)
    try {
        for action in actions
            Assert(EnqueueConfiguredShortcut(action,123),"shortcut command is accepted: " action)
        DrainShortcutQueue()
        Assert(A_IsCritical=23,"queue restores caller interruption policy")
    } finally Critical("Off")
}
ResetQueue(testScenario) {
    global ActiveEditorDialog, PaletteRefresh, SettingsTransferActive, IsBrowserOperationBusy, AutoMode, DefaultReactionCount
    global Scenario := testScenario, ForegroundOk := true, Sent := [], Effects := [], BrowserCalls := [], Injected := false
    global FocusToken := "", FocusConsumed := false, FocusCount := 0, SendAttempts := 0, ReactionCalls := 0
    global QueueVideo := "abcdefghijk", QueueClock := 1000, CancelOnValidation := false
    CancelReaction()
    ActiveEditorDialog := false, PaletteRefresh.Active := false, SettingsTransferActive := false, IsBrowserOperationBusy := false
    AutoMode := false, DefaultReactionCount := 1
    CommitTestLibraryChange(BaseLibrary,"queue reset")
    SaveInputProfileId("fixture-profile")
}
JoinQueueEffects() {
    joined := ""
    for effect in Effects
        joined .= (joined="" ? "" : "|") effect
    return joined
}
QueueText(text) {
    global SendAttempts
    SendAttempts++
    if Scenario="send_unknown"
        throw Error("Unknown native send")
    Sent.Push(text), Effects.Push(text)
}
QueueClear() {
    Effects.Push("clear")
}
ReadQueueText(item) {
    global CancelOnValidation
    if CancelOnValidation {
        CancelOnValidation := false
        HandleConfiguredShortcut("stop")
    }
    return OriginalQueueText
}
QueueRequest(hwnd,mode,video,extra) {
    global Injected, FocusToken, FocusConsumed, FocusCount, QueueClock, ForegroundOk, CancelOnValidation, ReactionCalls
    global ActiveEditorDialog, ActiveReactionJob, IsBrowserOperationBusy
    BrowserCalls.Push(mode)
    if mode="browser_context" {
        if Scenario="reaction_context_failed" && ActiveReactionJob
            return {State:"unavailable",Video:""}
        changed := FocusCount && (Scenario="changed_video" || Scenario="missing_video")
        return {State:"ok",Video:changed ? (Scenario="missing_video" ? "" : "ABCDEFGHIJK") : QueueVideo}
    }
    if mode="chat_focus" {
        Effects.Push("focus"), FocusCount++
        FocusToken := "proof-" FocusCount, FocusConsumed := false
        if Scenario="inject" && !Injected {
            Injected := true
            IsBrowserOperationBusy := true
            try {
                for action in ["shared1","shared2","shared1"]
                    Assert(EnqueueConfiguredShortcut(action,hwnd),"callback can append another key")
                DrainShortcutQueue()
                Assert(ShortcutCommands.Length=3 && !Sent.Length,"reentrant drain cannot overtake current operation")
            } finally IsBrowserOperationBusy := false
        }
        if Scenario="stop_new_session" || Scenario="throw_new_session" {
            HandleConfiguredShortcut("stop")
            Assert(EnqueueConfiguredShortcut("shared2",hwnd),"new session is accepted during old cleanup")
            if Scenario="throw_new_session"
                throw Error("Old request failed")
        }
        if Scenario="long_wait"
            QueueClock += 6000
        if Scenario="background"
            ForegroundOk := false
        if Scenario="request_throw"
            throw Error("Focus request failed")
        return {State:Scenario="focus_failed" ? "focus_failed" : "focused",Video:QueueVideo,Detail:Scenario="missing_token" ? "" : FocusToken}
    }
    if mode="verify_input" || mode="verify_chat" {
        if mode="verify_chat" {
            if FocusConsumed || extra!="FocusToken=" FocusToken
                return {State:"wrong_input",Video:video}
            FocusConsumed := true
        }
        if Scenario="background_after_verify"
            ForegroundOk := false
        if Scenario="edited" {
            for item in SharedDanmakuItems
                if item.Slot=1 {
                    ExecuteDanmakuCommand("edit","",item.Id,{Name:item.Name,Text:"modified",Slot:1})
                    break
                }
        }
        if Scenario="editor"
            ActiveEditorDialog := {Label:"fixture"}
        if Scenario="reaction_gate"
            ActiveReactionJob := CreateReactionJob({Mode:"queued"})
        if Scenario="cancel_final_validation"
            CancelOnValidation := true
        return {State:(Scenario="changed_field" || Scenario="show_changed_field") ? "wrong_input" : "ok",
            Video:Scenario="verified_video_changed" ? "ABCDEFGHIJK" : (Scenario="verified_video_empty" ? "" : video)}
    }
    if mode="reactions_show" {
        Effects.Push("show")
        return {State:"hovered",Video:QueueVideo}
    }
    if mode="reaction_send" {
        ReactionCalls++
        if Scenario="reaction_failed" || (Scenario="reaction_partial" && ReactionCalls=2)
            return {State:"unknown"}
        Effects.Push("reaction")
        if Scenario="reaction_cancelled"
            HandleConfiguredShortcut("stop")
        return {State:"operated"}
    }
    throw Error("Unexpected queue request: " mode)
}
'@
