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
    RefreshOperationControls()
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
    RefreshOperationControls()
}

ShowInputFailure() {
    PaletteHint.Text := "入力できませんでした。YouTubeのチャット欄かコメント欄をクリックし、" ShortcutKeyLabel(GetShortcutKey("palette")) "を押してください。"
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
    RefreshOperationControls()
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
    RefreshOperationControls()
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

BeginListRefresh(list, keyColumn) {
    selected := list.GetNext()
    state := {Selected:selected, Key:selected ? list.GetText(selected,keyColumn) : "",
        Top:SendMessage(0x1027,0,0,list.Hwnd), Visible:!!(WinGetStyle("ahk_id " list.Hwnd) & 0x10000000)}
    list.Opt("-Redraw")
    return state
}

EndListRefresh(list, state, keyColumn) {
    try {
        count := list.GetCount(), selected := 0
        if state.Selected && state.Selected <= count && list.GetText(state.Selected,keyColumn) == state.Key
            selected := state.Selected
        else if state.Selected {
            Loop count
                if list.GetText(A_Index,keyColumn) == state.Key {
                    selected := A_Index
                    break
                }
        }
        if count
            list.Modify(selected ? selected : 1,"Select Focus")
    } finally {
        list.Opt("+Redraw")
        ; WM_SETREDRAW can expose an inactive tab control. Restore the native
        ; visibility without setting AHK's explicit Hidden flag for future tabs.
        if !state.Visible
            DllCall("ShowWindow","Ptr",list.Hwnd,"Int",0)
    }
    ; Row metrics and the scroll range are current only after redraw is restored.
    if list.GetCount() {
        rect := Buffer(16,0)
        if SendMessage(0x100E,0,rect.Ptr,list.Hwnd) {
            height := NumGet(rect,12,"Int")-NumGet(rect,4,"Int")
            SendMessage(0x1014,0,((selected ? Min(state.Top,count-1) : 0)-SendMessage(0x1027,0,0,list.Hwnd))*height,list.Hwnd)
        }
    }
}

; Compare exact labels before crossing into the native control. No shared mutable cache.
SyncChoiceNames(control, names) {
    same := control.HasOwnProp("ChoiceNames") && control.ChoiceNames.Length = names.Length
    if same {
        for i, name in names {
            if !(name == control.ChoiceNames[i]) {
                same := false
                break
            }
        }
    }
    if same
        return false
    control.Delete()
    control.Add(names)
    control.ChoiceNames := names.Clone()
    return true
}

RefreshOperationControls() {
    canEdit := OperationAllowed("edit"), canReact := OperationAllowed("reaction"), canSave := OperationAllowed("preferences")
    if IsSet(PaletteInsert) {
        PreviewPaletteItem()
        SetControlEnabled(PaletteManageButton,canEdit)
        SetControlEnabled(PaletteBind,canEdit)
        SetControlEnabled(PaletteStart,canReact)
        SetControlEnabled(PaletteDefaults,canSave)
        SetControlEnabled(PaletteMode,canSave)
        SetControlEnabled(PaletteProfile,!AutoMode && Profiles.Length > 0 && canSave)
    }
    if ManagementWindow && IsSet(ManagementItemButtons) {
        UpdateManagementActions()
        RefreshManagementUndo()
        ManagementTarget.Enabled := canEdit
        ManagementAddProfileButton.Enabled := canEdit
        ManagementProfileMenu.Enabled := GetEditingProfileId() != "" && canEdit
        ManagementSupportButtons["key"].Enabled := canEdit
        for key in ["register","check"]
            ManagementSupportButtons[key].Enabled := canReact
        for control in [ReactionDefaultChoiceControl,ReactionDefaultCountControl,ReactionDefaultIntervalControl]
            control.Enabled := canSave
    }
}

; For controls outside tabs only: inactive tabs mask Enabled and retain a separate
; desired state inside AHK. Tab controls must always receive explicit assignments.
SetControlEnabled(control, value) {
    value := !!value
    if control.Enabled != value
        control.Enabled := value
}
SetControlText(control, text) {
    if !(control.Text == text)
        control.Text := text
}
