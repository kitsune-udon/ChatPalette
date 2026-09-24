; One editor owns a draft of all key bindings; existing services own persistence.
ShowShortcutManager(selectedAction := "reaction",*) {
    if RestoreActiveEditorDialog() || !OperationAllowed("edit")
        return 0
    if !ManagementWindow
        BuildManagement()
    panel := CreateShortcutManager(selectedAction)
    BeginEditorDialog(panel.Window,"ショートカットの管理")
    try panel.Viewport.Show()
    catch as failure {
        panel.Viewport.Dispose()
        EndEditorDialog()
        panel.Window.Destroy()
        throw failure
    }
    return panel
}
CreateShortcutManager(selectedAction := "reaction") {
    definitions := ShortcutDefinitions(), draft := CurrentShortcutMap(), syncing := false
    view := Gui("+Owner" PaletteWindow.Hwnd,"ショートカットの管理")
    view.SetFont("s10","Yu Gothic UI")
    view.AddText("x20 y16 w640 h26","キーを入力 →「キー設定を保存」の順で反映します。")
    list := view.AddListView("x20 y50 w640 h244 -Multi NoSortHdr",["操作","キー","有効な場面","状態"])
    list.ModifyCol(1,220), list.ModifyCol(2,150), list.ModifyCol(3,155), list.ModifyCol(4,90)
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
    names := ["共通の弾幕"], scopeIds := [""]
    for profile in Profiles
        names.Push(profile.Name), scopeIds.Push(profile.Id)
    scope := view.AddDropDownList("x36 y496 w290 Choose1",names)
    slotLabels := [view.AddText("x36 y532 w290 h22",""),view.AddText("x350 y532 w290 h22","")]
    first := view.AddDropDownList("x36 y556 w290",[])
    second := view.AddDropDownList("x350 y556 w290",[])
    itemsSaveButton := view.AddButton("x36 y604 w180 h32","弾幕の割当を保存")
    itemsSaveButton.OnEvent("Click",SaveItems)
    itemStatus := view.AddText("x228 y606 w412 h42","")
    view.AddText("x20 y674 w640 h42","パレット・リアクション実行・停止は解除できません。`n未保存の変更がある場合は、閉じる前に確認します。弾幕の保存はキー設定と独立しています。")
    view.AddButton("x480 y726 w180 h32","閉じる").OnEvent("Click",Close)
    itemIds := [], itemBaseline := [1,1], loadedScope := 1, selected := 1
    for i,definition in definitions
        if definition.Id = selectedAction
            selected := i
    list.OnEvent("ItemSelect",ChooseKey)
    scope.OnEvent("Change",ChangeScope)
    first.OnEvent("Change",UpdateItems), second.OnEvent("Change",UpdateItems)
    view.OnEvent("Close",Close), view.OnEvent("Escape",Close)
    RenderKeys(selected), RefreshItems()
    viewport := PanelViewport(view,680,780)
    return {Window:view,Viewport:viewport,List:list,Key:key,Status:status,
        Scope:scope,First:first,Second:second,ItemStatus:itemStatus,Save:SaveKeys,Stage:StageValue,
        Reset:ResetKeys,SaveItems:SaveItems,RefreshItems:RefreshItems,Close:Close,
        SaveButton:saveButton,ItemsSaveButton:itemsSaveButton,UpdateItems:UpdateItems,ChangeScope:ChangeScope}
    RenderKeys(index) {
        list.Delete()
        for definition in definitions
            list.Add("",definition.Label,ShortcutKeyLabel(draft[definition.Id]),definition.Scope)
        list.Modify(index,"Select Focus Vis")
        ChooseKey(), UpdateKeys()
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
        saved := CurrentShortcutMap()
        for id,value in draft
            if CanonicalShortcutKey(value) != CanonicalShortcutKey(saved[id])
                return true
        return false
    }
    UpdateKeys() {
        saved := CurrentShortcutMap(), dirty := false
        for i,definition in definitions {
            value := draft[definition.Id], canonical := CanonicalShortcutKey(value)
            changed := canonical != CanonicalShortcutKey(saved[definition.Id])
            dirty := dirty || changed
            state := changed ? "変更あり" : ""
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
        if !OperationAllowed("preferences") || !KeysDirty()
            return
        try {
            SaveShortcutMap(draft)
            draft := CurrentShortcutMap()
            RefreshReactionDefaultControls()
            RefreshPalette(), RefreshManagement()
            UpdateKeys(), RefreshItemLabels()
            status.Text := "キー設定を保存し、反映しました。"
        } catch as failure {
            status.Text := "保存できませんでした。" failure.Message
        }
    }
    ResetKeys(*) {
        draft := DefaultShortcutKeys()
        RenderKeys(1)
    }
    RefreshItems(*) {
        id := scopeIds[scope.Value]
        items := id = "" ? SharedDanmakuItems : FindProfileById(Profiles,id).Items
        labels := ["未割当"], itemIds := [""], choices := [1,1]
        for item in items {
            labels.Push(item.Name), itemIds.Push(item.Id)
            if ItemSlot(item)
                choices[ItemSlot(item)] := labels.Length
        }
        for i,control in [first,second] {
            control.Delete(), control.Add(labels), control.Choose(choices[i])
        }
        itemBaseline := choices, loadedScope := scope.Value
        RefreshItemLabels(), UpdateItems()
    }
    RefreshItemLabels() {
        prefix := scopeIds[loadedScope] = "" ? "shared" : "profile"
        for i,label in slotLabels
            label.Text := ShortcutKeyLabel(GetShortcutKey(prefix i))
    }
    ItemsDirty() {
        return first.Value != itemBaseline[1] || second.Value != itemBaseline[2]
    }
    UpdateItems(*) {
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
            scope.Choose(loadedScope)
            return
        }
        RefreshItems()
    }
    SaveItems(*) {
        if !OperationAllowed("preferences") || !ItemsDirty()
            return
        try {
            SaveShortcutItemAssignments(scopeIds[scope.Value],itemIds[first.Value],itemIds[second.Value])
            RefreshPalette(), RefreshManagement(), RefreshItems()
            itemStatus.Text := "弾幕の割当を保存しました。"
        } catch as failure {
            itemStatus.Text := "保存できませんでした。" failure.Message
        }
    }
    Close(*) {
        if (KeysDirty() || ItemsDirty()) && !ConfirmEditorDiscard(view,"未保存の変更を破棄して閉じますか？")
            return
        viewport.Dispose()
        EndEditorDialog()
        view.Destroy()
    }
}
