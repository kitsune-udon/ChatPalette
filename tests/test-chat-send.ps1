# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
global SendCase := "", SendEffects := [], EnterAttempts := 0, SendCalls := [], SendForeground := true
global SendVerified := false, SendProofUsed := false
RuntimePorts.BrowserRequest := MessageRequest
RuntimePorts.Text := (text) => SendEffects.Push(text)
RuntimePorts.SendEnter := MessageEnter
RuntimePorts.Foreground := MessageForeground
AutoMode := false
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second draft",Slot:2})
keys := DefaultShortcutKeys()
Assert(keys.Count=11 && keys["chat_clear"]="^!w" && keys["reactions_show"]="^!r"
    && keys["reaction"]="^!t" && keys["chat_send"]="^!e","new defaults have eleven unique actions")
RunMessages(["shared1","chat_send","shared2"])
Assert(SendEffects.Length=3 && SendEffects[1]=="👏👏👏👏👏👏" && SendEffects[2]="ENTER" && SendEffects[3]="second draft",
    "text, Enter and next text execute in FIFO order")
Assert(EnterAttempts=1 && !ActivePageAction && !ShortcutSession,"Enter is sent exactly once and owners release")
Assert(LastBrowserOperation.Mode="chat_send" && LastBrowserOperation.State="enter_sent"
    && InStr(BrowserResultInfo("enter_sent").Message,"受理は未確認"),"result reports Enter delivery rather than server acceptance")
ResetMessages("")
RunMessages(["chat_focus","chat_send","shared1"])
Assert(SendProofUsed && EnterAttempts=1 && SendEffects.Length=2,"send consumes exact focused-chat proof before next input")
Assert(SendCalls[-1]="verify_input","consumed proof is not reused by the next input")
for name in ["comment","missing_kind","wrong_input","video","missing_video","background","cancel","final_cancel","editor","unknown"] {
    ResetMessages(name)
    RunMessages(["chat_send","shared1"])
    Assert(EnterAttempts=(name="unknown" ? 1 : 0) && !SendEffects.Length,
        "unsafe or unknown send discards its tail without replay: " name)
    Assert(!ShortcutCommands.Length && !ActiveShortcutCommand && !ActivePageAction && !ShortcutSession,
        "failed send releases queue and page ownership: " name)
    if name="unknown"
        Assert(LastBrowserOperation.State="unknown","throwing Enter effect retains unknown outcome")
    ActiveEditorDialog := false
}
'@ -Helpers @'
RunMessages(actions) {
    Critical("On")
    try {
        for action in actions
            Assert(EnqueueConfiguredShortcut(action,123),"message command accepted: " action)
    } finally Critical("Off")
    DrainShortcutQueue()
}
ResetMessages(testCase) {
    global SendCase := testCase, SendEffects := [], EnterAttempts := 0, SendCalls := []
    global SendForeground := true, SendVerified := false, SendProofUsed := false
    CancelReaction()
}
MessageForeground(hwnd) {
    if SendCase="final_cancel" && SendVerified && A_IsCritical
        HandleConfiguredShortcut("stop")
    return SendForeground && hwnd=123
}
MessageEnter() {
    global EnterAttempts
    EnterAttempts++
    if SendCase="unknown"
        throw Error("Enter result unknown")
    SendEffects.Push("ENTER")
}
MessageRequest(hwnd,mode,video,extra) {
    global SendForeground, SendVerified, SendProofUsed, ActiveEditorDialog
    SendCalls.Push(mode)
    if mode="browser_context"
        return {State:"ok",Video:"abcdefghijk"}
    if mode="chat_focus"
        return {State:"focused",Video:"abcdefghijk",Detail:"message-proof"}
    if mode!="verify_chat" && mode!="verify_input"
        throw Error("Unexpected message request: " mode)
    if mode="verify_chat" {
        Assert(!SendProofUsed && extra="FocusToken=message-proof","send verifies the exact one-use proof")
        SendProofUsed := true
    }
    SendVerified := true
    if SendCase="background"
        SendForeground := false
    if SendCase="cancel"
        HandleConfiguredShortcut("stop")
    if SendCase="editor"
        ActiveEditorDialog := {Label:"message fixture"}
    return {State:SendCase="wrong_input" ? "wrong_input" : "ok",
        Video:SendCase="video" ? "ABCDEFGHIJK" : SendCase="missing_video" ? "" : "abcdefghijk",
        Detail:SendCase="comment" ? "comment" : SendCase="missing_kind" ? "" : "chat"}
}
'@

# Real hotkeys and native Enter go only to our isolated edit, never a browser.
Invoke-AppFixture -Body @'
global MessageWindow := Gui(,"ChatPalette isolated Enter target")
global MessageEdit := MessageWindow.AddEdit("w320 r3","unsent fixture text")
global NativeEnters := 0, ModifiedEnters := 0, NativeKind := "chat"
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=MessageWindow.Hwnd
RuntimePorts.Foreground := 0
RuntimePorts.BrowserRequest := NativeMessageRequest
RuntimePorts.ShortcutKey := 0
; The fixture's initial installation used a fake key adapter, so install real hooks now.
ApplicationShortcutsInstalled := false
InstallApplicationShortcuts()
PresentWindow(MessageWindow)
RequireTestWindowActive(MessageWindow.Hwnd)
MessageEdit.Focus()
observer := CallbackCreate(ObserveEnter,,6)
Assert(DllCall("comctl32\SetWindowSubclass","Ptr",MessageEdit.Hwnd,"Ptr",observer,"UPtr",1,"UPtr",0),"observe isolated native Enter")
try {
    SendLevel(1), SetKeyDelay(40,40)
    for modifier in ["Alt","Shift"] {
        keys := CurrentShortcutMap(), keys["chat_send"] := modifier="Alt" ? "^!e" : "^+e"
        SaveShortcutMap(keys)
        before := NativeEnters
        SendMessageKeys("{Control DownR}{" modifier " DownR}{e down}")
        Loop 3
            SendMessageKeys("{e down}")
        Sleep(100)
        Assert(NativeEnters=before,"main key down and repeat do not send Enter: " modifier)
        SendMessageKeys("{e up}")
        deadline := A_TickCount+3000
        while NativeEnters=before && A_TickCount<deadline
            Sleep(10)
        Assert(NativeEnters=before+1 && !ModifiedEnters,"main KeyUp sends bare Enter once: " modifier
            . " count=" (NativeEnters-before) " modified=" ModifiedEnters " state=" LastBrowserOperation.State
            . " focused=" (DllCall("GetFocus","Ptr")=MessageEdit.Hwnd))
        deadline := A_TickCount+1000
        while (!GetKeyState("Control") || !GetKeyState(modifier)) && A_TickCount<deadline
            Sleep(10)
        Assert(GetKeyState("Control") && GetKeyState(modifier),"Enter restores held modifiers: " modifier)
        NativeKind := "comment"
        SendMessageKeys("e")
        Sleep(150)
        Assert(NativeEnters=before+1 && LastBrowserOperation.State="wrong_input","comment never receives Enter: " modifier)
        NativeKind := "chat"
        SendMessageKeys("{" modifier " up}{Control up}")
    }
} finally {
    DllCall("comctl32\RemoveWindowSubclass","Ptr",MessageEdit.Hwnd,"Ptr",observer,"UPtr",1)
    CallbackFree(observer)
    MessageWindow.Destroy()
}
'@ -Helpers @'
NativeMessageRequest(hwnd,mode,video,extra) {
    if mode="browser_context"
        return {State:"ok",Video:"abcdefghijk"}
    if mode="verify_input"
        return {State:DllCall("GetFocus","Ptr")=MessageEdit.Hwnd ? "ok" : "wrong_input",Video:video,Detail:NativeKind}
    throw Error("Unexpected native message request: " mode)
}
ObserveEnter(hwnd,msg,wParam,lParam,id,data) {
    global NativeEnters, ModifiedEnters
    if (msg=0x100 || msg=0x104) && wParam=13 {
        NativeEnters++
        if (DllCall("GetKeyState","Int",0x11,"Short") & 0x8000)
            || (DllCall("GetKeyState","Int",0x12,"Short") & 0x8000)
            || (DllCall("GetKeyState","Int",0x10,"Short") & 0x8000)
            ModifiedEnters++
    }
    return DllCall("comctl32\DefSubclassProc","Ptr",hwnd,"UInt",msg,"UPtr",wParam,"Ptr",lParam,"Ptr")
}
SendMessageKeys(keys) {
    previousCritical := A_IsCritical
    Critical("On")
    try SendEvent("{Blind}" keys)
    finally Critical(previousCritical)
    Sleep(-1)
}
'@
