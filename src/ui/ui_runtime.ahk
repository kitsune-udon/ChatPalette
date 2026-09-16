ChooseSetting(control, values, selected) {
    for i, value in values
        if value = selected
            control.Choose(i)
}





BeginWorkerWait(mode) {
    enabled := !!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)
    managerEnabled := ManagementWindow && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)
    PaletteWindow.Opt("+Disabled")
    if ManagementWindow
        ManagementWindow.Opt("+Disabled")
    notification := () => ToolTip(mode = "verify_input" ? "入力欄を確認しています…" : "YouTubeの操作対象を確認しています…")
    SetTimer(notification,-400)
    return {Enabled:enabled, ManagerEnabled:managerEnabled, Notification:notification}
}

EndWorkerWait(view) {
    SetTimer(view.Notification,0)
    if view.Enabled
        PaletteWindow.Opt("-Disabled")
    if view.ManagerEnabled
        ManagementWindow.Opt("-Disabled")
    ToolTip()
}

ShowInputFailure() {
    PaletteHint.Text := "入力できませんでした。YouTubeのチャット欄かコメント欄をクリックし、Ctrl＋Alt＋Qを押してください。"
    ToolTip(PaletteHint.Text)
    SetTimer(() => ToolTip(),-3500)
}

BeginEditorDialog(view,label) {
    global ActiveEditorDialog
    if ActiveEditorDialog
        throw Error("先に開いている編集画面を閉じてください。")
    ActiveEditorDialog := {Window:view, Label:label,
        PaletteEnabled:!!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),
        ManagementEnabled:!!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)}
    PaletteWindow.Opt("+Disabled"), ManagementWindow.Opt("+Disabled")
}
EndEditorDialog() {
    global ActiveEditorDialog
    if !ActiveEditorDialog
        return
    state := ActiveEditorDialog
    ActiveEditorDialog := 0
    if state.PaletteEnabled
        PaletteWindow.Opt("-Disabled")
    if state.ManagementEnabled
        ManagementWindow.Opt("-Disabled")
}

; Reactivate the existing editor, including native owned dialogs for profile edits.
RestoreActiveEditorDialog() {
    if !ActiveEditorDialog
        return false
    view := ActiveEditorDialog.Window
    hwnd := DllCall("GetLastActivePopup", "Ptr", view.Hwnd, "Ptr")
    if hwnd && DllCall("IsWindowEnabled", "Ptr", hwnd) {
        if hwnd = view.Hwnd
            PresentWindow(view)
        else {
            if WinGetMinMax("ahk_id " hwnd) = -1
                WinRestore("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
        }
    }
    return true
}


IsAppWindow(hwnd) {
    if !hwnd
        return false
    pid := 0
    DllCall("GetWindowThreadProcessId","Ptr",hwnd,"UInt*",&pid)
    return pid = DllCall("GetCurrentProcessId")
}
