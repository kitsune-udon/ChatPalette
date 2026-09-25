; One editor owns a draft of all key bindings; existing services own persistence.
ShowShortcutManager(selectedAction := "reaction",*) {
    previousCritical := A_IsCritical, view := 0, viewport := 0
    Critical("On")
    try {
        if RestoreActiveEditorDialog() || !OperationAllowed("edit")
            return 0
        if !ManagementWindow
            BuildManagement()
        definitions := ShortcutDefinitions(), draft := CurrentShortcutMap(), syncing := false
        view := Gui("+Owner" PaletteWindow.Hwnd,"ショートカットの管理")
        view.SetFont("s10","Yu Gothic UI")
        view.AddText("x20 y16 w640 h26","キーを入力 →「キー設定を保存」の順で反映します。")
        list := view.AddListView("x20 y50 w640 h244 -Multi NoSortHdr",["操作","キー","有効な場面","状態"])
        list.ModifyCol(1,220), list.ModifyCol(2,150), list.ModifyCol(3,155), list.ModifyCol(4,90)
        Loop definitions.Length
            list.Add("")
        view.AddText("x20 y306 w640 h22","操作を選び、Ctrl＋Alt または Ctrl＋Shift とキーを入力")
        key := view.AddHotkey("x20 y334 w260")
        key.OnEvent("Change",StageKey)
        view.AddButton("x414 y332 w110 h30","割当を解除").OnEvent("Click",(*) => (StageValue(""), ChooseKey()))
        view.AddButton("x536 y332 w124 h30","停止をEscに").OnEvent("Click",UseEscape)
        status := view.AddText("x20 y372 w640 h42","")
        saveButton := view.AddButton("x20 y420 w180 h32","キー設定を保存")
        saveButton.OnEvent("Click",SaveKeys)
        view.AddButton("x212 y420 w200 h32","標準の割当に戻す").OnEvent("Click",ResetKeys)
        view.AddGroupBox("x20 y466 w640 h196","弾幕キーで入力する内容")
        scopeChoices := [{Id:"",Name:"共通の弾幕"}]
        for profile in Profiles
            scopeChoices.Push({Id:profile.Id,Name:profile.Name})
        scope := view.AddDropDownList("x36 y496 w290",[])
        SyncProfileChoices(scope,scopeChoices), scope.Choose(1)
        slotLabels := [view.AddText("x36 y532 w290 h22",""),view.AddText("x350 y532 w290 h22","")]
        first := view.AddDropDownList("x36 y556 w290",[])
        second := view.AddDropDownList("x350 y556 w290",[])
        itemsSaveButton := view.AddButton("x36 y604 w180 h32","弾幕の割当を保存")
        itemsSaveButton.OnEvent("Click",SaveItems)
        itemStatus := view.AddText("x228 y606 w412 h42","")
        view.AddText("x20 y674 w640 h42","パレット・リアクション実行・停止は解除できません。`n未保存の変更がある場合は、閉じる前に確認します。弾幕の保存はキー設定と独立しています。")
        view.AddButton("x480 y726 w180 h32","閉じる").OnEvent("Click",Close)
        itemState := 0, selected := 1
        for i,definition in definitions
            if definition.Id = selectedAction
                selected := i
        list.OnEvent("ItemSelect",ChooseKey)
        scope.OnEvent("Change",ChangeScope)
        first.OnEvent("Change",UpdateItems), second.OnEvent("Change",UpdateItems)
        view.OnEvent("Close",Close), view.OnEvent("Escape",Close)
        RenderKeys(selected), RefreshItems()
        viewport := PanelViewport(view,680,780)
        BeginEditorDialog(view,"ショートカットの管理")
        viewport.Show()
        return {Window:view,Viewport:viewport,List:list,Key:key,Status:status,
            Scope:scope,First:first,Second:second,ItemStatus:itemStatus,Save:SaveKeys,Stage:StageValue,
            Reset:ResetKeys,SaveItems:SaveItems,RefreshItems:RefreshItems,Close:Close,
            SaveButton:saveButton,ItemsSaveButton:itemsSaveButton,UpdateItems:UpdateItems,ChangeScope:ChangeScope}
    } catch as failure {
        if view
            DestroyEditorDialog(view,viewport)
        throw failure
    } finally Critical(previousCritical)
    RenderKeys(index) {
        UpdateKeys()
        list.Modify(0,"-Select"), list.Modify(index,"Select Focus Vis")
        ChooseKey()
    }
    ChooseKey(*) {
        index := list.GetNext()
        if !index
            return
        value := draft[definitions[index].Id]
        syncing := true
        key.Value := StrLower(value) = "esc" ? "" : value
        syncing := false
    }
    StageKey(*) {
        if !syncing
            StageValue(key.Value)
    }
    StageValue(value,*) {
        index := list.GetNext()
        if !index
            return
        draft[definitions[index].Id] := value
        UpdateKeys()
    }
    KeysDirty() {
        return ChangedShortcutBindings(CurrentShortcutMap(),draft).Count > 0
    }
    UpdateKeys() {
        changed := ChangedShortcutBindings(CurrentShortcutMap(),draft), dirty := changed.Count > 0
        for i,definition in definitions {
            value := draft[definition.Id], canonical := CanonicalShortcutKey(value)
            state := changed.Has(definition.Id) ? "変更あり" : ""
            for other in definitions
                if canonical != "" && other.Id != definition.Id && canonical = CanonicalShortcutKey(draft[other.Id])
                    state := "重複"
            list.Modify(i,"",definition.Label,ShortcutKeyLabel(value),definition.Scope,state)
        }
        saveButton.Enabled := dirty
        try {
            ValidateShortcutMap(draft)
            status.Text := dirty ? "未保存のキー変更があります。" : "キー設定に未保存の変更はありません。"
        } catch as failure {
            status.Text := failure.Message
            saveButton.Enabled := false
        }
    }
    UseEscape(*) {
        for i,definition in definitions
            if definition.Id = "stop" {
                list.Modify(0,"-Select"), list.Modify(i,"Select Focus Vis")
                StageValue("Esc"), ChooseKey()
                return
            }
    }
    SaveKeys(*) {
        local saveCritical := A_IsCritical
        Critical("On")
        try {
            if !OperationAllowed("preferences") || !KeysDirty()
                return
            try SaveShortcutMap(draft)
            catch as failure {
                status.Text := "保存できませんでした。" failure.Message
                return
            }
            draft := CurrentShortcutMap()
            try {
                UpdateKeys(), RefreshItemLabels()
                RefreshReactionDefaultControls()
                RefreshLibraryViews()
                status.Text := "キー設定を保存し、反映しました。"
            } catch as failure {
                status.Text := "キー設定は保存済みです。画面を更新できませんでした。" failure.Message
            }
        } finally Critical(saveCritical)
    }
    ResetKeys(*) {
        draft := DefaultShortcutKeys()
        RenderKeys(1)
    }
    RefreshItems(*) {
        local refreshCritical := A_IsCritical
        Critical("On")
        try {
            ; Neither dropdown may save against a partially replaced identity list.
            itemState := 0
            first.Enabled := false, second.Enabled := false, itemsSaveButton.Enabled := false
            itemStatus.Text := "弾幕の候補を更新しています。"
            RefreshItemLabels()
            id := GetSelectedProfileId(scope)
            items := id = "" ? SharedDanmakuItems : FindProfileById(Profiles,id).Items
            labels := ["未割当"], ids := [""], choices := [1,1]
            for item in items {
                labels.Push(item.Name), ids.Push(item.Id)
                if item.Slot
                    choices[item.Slot] := labels.Length
            }
            for i,control in [first,second] {
                control.Delete(), control.Add(labels), control.Choose(choices[i])
            }
            itemState := {ProfileId:id,Choice:scope.Value,Ids:ids,Baseline:choices}
            first.Enabled := true, second.Enabled := true
            RefreshItemLabels(), UpdateItems()
        } finally Critical(refreshCritical)
    }
    RefreshItemLabels() {
        prefix := itemState && itemState.ProfileId != "" ? "profile" : "shared"
        for i,label in slotLabels
            label.Text := itemState ? ShortcutKeyLabel(GetShortcutKey(prefix i)) : ""
    }
    ItemsDirty() {
        return itemState && (first.Value != itemState.Baseline[1] || second.Value != itemState.Baseline[2])
    }
    UpdateItems(*) {
        itemsSaveButton.Enabled := false
        if !itemState
            return
        dirty := ItemsDirty()
        itemsSaveButton.Enabled := dirty
        itemStatus.Text := dirty ? "未保存の弾幕割当があります。" : "弾幕の割当に未保存の変更はありません。"
        if first.Value > 1 && first.Value = second.Value {
            itemsSaveButton.Enabled := false
            itemStatus.Text := "同じ弾幕を両方のキーには割り当てられません。"
        }
    }
    ChangeScope(*) {
        if ItemsDirty() && !ConfirmEditorDiscard(view,"未保存の弾幕割当を破棄して対象を変更しますか？") {
            scope.Choose(itemState.Choice)
            return
        }
        try RefreshItems()
        catch as failure
            itemStatus.Text := "候補を更新できませんでした。対象を選び直してください。" failure.Message
    }
    SaveItems(*) {
        local saveCritical := A_IsCritical
        Critical("On")
        try {
            if !OperationAllowed("preferences") || !ItemsDirty()
                return
            try {
                if !(GetSelectedProfileId(scope) == itemState.ProfileId)
                    throw Error("弾幕の対象を選び直してください。")
                SaveShortcutItemAssignments(itemState.ProfileId,itemState.Ids[first.Value],itemState.Ids[second.Value])
            } catch as failure {
                itemStatus.Text := "保存できませんでした。" failure.Message
                return
            }
            itemState.Baseline := [first.Value,second.Value]
            try {
                UpdateItems()
                RefreshLibraryViews()
                itemStatus.Text := "弾幕の割当を保存しました。"
            } catch as failure {
                itemStatus.Text := "弾幕の割当は保存済みです。画面を更新できませんでした。" failure.Message
            }
        } finally Critical(saveCritical)
    }
    Close(*) {
        if !ActiveEditorDialog || ActiveEditorDialog.Window != view
            return
        if (KeysDirty() || ItemsDirty()) && !ConfirmEditorDiscard(view,"未保存の変更を破棄して閉じますか？")
            return
        DestroyEditorDialog(view,viewport)
    }
}
