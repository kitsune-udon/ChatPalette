; GUI adapters select the target once, call a service, then render the result.
GetEditingProfileId() {
    return FindProfileById(Profiles,EditingProfileId) ? EditingProfileId : ""
}
GetEditingDanmakuItems() {
    return GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},GetEditingProfileId())
}
RefreshManagementAfterCommand(editId) {
    global EditingProfileId := FindProfileById(Profiles,editId) ? editId : ""
    RefreshVisiblePalette()
    RefreshManagement()
}
HandleDanmakuCommand(action, *) {
    if !OperationAllowed("edit")
        return
    index := ManagedList.GetNext()
    if !index
        return
    editId := GetEditingProfileId()
    try result := ExecuteDanmakuCommand(action,editId,index)
    catch as failure {
        SetManagementNotice("保存できませんでした。" failure.Message)
        return
    }
    if !result
        return
    if action = "up" || action = "down" {
        RefreshManagedOrder(index,result.Index)
        RefreshVisiblePalette()
    } else {
        RefreshManagementAfterCommand(editId)
        SelectManagedRow(result.Index)
    }
    SetManagementNotice(result.Label "：保存済み")
}
UndoLibraryChange(*) {
    if !OperationAllowed("edit")
        return
    editId := GetEditingProfileId()
    try label := UndoLibraryCommand()
    catch as failure {
        SetManagementNotice("取り消しを保存できませんでした。" failure.Message)
        return
    }
    RefreshManagementAfterCommand(editId)
    if label != ""
        SetManagementNotice(label "を取り消しました。")
}
ManageProfile(action, *) {
    if !OperationAllowed("edit")
        return
    BeginEditorDialog(ManagementWindow,"配信者の編集")
    try RunProfileDialog(action)
    finally EndEditorDialog()
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
    } else if action = "bind" {
        if !IsBrowser(TargetBrowserHwnd) {
            SetManagementNotice("YouTubeからパレットを開き直してください。")
            return
        }
        candidate := ResolveBrowserChannel(TargetBrowserHwnd)
        if candidate.State != "ok" {
            SetManagementNotice("チャンネルを取得できませんでした。YouTubeから開き直してください。")
            return
        }
        if MsgBox("YouTubeのチャンネル「" candidate.Author "」で、配信者「" profile.Name "」の弾幕を自動選択します。`n`n現在：" (profile.Channel != "" ? profile.Channel : "未連携") "`n変更後：" candidate.Channel "`n以前の連携はこのチャンネルに置き換わります。`n`n連携しますか？","チャンネル連携の確認","YesNo") != "Yes"
            return
        fresh := ResolveBrowserChannel(TargetBrowserHwnd)
        if fresh.State != "ok" || fresh.Channel != candidate.Channel {
            SetManagementNotice("チャンネルが変わりました。もう一度連携してください。")
            return
        }
        value := candidate.Channel
    }
    try result := ExecuteProfileCommand(action,editId,value)
    catch as failure {
        SetManagementNotice("保存できませんでした。" failure.Message)
        return
    }
    if action = "add"
        editId := result.ProfileId
    RefreshManagementAfterCommand(editId)
    SetManagementNotice(result.Label "：保存済み")
}


ChangeManagementTarget(*) {
    if !OperationAllowed("edit")
        return
    global EditingProfileId := ManagementTarget.Value > 1 ? Profiles[ManagementTarget.Value-1].Id : ""
    RefreshManagement()
}

SaveReactionDefaultsFromControls(*) {
    if !OperationAllowed("preferences") {
        RefreshReactionDefaultControls()
        ReactionDefaultsStatusControl.Text := "実行が終わってから変更してください。"
        return
    }
    draft := CreateReactionOptions(ReactionDefaultChoiceControl.Value,ReactionCounts[ReactionDefaultCountControl.Value],ReactionIntervals[ReactionDefaultIntervalControl.Value],ShortcutKeys["reaction"])
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
    if RestoreActiveEditorDialog() || IsBrowserOperationBusy
        return
    RefreshPaletteForTarget()
    ManagementWindow.Hide()
    ShowFittedWindow(PaletteWindow,560,740,ResizePalette)
}

LoadDefaultsAndReturn(*) {
    if ActiveReactionJob || IsBrowserOperationBusy
        return
    ResetPaletteSession()
    ReturnToPalette()
}

RefreshReactionRegistration(*) {
    if !IsSet(ReactionRegistrationLabel)
        return
    if !IsBrowser(TargetBrowserHwnd) {
        ReactionRegistrationLabel.Text := "対象ブラウザー：未選択`nYouTubeから" ShortcutKeyLabel(GetShortcutKey("palette")) "で開いてください。"
        return
    }
    if !OperationAllowed("preferences") {
        ReactionRegistrationLabel.Text := "設定状態：未確認（処理中）`n終了後、このタブを開き直してください。"
        return
    }
    result := RequestBrowserOperation(TargetBrowserHwnd,"reaction_status")
    ReactionRegistrationLabel.Text := result.State = "configured"
        ? "設定済み（メニューの認識は未確認）`n②で確認。開始後、♡にマウスを重ねます。"
        : result.State = "not_registered" ? "未設定：①から始めてください。`n開始後、YouTubeの♡にマウスを重ねます。"
        : "設定状態：未確認`nYouTubeからパレットを開き直してください。"
}
