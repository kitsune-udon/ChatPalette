; Owned editors and their explicit save/cancel lifetime.

OpenDanmakuEditor(isNew) {
    previousCritical := A_IsCritical, view := 0
    Critical("On")
    try {
        if RestoreActiveEditorDialog() || !OperationAllowed("edit")
            return
        selected := isNew ? 0 : GetSelectedManagedTarget()
        if !isNew && !selected
            return
        editId := selected ? selected.ProfileId : GetEditingProfileId()
        items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},editId)
        original := selected ? selected.Item : {Name:"",Text:"",Slot:0}
        view := Gui("+Owner" ManagementWindow.Hwnd,"弾幕を" (isNew ? "追加" : "編集"))
        view.SetFont("s10","Yu Gothic UI")
        view.AddText("w420","編集対象：" ((editId = "") ? "共通の弾幕" : FindProfileById(Profiles,editId).Name))
        view.AddText(,"弾幕名")
        name := view.AddEdit("w420",original.Name)
        view.AddText(,"本文（1行）")
        text := view.AddEdit("w420",original.Text)
        view.AddText(,"キーの割当 — 現在の割当を表示")
        labels := ["割当なし"], assigned := Map()
        for item in items
            if item.Slot
                assigned[item.Slot] := item.Name
        Loop 2
            labels.Push(ShortcutKeyLabel(GetShortcutKey((editId = "" ? "shared" : "profile") A_Index)) " — " assigned.Get(A_Index,"未割当"))
        slot := view.AddDropDownList("w420 Choose" (original.Slot+1),labels)
        assignmentHint := view.AddText("w420 r2","")
        slot.OnEvent("Change",UpdateAssignment)
        UpdateAssignment()
        view.IsDirty := (*) => !(name.Value == original.Name) || !(text.Value == original.Text) || slot.Value-1 != original.Slot
        status := view.AddText("w420 r2","")
        view.AddButton("w120 Default","保存").OnEvent("Click",Save)
        view.AddButton("x+8 w120","キャンセル").OnEvent("Click",CloseDanmakuEditor.Bind(view))
        view.OnEvent("Close",CloseDanmakuEditor.Bind(view))
        view.OnEvent("Escape",CloseDanmakuEditor.Bind(view))
        BeginEditorDialog(view,"弾幕の編集")
        PresentWindow(view)
    } catch as failure {
        if view
            DestroyEditorDialog(view)
        throw failure
    } finally Critical(previousCritical)
    UpdateAssignment(*) {
        chosen := slot.Value-1
        assignmentHint.Text := chosen && assigned.Has(chosen) && chosen != original.Slot
            ? "保存すると「" assigned[chosen] "」のキーを解除し、この弾幕へ付け替えます。"
            : chosen ? "保存すると、この弾幕にキーを割り当てます。" : "キーでは呼び出さず、パレットから選んで使います。"
    }
    Save(*) {
        local commitCritical := A_IsCritical
        Critical("On")
        try {
            if !Trim(name.Value) || !Trim(text.Value) {
                status.Text := "弾幕名と本文を入力してください。"
                return
            }
            try result := ExecuteDanmakuCommand(isNew ? "add" : "edit",editId,isNew ? "" : original.Id,{Name:name.Value,Text:text.Value,Slot:slot.Value-1})
            catch as failure {
                status.Text := "保存できませんでした。" failure.Message
                return
            }
            FinishDanmakuEditor(view)
            RefreshManagementAfterCommand(editId,result.Label "：保存済み",RenderManagedSelection.Bind(result.Index))
            if WinActive("ahk_id " ManagementWindow.Hwnd)
                ManagedList.Focus()
        } finally Critical(commitCritical)
    }
}

CloseDanmakuEditor(view,*) {
    if !ActiveEditorDialog || ActiveEditorDialog.Window != view
        return
    if view.IsDirty.Call() && !ConfirmEditorDiscard(view)
        return
    FinishDanmakuEditor(view)
}
FinishDanmakuEditor(view) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !ActiveEditorDialog || ActiveEditorDialog.Window != view
            return
        restoreFocus := !!WinActive("ahk_id " view.Hwnd)
        ; Restore the owner before Windows chooses a successor to the dialog.
        DestroyEditorDialog(view)
        if restoreFocus && DllCall("IsWindowVisible", "Ptr", ManagementWindow.Hwnd)
            && DllCall("IsWindowEnabled", "Ptr", ManagementWindow.Hwnd) {
            WinActivate("ahk_id " ManagementWindow.Hwnd)
            ManagedList.Focus()
        }
    } finally Critical(previousCritical)
}

TransferItem(*) {
    previousCritical := A_IsCritical, view := 0
    Critical("On")
    try {
        if RestoreActiveEditorDialog() || !OperationAllowed("edit")
            return
        selected := GetSelectedManagedTarget()
        if !selected
            return
        view := Gui("+Owner" ManagementWindow.Hwnd,"弾幕の移動先")
        view.SetFont("s10","Yu Gothic UI")
        editId := selected.ProfileId, item := selected.Item, choices := []
        view.AddText("w380 r2","移動する弾幕：" item.Name)
        view.AddText("w380 r2","移動元：" (editId = "" ? "共通の弾幕" : FindProfileById(Profiles,editId).Name))
        view.AddText("w380 r2","移動先を選んでください。移動すると元の一覧から外れ、キーの割当も解除されます。")
        if editId != ""
            choices.Push({Id:"",Name:"共通の弾幕"})
        for profile in Profiles {
            if profile.Id == editId
                continue
            choices.Push({Id:profile.Id,Name:profile.Name})
        }
        target := view.AddDropDownList("w380",[])
        SyncProfileChoices(target,choices)
        if choices.Length
            target.Choose(1)
        status := view.AddText("w380 r2","")
        moveButton := view.AddButton("w100","移動")
        moveButton.OnEvent("Click",Move)
        moveButton.Enabled := choices.Length > 0
        if !choices.Length
            status.Text := "移動先がありません。先に配信者を追加してください。"
        view.AddButton("x+8 w100","キャンセル").OnEvent("Click",Close)
        view.OnEvent("Close",Close), view.OnEvent("Escape",Close)
        BeginEditorDialog(view,"弾幕の移動")
        PresentWindow(view)
    } catch as failure {
        if view
            DestroyEditorDialog(view)
        throw failure
    } finally Critical(previousCritical)
    Close(*) {
        if !ActiveEditorDialog || ActiveEditorDialog.Window != view
            return
        DestroyEditorDialog(view)
    }
    Move(*) {
        local commitCritical := A_IsCritical
        Critical("On")
        try {
            if !target.Value
                return
            try result := ExecuteDanmakuCommand("move",editId,item.Id,0,GetSelectedProfileId(target))
            catch as failure {
                status.Text := "保存できませんでした。" failure.Message
                return
            }
            Close()
            RefreshManagementAfterCommand(editId,result.Label "：保存済み")
        } finally Critical(commitCritical)
    }
}

OpenChannelLinkDialog(preferredProfileId := "",*) {
    if RestoreActiveEditorDialog() || !OperationAllowed("edit")
        return
    ShowManagement(1)
    if !IsBrowser(TargetBrowserHwnd) {
        SetManagementNotice("YouTubeを最前面にして" ShortcutKeyLabel(GetShortcutKey("palette")) "を押し、もう一度チャンネル連携を開いてください。")
        return
    }
    candidate := ResolveBrowserChannel(TargetBrowserHwnd)
    if candidate.State != "ok" {
        SetManagementNotice("チャンネルを確認できませんでした。YouTubeの動画を開いてやり直してください。")
        return
    }
    previousCritical := A_IsCritical, view := 0
    Critical("On")
    try {
        if RestoreActiveEditorDialog() || !OperationAllowed("edit")
            return
        if preferredProfileId != "" && !FindProfileById(Profiles,preferredProfileId) {
            SetManagementNotice("対象の配信者がありません。選び直してください。")
            return
        }
        view := Gui("+Owner" ManagementWindow.Hwnd,"このチャンネルと連携")
        view.SetFont("s10","Yu Gothic UI")
        view.AddText("w440 r2","YouTubeのチャンネル：" candidate.Author)
        view.AddText("w440","このチャンネルで自動選択する配信者")
        choices := [{Id:"",Name:"新しい配信者として登録"}], selected := 1
        for profile in Profiles {
            choices.Push({Id:profile.Id,Name:profile.Name})
            if preferredProfileId != "" ? profile.Id == preferredProfileId : profile.Channel == candidate.Channel
                selected := choices.Length
        }
        target := view.AddDropDownList("w440",[])
        SyncProfileChoices(target,choices), target.Choose(selected)
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
    } catch as failure {
        if view
            DestroyEditorDialog(view)
        throw failure
    } finally Critical(previousCritical)
    UpdateChoice(*) {
        try selectedId := GetSelectedProfileId(target)
        catch as failure {
            summary.Text := failure.Message
            return
        }
        isNew := selectedId = ""
        name.Enabled := isNew, nameLabel.Enabled := isNew
        selectedName := isNew ? name.Value : target.Text
        current := isNew ? "" : FindProfileById(Profiles,selectedId).Channel
        summary.Text := (isNew ? "新しい配信者「" selectedName "」を作成します。" : "配信者「" selectedName "」の連携を設定します。")
            . "`n現在：" (current = "" ? "未連携" : current) "`n変更後：" candidate.Channel
            . "`n" (current != "" && !(current == candidate.Channel) ? "以前のチャンネルでは自動選択されなくなります。" : "このチャンネルで弾幕を自動選択します。")
    }
    Close(*) {
        if !ActiveEditorDialog || ActiveEditorDialog.Window != view
            return
        restore := !!WinActive("ahk_id " view.Hwnd)
        DestroyEditorDialog(view)
        if restore
            WinActivate("ahk_id " ManagementWindow.Hwnd)
    }
    Save(*) {
        local commitCritical := A_IsCritical
        try {
            try {
                selectedId := GetSelectedProfileId(target), submittedName := name.Value
                fresh := ResolveBrowserChannel(TargetBrowserHwnd)
                if fresh.State != "ok" || !(fresh.Channel == candidate.Channel)
                    throw Error("チャンネルが変わりました。連携画面を閉じて、もう一度開いてください。")
                ; Network verification stays interruptible; only commit and presentation are atomic.
                Critical("On")
                if selectedId = ""
                    result := ExecuteProfileCommand("add","",submittedName,candidate.Channel)
                else
                    result := ExecuteProfileCommand("bind",selectedId,candidate.Channel)
            } catch as failure {
                status.Text := "連携できませんでした。" failure.Message
                return
            }
            Close()
            RefreshManagementAfterCommand(result.ProfileId,"チャンネルと連携しました。自動判別でこの配信者の弾幕を選びます。")
        } finally Critical(commitCritical)
    }
}
