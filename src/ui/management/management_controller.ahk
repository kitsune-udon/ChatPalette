; GUI adapters select the target once, call a service, then render the result.
GetEditingProfileId() {
    return FindProfileById(Profiles,EditingProfileId) ? EditingProfileId : ""
}
; Capture the validated item and its owner together; callers must not resolve the row again.
GetSelectedManagedTarget() {
    index := ManagedList.GetNext()
    if !index
        return 0
    message := "一覧を更新しました。操作する弾幕を選び直してください。"
    try {
        items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},EditingProfileId)
        if index <= items.Length && items[index].Id == ManagedList.GetText(index,4)
            return {ProfileId:EditingProfileId, Index:index, Item:items[index]}
    } catch as failure {
        message := failure.Message
    }
    RefreshManagement()
    ManagedList.Modify(0,"-Select")
    UpdateManagementActions()
    SetManagementNotice(message)
    return 0
}
RefreshManagementAfterCommand(editId, message := "変更は保存済みです。", updateManagement := 0) {
    global EditingProfileId := FindProfileById(Profiles,editId) ? editId : ""
    try {
        RefreshLibraryViews(updateManagement)
        SetManagementNotice(message)
    } catch as failure {
        SetManagementNotice("変更は保存済みです。画面を更新できませんでした。`n" failure.Message)
    }
}
HandleDanmakuCommand(action, *) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        ; Keep the saved result and its selection visible before the next edit enters.
        if !OperationAllowed("edit")
            return
        selected := GetSelectedManagedTarget()
        if !selected
            return
        try result := ExecuteDanmakuCommand(action,selected.ProfileId,selected.Item.Id)
        catch as failure {
            SetManagementNotice("保存できませんでした。" failure.Message)
            return
        }
        if !result
            return
        updateManagement := action = "up" || action = "down"
            ? RenderManagedOrder.Bind(selected.Index,result.Index) : RenderManagedSelection.Bind(result.Index)
        RefreshManagementAfterCommand(selected.ProfileId,result.Label "：保存済み",updateManagement)
    } finally Critical(previousCritical)
}
UndoLibraryChange(*) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !OperationAllowed("edit")
            return
        editId := GetEditingProfileId()
        try label := UndoLibraryCommand()
        catch as failure {
            SetManagementNotice("取り消しを保存できませんでした。" failure.Message)
            return
        }
        if label != ""
            RefreshManagementAfterCommand(editId,label "を取り消しました。")
    } finally Critical(previousCritical)
}
ManageProfile(action, *) {
    if !OperationAllowed("edit")
        return
    if action = "bind"
        return OpenChannelLinkDialog(EditingProfileId)
    try {
        BeginEditorDialog(ManagementWindow,"配信者の編集")
        RunProfileDialog(action)
    }
    finally EndEditorDialog(ManagementWindow)
}
RunProfileDialog(action) {
    profile := FindProfileById(Profiles,EditingProfileId)
    editId := profile ? profile.Id : ""
    if action != "add" && !profile
        return
    value := ""
    ManagementWindow.Opt("+OwnDialogs")
    if action = "add" || action = "rename" {
        answer := InputBox("このツール内で表示する配信者名",action = "add" ? "配信者を追加" : "配信者名を変更","w360 h140",action = "add" ? "" : profile.Name)
        if answer.Result != "OK"
            return
        value := answer.Value
    } else if action = "delete" {
        if MsgBox("「" profile.Name "」と弾幕 " profile.Items.Length "件を削除します。履歴から取り消せます。","配信者を削除","YesNo Default2") != "Yes"
            return

    }
    try result := ExecuteProfileCommand(action,editId,value)
    catch as failure {
        SetManagementNotice("保存できませんでした。" failure.Message)
        return
    }
    if action = "add"
        editId := result.ProfileId
    RefreshManagementAfterCommand(editId,result.Label "：保存済み")
}


ChangeManagementTarget(*) {
    if !OperationAllowed("edit")
        return
    try id := GetSelectedProfileId(ManagementTarget)
    catch as failure {
        RefreshManagement()
        SetManagementNotice(failure.Message)
        return
    }
    global EditingProfileId := id
    RefreshManagement()
}

SaveReactionDefaultsFromControls(*) {
    if !OperationAllowed("preferences") {
        RefreshReactionDefaultControls()
        ReactionDefaultsStatusControl.Text := "実行が終わってから変更してください。"
        return
    }
    draft := CreateReactionOptions(ReactionDefaultChoiceControl.Value,ReactionCounts[ReactionDefaultCountControl.Value],ReactionIntervals[ReactionDefaultIntervalControl.Value])
    try SaveReactionDefaults(draft)
    catch as failure {
        RefreshReactionDefaultControls()
        ReactionDefaultsStatusControl.Text := "保存できませんでした。" failure.Message
        return
    }
    RefreshReactionDefaultControls()
}

PrepareReaction(mode) {
    if !OperationAllowed("reaction") {
        SetManagementNotice("現在の処理・編集を終了してから実行してください。")
        return
    }
    if ScheduleReaction(mode,mode = "reaction_capture" ? 0 : 5)
        ManagementWindow.Hide()
    else
        SetManagementNotice(ReactionExecutionStatus.Message)
}

ReturnToPalette(*) {
    if RestoreActiveEditorDialog() || CurrentOperationState().BrowserBusy
        return
    RefreshPaletteForTarget()
    ManagementWindow.Hide()
    ShowFittedWindow(PaletteWindow,560,740,ResizePalette)
}

LoadDefaultsAndReturn(*) {
    if ActiveReactionJob || CurrentOperationState().BrowserBusy
        return
    ResetPaletteSession()
    ReturnToPalette()
}

RefreshReactionRegistration(*) {
    if !IsSet(ReactionRegistrationLabel)
        return
    process := ReadBrowserProcessName(TargetBrowserHwnd)
    if !BrowserNames().Has(process) {
        ReactionRegistrationLabel.Text := "対象ブラウザー：未選択`nYouTubeから" ShortcutKeyLabel(GetShortcutKey("palette")) "で開いてください。"
        return
    }
    ; Saved registration is local state; recognition and synchronization belong to actions.
    try registered := HasReactionRegistration(SubStr(process,1,-4)) ; Remove the known .exe suffix.
    catch as failure {
        ReactionRegistrationLabel.Text := "設定状態：未確認`n" failure.Message
        return
    }
    ReactionRegistrationLabel.Text := registered
        ? "設定済み（メニューの認識は未確認）`n②で確認。開始後、♡にマウスを重ねます。"
        : "未設定：①から始めてください。`n開始後、YouTubeの♡にマウスを重ねます。"
}
