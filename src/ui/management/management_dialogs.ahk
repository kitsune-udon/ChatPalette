; Owned editors and their explicit save/cancel lifetime.

OpenDanmakuEditor(isNew) {
    if ManagementUpdating
        return
    global DanmakuEditorWindow
    if IsBrowserOperationBusy || ActiveReactionJob || DanmakuEditorWindow
        return
    index := isNew ? 0 : ManagedList.GetNext()
    if !isNew && !index
        return
    editId := GetEditingProfileId()
    items := GetEditingDanmakuItems(), original := index ? items[index] : {Name:"",Text:"",Slot:0}
    DanmakuEditorWindow := Gui("+Owner" ManagementWindow.Hwnd,"弾幕を" (isNew ? "追加" : "編集"))
    DanmakuEditorWindow.SetFont("s10","Yu Gothic UI")
    DanmakuEditorWindow.AddText("w420","編集対象：" (EditScopeShared ? "共通の弾幕" : Profiles[EditProfileIndex].Name))
    DanmakuEditorWindow.AddText(,"弾幕名")
    name := DanmakuEditorWindow.AddEdit("w420",original.Name)
    DanmakuEditorWindow.AddText(,"本文（1行）")
    text := DanmakuEditorWindow.AddEdit("w420",original.Text)
    DanmakuEditorWindow.AddText(,"キーの割当 — 現在の割当を表示")
    offset := EditScopeShared ? 2 : 0
    labels := ["割当なし"], assigned := Map()
    for item in items
        if ItemSlot(item)
            assigned[ItemSlot(item)] := item.Name
    Loop 2
        labels.Push("Ctrl＋Alt＋" (offset+A_Index) " — " assigned.Get(A_Index,"未割当"))
    slot := DanmakuEditorWindow.AddDropDownList("w420 Choose" (ItemSlot(original)+1),labels)
    assignmentHint := DanmakuEditorWindow.AddText("w420 r2","")
    slot.OnEvent("Change",UpdateAssignment)
    UpdateAssignment()
    UpdateAssignment(*) {
        chosen := slot.Value-1
        assignmentHint.Text := chosen && assigned.Has(chosen) && chosen != ItemSlot(original)
            ? "保存すると「" assigned[chosen] "」のキーを解除し、この弾幕へ付け替えます。"
            : chosen ? "保存すると、この弾幕にキーを割り当てます。" : "キーでは呼び出さず、パレットから選んで使います。"
    }
    status := DanmakuEditorWindow.AddText("w420 r2","")
    DanmakuEditorWindow.AddButton("w120 Default","保存").OnEvent("Click",Save)
    DanmakuEditorWindow.AddButton("x+8 w120","キャンセル").OnEvent("Click",CloseDanmakuEditor)
    DanmakuEditorWindow.OnEvent("Close",CloseDanmakuEditor)
    DanmakuEditorWindow.OnEvent("Escape",CloseDanmakuEditor)
    BeginEditorDialog(DanmakuEditorWindow,"弾幕の編集")
    PresentWindow(DanmakuEditorWindow)
    Save(*) {
        if !Trim(name.Value) || !Trim(text.Value) {
            status.Text := "弾幕名と本文を入力してください。"
            return
        }
        try result := ExecuteDanmakuCommand(index ? "edit" : "add",editId,index,{Name:name.Value,Text:text.Value,Slot:slot.Value-1})
        catch as failure {
            status.Text := "保存できませんでした。" failure.Message
            return
        }
        CloseDanmakuEditor()
        RefreshManagementAfterCommand(editId)
        SelectManagedRow(result.Index)
        if WinActive("ahk_id " ManagementWindow.Hwnd)
            ManagedList.Focus()
    }
}

CloseDanmakuEditor(*) {
    global DanmakuEditorWindow
    if !DanmakuEditorWindow
        return
    editor := DanmakuEditorWindow
    restoreFocus := !!WinActive("ahk_id " editor.Hwnd)
    ; The owner must be enabled before Windows chooses a successor to the dialog.
    EndEditorDialog()
    editor.Destroy()
    DanmakuEditorWindow := 0
    if restoreFocus && DllCall("IsWindowVisible", "Ptr", ManagementWindow.Hwnd)
        && DllCall("IsWindowEnabled", "Ptr", ManagementWindow.Hwnd) {
        WinActivate("ahk_id " ManagementWindow.Hwnd)
        ManagedList.Focus()
    }
}

TransferItem(*) {
    if ManagementUpdating
        return
    index := ManagedList.GetNext()
    if !index || IsBrowserOperationBusy || ActiveReactionJob
        return
    view := Gui("+Owner" ManagementWindow.Hwnd,"弾幕の移動先")
    view.SetFont("s10","Yu Gothic UI")
    editId := GetEditingProfileId(), destinationIds := [], names := []
    view.AddText("w380 r2","移動する弾幕：" GetEditingDanmakuItems()[index].Name)
    view.AddText("w380 r2","移動元：" (editId = "" ? "共通の弾幕" : Profiles[EditProfileIndex].Name))
    view.AddText("w380 r2","移動先を選んでください。移動すると元の一覧から外れ、キーの割当も解除されます。")
    if editId != ""
        names.Push("共通の弾幕"), destinationIds.Push("")
    for profile in Profiles {
        if profile.Id = editId
            continue
        names.Push(profile.Name), destinationIds.Push(profile.Id)
    }
    target := view.AddDropDownList("w380 Choose1",names)
    status := view.AddText("w380 r2","")
    moveButton := view.AddButton("w100","移動")
    moveButton.OnEvent("Click",Move)
    moveButton.Enabled := names.Length > 0
    if !names.Length
        status.Text := "移動先がありません。先に配信者を追加してください。"
    view.AddButton("x+8 w100","キャンセル").OnEvent("Click",Close)
    view.OnEvent("Close",Close), view.OnEvent("Escape",Close)
    BeginEditorDialog(view,"弾幕の移動")
    PresentWindow(view)
    Close(*) {
        EndEditorDialog()
        view.Destroy()
    }
    Move(*) {
        if !target.Value
            return
        try result := ExecuteDanmakuCommand("move",editId,index,0,destinationIds[target.Value])
        catch as failure {
            status.Text := "保存できませんでした。" failure.Message
            return
        }
        RefreshManagementAfterCommand(editId)
        SetManagementNotice(result.Label "：保存済み")
        Close()
    }
}

EditReactionKey(*) {
    view := Gui("+Owner" ManagementWindow.Hwnd,"リアクションキーの変更")
    view.SetFont("s10","Yu Gothic UI")
    view.AddText("w420","欄を選び、Ctrl＋AltまたはCtrl＋Shiftとキーを押してください。")
    key := view.AddHotkey("w420",ReactionShortcut)
    status := view.AddText("w420 r2","「保存」で確定します。パレット・弾幕用のキーは指定できません。")
    view.AddButton("w180","Ctrl＋Alt＋Rを入力").OnEvent("Click",(*) => key.Value := ReactionDefaults.Shortcut)
    view.AddButton("x+8 w100 Default","保存").OnEvent("Click",Save)
    view.AddButton("x+8 w100","キャンセル").OnEvent("Click",Close)
    view.OnEvent("Close",Close),view.OnEvent("Escape",Close)
    BeginEditorDialog(view,"リアクションキーの編集")
    PresentWindow(view)
    Close(*) {
        EndEditorDialog()
        view.Destroy()
    }
    Save(*) {
        if IsBrowserOperationBusy || ActiveReactionJob {
            status.Text := "処理が終わってから保存してください。"
            return
        }
        try SaveReactionDefaults(CreateReactionOptions(DefaultReactionKind,DefaultReactionCount,DefaultReactionIntervalMs,key.Value))
        catch as failure {
            status.Text := failure.Message
            return
        }
        RefreshReactionDefaultControls()
        Close()
    }
}

OpenChannelLinkDialog(*) {
    if IsBrowserOperationBusy || ActiveReactionJob || RestoreActiveEditorDialog()
        return
    ShowManagement(1)
    if !IsBrowser(TargetBrowserHwnd) {
        SetManagementNotice("YouTubeを最前面にしてCtrl＋Alt＋Qを押し、もう一度チャンネル連携を開いてください。")
        return
    }
    candidate := ResolveBrowserChannel(TargetBrowserHwnd)
    if candidate.State != "ok" {
        SetManagementNotice("チャンネルを確認できませんでした。YouTubeの動画を開いてやり直してください。")
        return
    }
    view := Gui("+Owner" ManagementWindow.Hwnd,"このチャンネルと連携")
    view.SetFont("s10","Yu Gothic UI")
    view.AddText("w440 r2","YouTubeのチャンネル：" candidate.Author)
    view.AddText("w440","このチャンネルで自動選択する配信者")
    names := ["新しい配信者として登録"], ids := [""], selected := 1
    for profile in Profiles {
        names.Push(profile.Name), ids.Push(profile.Id)
        if profile.Channel == candidate.Channel
            selected := ids.Length
    }
    target := view.AddDropDownList("w440 Choose" selected,names)
    nameLabel := view.AddText("w440","アプリ内で表示する名前")
    name := view.AddEdit("w440",candidate.Author)
    summary := view.AddText("w440 r5","")
    status := view.AddText("w440 r2","")
    target.OnEvent("Change",UpdateChoice)
    name.OnEvent("Change",UpdateChoice)
    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)
    view.AddButton("x+8 w100","キャンセル").OnEvent("Click",Close)
    view.OnEvent("Close",Close),view.OnEvent("Escape",Close)
    UpdateChoice()
    BeginEditorDialog(view,"チャンネル連携")
    PresentWindow(view)
    UpdateChoice(*) {
        isNew := target.Value = 1
        name.Enabled := isNew, nameLabel.Enabled := isNew
        selectedName := isNew ? name.Value : names[target.Value]
        current := isNew ? "" : Profiles[FindProfileIndexById(Profiles,ids[target.Value])].Channel
        summary.Text := (isNew ? "新しい配信者「" selectedName "」を作成します。" : "配信者「" selectedName "」の連携を設定します。")
            . "`n現在：" (current = "" ? "未連携" : current) "`n変更後：" candidate.Channel
            . "`n" (current != "" && current != candidate.Channel ? "以前のチャンネルでは自動選択されなくなります。" : "このチャンネルで弾幕を自動選択します。")
    }
    Close(*) {
        restore := !!WinActive("ahk_id " view.Hwnd)
        EndEditorDialog()
        view.Destroy()
        if restore
            WinActivate("ahk_id " ManagementWindow.Hwnd)
    }
    Save(*) {
        global EditProfileIndex, EditScopeShared
        try {
            fresh := ResolveBrowserChannel(TargetBrowserHwnd)
            if fresh.State != "ok" || fresh.Channel != candidate.Channel
                throw Error("チャンネルが変わりました。連携画面を閉じて、もう一度開いてください。")
            if target.Value = 1
                result := ExecuteProfileCommand("add","",name.Value,candidate.Channel)
            else
                result := ExecuteProfileCommand("bind",ids[target.Value],candidate.Channel)
        } catch as failure {
            status.Text := "連携できませんでした。" failure.Message
            return
        }
        EditScopeShared := false
        RefreshManagementAfterCommand(result.ProfileId)
        SetManagementNotice("チャンネルと連携しました。自動判別でこの配信者の弾幕を選びます。")
        Close()
    }
}
