# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    global PageCalls := [], ClearCalls := 0, PageForeground := true, PageFailure := "", PageSwitch := false
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
    for state in ["wrong_input","changed","unavailable","unknown"] {
        PageFailure := state, PageCalls := []
        Assert(!RunPageAction("chat_clear",123) && ClearCalls=1,"failed verification prevents deletion: " state)
    }
    Assert(LastBrowserOperation.Mode="chat_clear" && LastBrowserOperation.Stage="クリア前の確認","failure retains action and failed stage")
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
    EditReactionKey()
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
    PageCalls.Push({Mode:mode,Video:video})
    if mode="chat_focus"
        return {State:"focused",Video:"abcdefghijk"}
    if mode="verify_chat" {
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
