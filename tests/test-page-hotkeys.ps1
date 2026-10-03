# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$body = @'
global HotkeyCalls := [], QueueKeys := false, QueuedBeforeResponse := false
global FixtureBrowser := Gui(,"ChatPalette isolated page shortcut test")
global FixtureChat := FixtureBrowser.AddEdit("w320","unsent fixture text")
other := FixtureBrowser.AddButton("w160","Another control")
RuntimePorts.BrowserProcessName := (hwnd) => (hwnd=FixtureBrowser.Hwnd) ? "chrome.exe" : ""
RuntimePorts.BrowserRequest := ShortcutFixtureRequest
InstallApplicationShortcuts()
PresentWindow(FixtureBrowser)
RequireTestWindowActive(FixtureBrowser.Hwnd)
other.Focus()
SendLevel(1)
SetKeyDelay(40,40)
for entry in [["f",2,"chat_focus","focused"],["w",5,"chat_clear","cleared"],["r",7,"reactions_show","hovered"]] {
    SendTestKeys("{Control DownR}{Alt DownR}" entry[1] "{Alt up}{Control up}")
    deadline := A_TickCount+3000
    ; Key dispatch can finish before the edit processes the queued deletion.
    while (HotkeyCalls.Length<entry[2] || LastBrowserOperation.Mode!=entry[3] || LastBrowserOperation.State!=entry[4]
        || (entry[1]="w" && FixtureChat.Value!="")) && A_TickCount<deadline
        Sleep(10)
    Assert(HotkeyCalls.Length=entry[2] && LastBrowserOperation.State=entry[4],"real binding dispatches " entry[1] " calls=" HotkeyCalls.Length " state=" LastBrowserOperation.State " active=" (!!WinActive("ahk_id " FixtureBrowser.Hwnd)))
    if entry[1]="f" {
        focused := DllCall("GetFocus","Ptr")=FixtureChat.Hwnd
        unchanged := FixtureChat.Value="unsent fixture text"
        Assert(focused && unchanged,"F focuses without modifying draft; focused=" focused " unchanged=" unchanged
            . " active=" (!!WinActive("ahk_id " FixtureBrowser.Hwnd)) " operation_active=" (!!ActivePageAction))
    }
    if entry[1]="w"
        Assert(FixtureChat.Value="" && HotkeyCalls[4].Mode="chat_focus" && HotkeyCalls[5].Mode="verify_chat","W clears only isolated edit after verification; empty=" (FixtureChat.Value="") " modes=" HotkeyCalls[4].Mode "/" HotkeyCalls[5].Mode)
    if entry[1]="r"
        Assert(HotkeyCalls[7].Mode="reactions_show","R selects non-sending page operation")
}
Assert(HotkeyCalls[5].Video="abcdefghijk","verification uses the focused page's video")
; Exercise production delivery in our own edit, including literal AHK syntax.
FixtureChat.Focus()
literal := "日本語の弾幕 {Enter} ^!+#"
result := SendInputText(literal)
Sleep(100)
Assert(result.State="inserted" && FixtureChat.Value=literal,"IME-off delivery preserves Unicode and literal key syntax")
for character in [Chr(8),Chr(9),Chr(10),Chr(13)] {
    FixtureChat.Value := "unchanged", FixtureChat.Focus()
    result := SendInputText("prefix" character "suffix")
    Sleep(50)
    Assert(result.State="invalid_text","control character is rejected before native input: " Ord(character) " state=" result.State " text=" FixtureChat.Value)
    Assert(FixtureChat.Value="unchanged" && DllCall("GetFocus","Ptr")=FixtureChat.Hwnd,"rejected text changes neither content nor focus")
}
ShowInputFailure("invalid_text")
Assert(InStr(PaletteHint.Text,"制御文字") && InStr(PaletteHint.Text,"弾幕を編集"),"invalid text explains how to correct the stored body")
ExecuteDanmakuCommand("add","","",{Name:"queued",Text:"queued text",Slot:1})
AutoMode := false
; Exercise native text and clear with modifiers held, including repeat-down and
; the next shortcut after Send temporarily releases/restores modifier state.
for modifiers in ["Alt", "Shift"] {
    heldKeys := CurrentShortcutMap()
    prefix := modifiers="Alt" ? "^!" : "^+"
    heldKeys["chat_focus"] := prefix "f", heldKeys["chat_clear"] := prefix "c"
    heldKeys["shared1"] := prefix "3"
    SaveShortcutMap(heldKeys)
    FixtureChat.Value := "draft", FixtureChat.Focus()
    SendMessage(0xB1,1,3,FixtureChat.Hwnd)
    before := HotkeyCalls.Length
    SendTestKeys("{Control DownR}{" modifiers " DownR}{3 down}")
    Loop 3
        SendTestKeys("{3 down}")
    Sleep(150)
    selection := FixtureSelection()
    Assert(HotkeyCalls.Length=before && FixtureChat.Value="draft" && selection[1]=1 && selection[2]=3
        && DllCall("GetFocus","Ptr")=FixtureChat.Hwnd,"held/repeated main key neither executes nor leaks: " modifiers)
    SendTestKeys("{3 up}")
    deadline := A_TickCount+3000
    while FixtureChat.Value!="dqueued textft" && A_TickCount<deadline
        Sleep(10)
    Assert(FixtureChat.Value="dqueued textft" && HotkeyCalls.Length=before+3,"main KeyUp inserts exactly once with held modifiers: " modifiers)
    Assert(WaitFixtureModifiers(modifiers),"native text restores held modifiers: " modifiers " ctrl=" GetKeyState("Control") " modifier=" GetKeyState(modifiers))
    before := HotkeyCalls.Length
    SendTestKeys("{c down}")
    Sleep(100)
    Assert(HotkeyCalls.Length=before && FixtureChat.Value="dqueued textft","clear waits for main KeyUp: " modifiers)
    SendTestKeys("{c up}")
    deadline := A_TickCount+3000
    while FixtureChat.Value!="" && A_TickCount<deadline
        Sleep(10)
    Assert(FixtureChat.Value="" && HotkeyCalls.Length=before+3,"native clear works with held modifiers: " modifiers " text=" FixtureChat.Value " calls=" (HotkeyCalls.Length-before) " state=" LastBrowserOperation.State " ctrl=" GetKeyState("Control") " alt=" GetKeyState("Alt"))
    Assert(WaitFixtureModifiers(modifiers),"native clear restores held modifiers: " modifiers " ctrl=" GetKeyState("Control") " modifier=" GetKeyState(modifiers))
    SendTestKeys("3")
    deadline := A_TickCount+3000
    while FixtureChat.Value!="queued text" && A_TickCount<deadline
        Sleep(10)
    Assert(FixtureChat.Value="queued text" && HotkeyCalls.Length=before+6,"next shortcut uses the same held modifiers: " modifiers)
    SendTestKeys("{" modifiers " up}{Control up}")
}
SaveShortcutMap(DefaultShortcutKeys())
; A captured chord still completes when modifiers are released first.
before := HotkeyCalls.Length
SendTestKeys("{Control DownR}{Alt DownR}{f down}{Alt up}{Control up}")
Sleep(100)
Assert(HotkeyCalls.Length=before,"modifier release alone does not execute")
SendTestKeys("{f up}")
Sleep(150)
Assert(HotkeyCalls.Length=before+2,"modifier-first release still executes on main KeyUp")
; Remapping a function key has the same release semantics and removes the old key.
heldKeys := CurrentShortcutMap(), heldKeys["chat_focus"] := "^+F12"
SaveShortcutMap(heldKeys)
before := HotkeyCalls.Length
SendTestKeys("{Control DownR}{Shift DownR}{F12 down}")
Sleep(100)
Assert(HotkeyCalls.Length=before,"function key waits for KeyUp")
SendTestKeys("{F12 up}")
Sleep(150)
Assert(HotkeyCalls.Length=before+2,"remapped function KeyUp executes with modifiers held")
SendTestKeys("{Shift up}{Control up}")
SaveShortcutMap(DefaultShortcutKeys())
before := HotkeyCalls.Length
SendTestKeys("{Control DownR}{Alt DownR}{t down}")
Sleep(100)
Assert(!ActiveReactionJob && HotkeyCalls.Length=before,"reaction does not start on KeyDown")
SendTestKeys("{t up}")
deadline := A_TickCount+3000
while (LastReactionResult.Reason!="completed" || ActiveReactionJob) && A_TickCount<deadline
    Sleep(10)
Assert(!ActiveReactionJob && LastReactionResult.Reason="completed" && LastReactionResult.Completed=1
    && HotkeyCalls.Length=before+3,"reaction starts once on KeyUp with held modifiers")
SendTestKeys("{Alt up}{Control up}")
HotkeyCalls.RemoveAt(8,HotkeyCalls.Length-7)
global QueueSent := []
RuntimePorts.Text := (text) => QueueSent.Push(text)
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second text",Slot:2})
AutoMode := false, QueueKeys := true
before := HotkeyCalls.Length
SendTestKeys("{Control DownR}{Alt DownR}f")
deadline := A_TickCount+4000
while (QueueSent.Length<3 || ActivePageAction || ActiveShortcutCommand || ShortcutCommands.Length) && A_TickCount<deadline
    Sleep(10)
Assert(QueuedBeforeResponse && QueueSent.Length=3 && QueueSent[1]="queued text" && QueueSent[2]="second text" && QueueSent[3]="queued text" && !ActivePageAction,"real F then repeated danmaku keys are delivered in order; queued=" QueuedBeforeResponse " sent=" QueueSent.Length " calls=" (HotkeyCalls.Length-before) " operation=" LastBrowserOperation.Mode "/" LastBrowserOperation.State " focusing=" (!!ActivePageAction) " active=" (!!WinActive("ahk_id " FixtureBrowser.Hwnd)))
Assert(HotkeyCalls.Length=before+11 && HotkeyCalls[-1].Mode="verify_input","queued native shortcuts wait for prior completion and verification")
Assert(GetKeyState("Control") && GetKeyState("Alt"),"F then danmaku keeps modifiers held")
SendTestKeys("{Alt up}{Control up}")
QueueKeys := false
HotkeyCalls.RemoveAt(8,HotkeyCalls.Length-7)
remapped := CurrentShortcutMap(), remapped["chat_focus"] := "^+j"
SaveShortcutMap(remapped)
SendTestKeys("{Control DownR}{Shift DownR}j{Shift up}{Control up}")
deadline := A_TickCount+3000
while HotkeyCalls.Length<9 && A_TickCount<deadline
    Sleep(10)
Assert(HotkeyCalls.Length=9 && HotkeyCalls[9].Mode="chat_focus","remapped key dispatches production action")
SendTestKeys("{Control DownR}{Alt DownR}f{Alt up}{Control up}")
Sleep(150)
Assert(HotkeyCalls.Length=9,"old key is removed after remapping")
RuntimePorts.BrowserProcessName := (hwnd) => ""
SendTestKeys("{Control DownR}{Shift DownR}j{Shift up}{Control up}")
Sleep(150)
Assert(HotkeyCalls.Length=9,"remapped page key remains browser-only")
SendTestKeys("{Control DownR}{Alt DownR}{q down}")
Sleep(100)
Assert(!DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd),"palette does not open on KeyDown")
SendTestKeys("{q up}")
Sleep(150)
Assert(DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd),"palette key remains available outside browsers")
SendTestKeys("{Alt up}{Control up}")
remapped["stop"] := "^+s"
SaveShortcutMap(remapped)
global ActiveReactionJob := CreateReactionJob({Mode:"queued"})
SendTestKeys("{Control DownR}{Shift DownR}{s down}")
Sleep(150)
Assert(!ActiveReactionJob,"remapped stop key cancels on KeyDown outside browsers")
SendTestKeys("{s up}{Shift up}{Control up}")
FixtureBrowser.Destroy()
FileAppend("PASS: " Checks " actual key dispatch checks; only an isolated edit was cleared`n","*")
ExitApp()
ShortcutFixtureRequest(hwnd,mode,video,extra) {
    global QueuedBeforeResponse
    HotkeyCalls.Push({Mode:mode,Video:video})
    if mode="chat_focus" {
        if QueueKeys {
            SetTimer(SendQueuedKeys,-20)
            deadline := A_TickCount+3000
            while ShortcutCommands.Length<3 && A_TickCount<deadline
                Sleep(10)
            QueuedBeforeResponse := ShortcutCommands.Length=3
        }
        FixtureChat.Focus()
        return {State:"focused",Video:"abcdefghijk",Detail:"fixture-token"}
    }
    if mode="browser_context"
        return {State:"ok",Video:"abcdefghijk"}
    if mode="reaction_send"
        return {State:"operated"}
    if mode="verify_chat" || mode="verify_input"
        return {State:DllCall("GetFocus","Ptr")=FixtureChat.Hwnd ? "ok" : "wrong_input",Video:video}
    if mode="reactions_show"
        return {State:"hovered",Video:"abcdefghijk"}
    throw Error("Unexpected browser operation: " mode)
}
; DownR lets native Send release/restore modifiers as with physical input.
; Emit each test batch before dispatching its hook callbacks. Otherwise
; the test driver itself can be suspended with synthetic modifiers still down.
SendTestKeys(keys) {
    previousCritical := A_IsCritical
    Critical("On")
    try SendEvent("{Blind}" keys)
    finally Critical(previousCritical)
    Sleep(-1)
}
FixtureSelection() {
    start := Buffer(4), finish := Buffer(4)
    SendMessage(0xB0,start.Ptr,finish.Ptr,FixtureChat.Hwnd)
    return [NumGet(start,0,"UInt"),NumGet(finish,0,"UInt")]
}
WaitFixtureModifiers(modifier) {
    ; Text updates can be processed before the trailing modifier restoration.
    started := A_TickCount, initialControl := GetKeyState("Control"), initialModifier := GetKeyState(modifier)
    deadline := started+1000
    while (!GetKeyState("Control") || !GetKeyState(modifier)) && A_TickCount<deadline
        Sleep(10)
    if !initialControl || !initialModifier
        FileAppend("INFO: modifier restoration observed after " (A_TickCount-started) " ms; initial ctrl=" initialControl " " modifier "=" initialModifier "`n","*")
    return GetKeyState("Control") && GetKeyState(modifier)
}
SendQueuedKeys() {
    SendLevel(1)
    for key in ["3","4","3"]
        SendTestKeys(key)
}
'@
Invoke-AppTest -Runtime $release -Body $body
