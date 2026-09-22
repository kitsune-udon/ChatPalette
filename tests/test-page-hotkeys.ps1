# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$body = @'
global HotkeyCalls := [], HotkeyChecks := 0
global FixtureBrowser := Gui(,"ChatPalette isolated page shortcut test")
global FixtureChat := FixtureBrowser.AddEdit("w320","unsent fixture text")
other := FixtureBrowser.AddButton("w160","Another control")
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=FixtureBrowser.Hwnd
RuntimePorts.BrowserRequest := ShortcutFixtureRequest
InstallApplicationShortcuts()
try {
    PresentWindow(FixtureBrowser)
    if !WinWaitActive("ahk_id " FixtureBrowser.Hwnd,,2)
        throw Error("Fixture window could not be activated")
    other.Focus()
    SendLevel(1)
    SetKeyDelay(40,40)
    for entry in [["f",1],["c",3],["e",4]] {
        SendEvent("{Control down}{Alt down}" entry[1] "{Alt up}{Control up}")
        deadline := A_TickCount+3000
        while HotkeyCalls.Length<entry[2] && A_TickCount<deadline
            Sleep(10)
        Sleep(50)
        CheckHotkey(HotkeyCalls.Length=entry[2],"real binding dispatches " entry[1])
        if entry[1]="f"
            CheckHotkey(DllCall("GetFocus","Ptr")=FixtureChat.Hwnd && FixtureChat.Value="unsent fixture text","F focuses without modifying draft")
        if entry[1]="c"
            CheckHotkey(FixtureChat.Value="" && HotkeyCalls[2].Mode="chat_focus" && HotkeyCalls[3].Mode="verify_chat","C clears only isolated edit after verification")
        if entry[1]="e"
            CheckHotkey(HotkeyCalls[4].Mode="reactions_show","E selects non-sending page operation")
    }
    CheckHotkey(HotkeyCalls[3].Video="abcdefghijk","verification uses the focused page's video")
    remapped := CurrentShortcutMap(), remapped["chat_focus"] := "^+j"
    SaveShortcutMap(remapped)
    SendEvent("{Control down}{Shift down}j{Shift up}{Control up}")
    deadline := A_TickCount+3000
    while HotkeyCalls.Length<5 && A_TickCount<deadline
        Sleep(10)
    CheckHotkey(HotkeyCalls.Length=5 && HotkeyCalls[5].Mode="chat_focus","remapped key dispatches production action")
    SendEvent("{Control down}{Alt down}f{Alt up}{Control up}")
    Sleep(150)
    CheckHotkey(HotkeyCalls.Length=5,"old key is removed after remapping")
    RuntimePorts.BrowserIdentity := (hwnd) => false
    SendEvent("{Control down}{Shift down}j{Shift up}{Control up}")
    Sleep(150)
    CheckHotkey(HotkeyCalls.Length=5,"remapped page key remains browser-only")
    SendEvent("{Control down}{Alt down}q{Alt up}{Control up}")
    Sleep(150)
    CheckHotkey(DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd),"palette key remains available outside browsers")
    remapped["stop"] := "^+s"
    SaveShortcutMap(remapped)
    global ActiveReactionJob := CreateReactionJob({Mode:"queued"})
    SendEvent("{Control down}{Shift down}s{Shift up}{Control up}")
    Sleep(150)
    CheckHotkey(!ActiveReactionJob,"remapped stop key cancels queued operation outside browsers")
    FixtureBrowser.Destroy()
    FileAppend("PASS: " HotkeyChecks " actual key dispatch checks; only an isolated edit was cleared`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.Line "`n","**")
    ExitApp(1)
}
ShortcutFixtureRequest(hwnd,mode,video,extra) {
    HotkeyCalls.Push({Mode:mode,Video:video})
    if mode="chat_focus" {
        FixtureChat.Focus()
        return {State:"focused",Video:"abcdefghijk"}
    }
    if mode="verify_chat"
        return {State:DllCall("GetFocus","Ptr")=FixtureChat.Hwnd ? "ok" : "wrong_input",Video:video}
    if mode="reactions_show"
        return {State:"hovered",Video:"abcdefghijk"}
    throw Error("Unexpected browser operation: " mode)
}
CheckHotkey(value,label) {
    global HotkeyChecks
    if !value
        throw Error(label)
    HotkeyChecks++
}
'@
Invoke-AppTest -Runtime $release -Body $body
