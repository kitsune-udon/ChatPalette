; The single tooltip owns one expiry timer; replacement cancels the old expiry.
ShowStatusTip(message := "", duration := 0) {
    static clear := () => ShowStatusTip()
    previousCritical := A_IsCritical
    Critical("On")
    try {
        SetTimer(clear,0)
        ToolTip(message)
        if message != "" && duration > 0
            SetTimer(clear,-duration)
    } finally Critical(previousCritical)
}

ChooseSetting(control, values, selected) {
    for i, value in values
        if value = selected
            control.Choose(i)
}


CreateWorkerWait(mode) {
    return {Enabled:!!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),
        ManagerEnabled:ManagementWindow && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),
        Notification:() => ShowStatusTip(mode = "verify_input" ? "入力欄を確認しています…" : "YouTubeの操作対象を確認しています…")}
}
BeginWorkerWait(view) {
    PaletteWindow.Opt("+Disabled")
    if ManagementWindow
        ManagementWindow.Opt("+Disabled")
    RefreshOperationControls()
    SetTimer(view.Notification,-400)
}

EndWorkerWait(view) {
    SetTimer(view.Notification,0)
    if view.Enabled
        PaletteWindow.Opt("-Disabled")
    if view.ManagerEnabled
        ManagementWindow.Opt("-Disabled")
    ShowStatusTip()
    RefreshOperationControls()
}

ShowInputFailure(state) {
    if state = "unknown" {
        info := BrowserResultInfo(state)
        PaletteHint.Text := info.Summary "。" info.Advice
    } else
        PaletteHint.Text := "入力できませんでした。YouTubeのチャット欄かコメント欄をクリックし、" ShortcutKeyLabel(GetShortcutKey("palette")) "を押してください。"
    ShowStatusTip(PaletteHint.Text,3500)
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
EndEditorDialog(view) {
    global ActiveEditorDialog
    if !ActiveEditorDialog || ActiveEditorDialog.Window != view
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

; Choice identities belong to the displayed labels, even when the live library changes.
SyncProfileChoices(control, choices) {
    sameNames := control.HasOwnProp("ProfileChoices") && control.ProfileChoices.Length = choices.Length
    names := [], snapshot := []
    for i, choice in choices {
        names.Push(choice.Name)
        snapshot.Push({Id:choice.Id,Name:choice.Name})
        if sameNames && !(choice.Name == control.ProfileChoices[i].Name)
            sameNames := false
    }
    if !sameNames {
        control.ProfileChoices := []
        control.Delete()
        control.Add(names)
    }
    control.ProfileChoices := snapshot
    return !sameNames
}

GetSelectedProfileId(control) {
    index := control.Value
    if !control.HasOwnProp("ProfileChoices") || index < 1 || index > control.ProfileChoices.Length
        throw Error("配信者を選び直してください。")
    id := control.ProfileChoices[index].Id
    if id != "" && !FindProfileById(Profiles,id)
        throw Error("選択した配信者が見つかりません。一覧から選び直してください。")
    return id
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

ConfirmEditorDiscard(view,message := "未保存の変更を破棄して閉じますか？") {
    if RuntimePorts.ConfirmDiscard
        return RuntimePorts.ConfirmDiscard.Call(message)
    return MsgBox(message,"未保存の変更","YesNo Default2 Icon? Owner" view.Hwnd) = "Yes"
}
