# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$body = @'
global HotkeyCalls := [], HotkeyChecks := 0, QueueKeys := false, QueuedBeforeResponse := false
global FixtureBrowser := Gui(,"ChatPalette isolated page shortcut test")
global FixtureChat := FixtureBrowser.AddEdit("w320","unsent fixture text")
other := FixtureBrowser.AddButton("w160","Another control")
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=FixtureBrowser.Hwnd
RuntimePorts.BrowserRequest := ShortcutFixtureRequest
InstallApplicationShortcuts()
PresentWindow(FixtureBrowser)
RequireTestWindowActive(FixtureBrowser.Hwnd)
other.Focus()
SendLevel(1)
SetKeyDelay(40,40)
for entry in [["f",1,"chat_focus","focused"],["c",3,"chat_clear","cleared"],["e",4,"reactions_show","hovered"]] {
    SendTestKeys("{Control down}{Alt down}" entry[1] "{Alt up}{Control up}")
    deadline := A_TickCount+3000
    while (HotkeyCalls.Length<entry[2] || LastBrowserOperation.Mode!=entry[3] || LastBrowserOperation.State!=entry[4]) && A_TickCount<deadline
        Sleep(10)
    CheckHotkey(HotkeyCalls.Length=entry[2] && LastBrowserOperation.State=entry[4],"real binding dispatches " entry[1] " calls=" HotkeyCalls.Length " state=" LastBrowserOperation.State " active=" (!!WinActive("ahk_id " FixtureBrowser.Hwnd)))
    if entry[1]="f"
        CheckHotkey(DllCall("GetFocus","Ptr")=FixtureChat.Hwnd && FixtureChat.Value="unsent fixture text","F focuses without modifying draft")
    if entry[1]="c"
        CheckHotkey(FixtureChat.Value="" && HotkeyCalls[2].Mode="chat_focus" && HotkeyCalls[3].Mode="verify_chat","C clears only isolated edit after verification")
    if entry[1]="e"
        CheckHotkey(HotkeyCalls[4].Mode="reactions_show","E selects non-sending page operation")
}
CheckHotkey(HotkeyCalls[3].Video="abcdefghijk","verification uses the focused page's video")
; Exercise production delivery in our own edit, including literal AHK syntax.
FixtureChat.Focus()
literal := "日本語の弾幕 {Enter} ^!+#"
result := SendInputText(literal)
Sleep(100)
CheckHotkey(result.State="inserted" && FixtureChat.Value=literal,"IME-off delivery preserves Unicode and literal key syntax")
ExecuteDanmakuCommand("add","","",{Name:"queued",Text:"queued text",Slot:1})
global QueueSent := []
RuntimePorts.Text := (text) => QueueSent.Push(text)
AutoMode := false, QueueKeys := true
before := HotkeyCalls.Length
SendTestKeys("{Control down}{Alt down}f{Alt up}{Control up}")
deadline := A_TickCount+4000
while (!QueueSent.Length || ActivePageAction) && A_TickCount<deadline
    Sleep(10)
CheckHotkey(QueuedBeforeResponse && QueueSent.Length=1 && QueueSent[1]="queued text" && !ActivePageAction,"real F then danmaku shortcut is delivered once; queued=" QueuedBeforeResponse " sent=" QueueSent.Length " calls=" (HotkeyCalls.Length-before) " operation=" LastBrowserOperation.Mode "/" LastBrowserOperation.State " focusing=" (!!ActivePageAction) " active=" (!!WinActive("ahk_id " FixtureBrowser.Hwnd)))
CheckHotkey(HotkeyCalls.Length=before+3 && HotkeyCalls[-1].Mode="verify_chat","queued native shortcut waits for focus and verification")
QueueKeys := false
HotkeyCalls.RemoveAt(5,HotkeyCalls.Length-4)
remapped := CurrentShortcutMap(), remapped["chat_focus"] := "^+j"
SaveShortcutMap(remapped)
SendTestKeys("{Control down}{Shift down}j{Shift up}{Control up}")
deadline := A_TickCount+3000
while HotkeyCalls.Length<5 && A_TickCount<deadline
    Sleep(10)
CheckHotkey(HotkeyCalls.Length=5 && HotkeyCalls[5].Mode="chat_focus","remapped key dispatches production action")
SendTestKeys("{Control down}{Alt down}f{Alt up}{Control up}")
Sleep(150)
CheckHotkey(HotkeyCalls.Length=5,"old key is removed after remapping")
RuntimePorts.BrowserIdentity := (hwnd) => false
SendTestKeys("{Control down}{Shift down}j{Shift up}{Control up}")
Sleep(150)
CheckHotkey(HotkeyCalls.Length=5,"remapped page key remains browser-only")
SendTestKeys("{Control down}{Alt down}q{Alt up}{Control up}")
Sleep(150)
CheckHotkey(DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd),"palette key remains available outside browsers")
remapped["stop"] := "^+s"
SaveShortcutMap(remapped)
global ActiveReactionJob := CreateReactionJob({Mode:"queued"})
SendTestKeys("{Control down}{Shift down}s{Shift up}{Control up}")
Sleep(150)
CheckHotkey(!ActiveReactionJob,"remapped stop key cancels queued operation outside browsers")
FixtureBrowser.Destroy()
FileAppend("PASS: " HotkeyChecks " actual key dispatch checks; only an isolated edit was cleared`n","*")
ExitApp()
ShortcutFixtureRequest(hwnd,mode,video,extra) {
    global QueuedBeforeResponse
    HotkeyCalls.Push({Mode:mode,Video:video})
    if mode="chat_focus" {
        if QueueKeys {
            SetTimer(SendQueuedKeys,-20)
            deadline := A_TickCount+3000
            while !ActivePageAction.Pending && A_TickCount<deadline
                Sleep(10)
            QueuedBeforeResponse := !!ActivePageAction.Pending
        }
        FixtureChat.Focus()
        return {State:"focused",Video:"abcdefghijk",Detail:"fixture-token"}
    }
    if mode="browser_context"
        return {State:"ok",Video:"abcdefghijk"}
    if mode="verify_chat"
        return {State:DllCall("GetFocus","Ptr")=FixtureChat.Hwnd ? "ok" : "wrong_input",Video:video}
    if mode="reactions_show"
        return {State:"hovered",Video:"abcdefghijk"}
    throw Error("Unexpected browser operation: " mode)
}
; Emit each complete key chord before dispatching its hook callbacks. Otherwise
; the test driver itself can be suspended with synthetic modifiers still down.
SendTestKeys(keys) {
    previousCritical := A_IsCritical
    Critical("On")
    try SendEvent(keys)
    finally Critical(previousCritical)
    Sleep(-1)
}
SendQueuedKeys() {
    SendLevel(1)
    SendTestKeys("{Control down}{Alt down}3{Alt up}{Control up}")
}
CheckHotkey(value,label) {
    global HotkeyChecks
    if !value
        throw Error(label)
    HotkeyChecks++
}
'@
Invoke-AppTest -Runtime $release -Body $body
