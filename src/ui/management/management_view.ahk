ShowManagement(page := 1, *) {
    if RestoreActiveEditorDialog()
        return
    if DanmakuEditorWindow {
        PresentWindow(DanmakuEditorWindow)
        return
    }
    if !ManagementWindow
        BuildManagement()
    ManagementTabs.Choose(page)
    RefreshManagement()
    PaletteWindow.Hide()
    ShowFittedWindow(ManagementWindow,760,660,ResizeManagement)
    if page = 3
        RefreshReactionRegistration()
}


BuildManagement() {
    global ManagementBack, ReactionLoadButton, ReactionRegistrationLabel, ReactionDefaultLabels, ReactionDefaultExplanation, ManagementKeyIntro
    global ManagementProfileMenu, ManagementListHeading, ManagementSupportGroups, ManagementAddProfileButton, ManagementItemButtons, ManagementScopeHint, ManagementSupportButtons
    global ManagementWindow, ManagementTabs, ManagementTarget, ManagedList, ManagementStatus, ManagementUndo
    global ManagementTitle, ManagementChannel, ManagementButtons, ReactionDefaultChoiceControl, ReactionDefaultCountControl, ReactionDefaultIntervalControl, ReactionDefaultsStatusControl, KeyLabel
    ManagementWindow := Gui("+Resize +MinSize360x520", "ChatPalette — 管理・設定")
    ManagementWindow.BackColor := "F5F7FA"
    ManagementWindow.SetFont("s10", "Yu Gothic UI")
    ManagementTabs := ManagementWindow.AddTab3("x12 y12 w736 h592", ["弾幕・配信者", "リアクション", "操作・サポート"])
    ManagementTabs.OnEvent("Change", (*) => ManagementTabs.Value = 3 ? RefreshReactionRegistration() : 0)
    ManagementTabs.UseTab(1)
    ManagementTarget := ManagementWindow.AddDropDownList("x28 y54 w320", [])
    ManagementTarget.OnEvent("Change", ChangeManagementTarget)
    ManagementAddProfileButton := ManagementWindow.AddButton("x364 y52 w160 h30", "配信者を追加")
    ManagementAddProfileButton.OnEvent("Click", (*) => ManageProfile("add"))
    ManagementTitle := ManagementWindow.AddText("x28 y96 w680 h24", "")
    ManagementChannel := ManagementWindow.AddText("x28 y126 w680 h38", "")
    ManagementProfileMenu := ManagementWindow.AddButton("x28 y112 w280 h32","配信者の設定…")
    ManagementProfileMenu.OnEvent("Click",OpenManagedProfileMenu)
    ManagementButtons := [ManagementProfileMenu]
    ManagementListHeading := ManagementWindow.AddText("x28 y202 w680 h24","弾幕一覧 — 選んで編集")
    ManagedList := ManagementWindow.AddListView("x28 y218 w680 h210 -Multi NoSortHdr", ["弾幕名", "本文", "キー"])
    ManagedList.OnEvent("ItemSelect",UpdateManagementActions)
    ManagedList.OnEvent("DoubleClick", (*) => OpenDanmakuEditor(false))
    ManagementItemButtons := []
    for entry in [["追加…",(*) => OpenDanmakuEditor(true)],["編集…",(*) => OpenDanmakuEditor(false)],["複製",HandleDanmakuCommand.Bind("duplicate")],["削除",HandleDanmakuCommand.Bind("delete")],["上へ",HandleDanmakuCommand.Bind("up")],["下へ",HandleDanmakuCommand.Bind("down")],["別の対象へ移動…",TransferItem]] {
        button := ManagementWindow.AddButton("x" (28+(A_Index-1)*96) " y440 w88 h30",entry[1])
        button.OnEvent("Click",entry[2])
        ManagementItemButtons.Push(button)
    }
    ManagementUndo := ManagementWindow.AddButton("x28 y488 w680 h32", "取り消せる変更はありません")
    ManagementUndo.OnEvent("Click",UndoLibraryChange)
    ManagementScopeHint := ManagementWindow.AddText("x28 y538 w680 h42", "変更は自動保存します。`n編集対象と入力対象は別です。")
    ManagementTabs.UseTab(2)
    ManagementWindow.AddText("x28 y60 w640 h42", "リアクションの標準設定`n全チャンネル共通・キー実行に適用").SetFont("bold")
    ReactionDefaultLabels := []
    ReactionDefaultLabels.Push(ManagementWindow.AddText("x28 y116 w300 h24", "種類"))
    ReactionDefaultChoiceControl := ManagementWindow.AddDropDownList("x28 y142 w300",ReactionNames)
    ReactionDefaultLabels.Push(ManagementWindow.AddText("x28 y182 w300 h24", "1回の実行で繰り返す回数"))
    ReactionDefaultCountControl := ManagementWindow.AddDropDownList("x28 y208 w300",SettingOptionLabels(ReactionCounts,"回"))
    ReactionDefaultLabels.Push(ManagementWindow.AddText("x28 y248 w300 h24", "リアクションの間隔"))
    ReactionDefaultIntervalControl := ManagementWindow.AddDropDownList("x28 y274 w300",ReactionIntervalLabels())
    ReactionDefaultExplanation := ManagementWindow.AddText("x28 y320 w650 h62", "選択すると保存し、キー実行に適用します。`nパレットの今回の設定は変わりません。`n処理が長い場合は、指定間隔を超えます。")
    ReactionDefaultsStatusControl := ManagementWindow.AddText("x28 y384 w650 h32", "")
    ReactionLoadButton := ManagementWindow.AddButton("x28 y420 w280 h32","パレットへ読み込んで戻る")
    ReactionLoadButton.OnEvent("Click",LoadDefaultsAndReturn)
    for control in [ReactionDefaultChoiceControl,ReactionDefaultCountControl,ReactionDefaultIntervalControl]
        control.OnEvent("Change",SaveReactionDefaultsFromControls)
    ManagementTabs.UseTab(3)
    ManagementSupportButtons := Map(), ManagementSupportGroups := []
    ManagementSupportGroups.Push(ManagementWindow.AddGroupBox("x24 y48 w712 h156","キー操作"))
    ManagementKeyIntro := ManagementWindow.AddText("x40 y74 w680 h42", "パレットを開く：Ctrl＋Alt＋Q`n弾幕を入力：配信者 1／2・共通 3／4（Ctrl＋Alt）")
    KeyLabel := ManagementWindow.AddText("x40 y122 w680 h24", "")
    ManagementSupportButtons["key"] := ManagementWindow.AddButton("x40 y154 w260 h36", "リアクションのキーを変更…")
    ManagementSupportButtons["key"].OnEvent("Click",EditReactionKey)
    ManagementSupportGroups.Push(ManagementWindow.AddGroupBox("x24 y214 w712 h124","リアクションの準備"))
    ReactionRegistrationLabel := ManagementWindow.AddText("x40 y240 w680 h42", "対象ブラウザー：未確認")
    ManagementSupportButtons["register"] := ManagementWindow.AddButton("x40 y288 w320 h36", "① ボタンを設定…")
    ManagementSupportButtons["register"].OnEvent("Click",(*) => PrepareReaction("reaction_capture"))
    ManagementSupportButtons["check"] := ManagementWindow.AddButton("x380 y288 w320 h36", "② 送らずに確認")
    ManagementSupportButtons["check"].OnEvent("Click",(*) => PrepareReaction("reaction_check"))
    ManagementSupportGroups.Push(ManagementWindow.AddGroupBox("x24 y348 w712 h120","使い方・トラブルの確認"))
    ManagementSupportButtons["help"] := ManagementWindow.AddButton("x40 y374 w320 h36", "使い方")
    ManagementSupportButtons["help"].OnEvent("Click",Help)
    ManagementSupportButtons["details"] := ManagementWindow.AddButton("x380 y374 w320 h36", "リアクションの実行結果")
    ManagementSupportButtons["details"].OnEvent("Click",ShowReactionDetails)
    ManagementSupportButtons["diagnostics"] := ManagementWindow.AddButton("x40 y418 w320 h36", "診断情報（不具合の相談用）")
    ManagementSupportButtons["diagnostics"].OnEvent("Click",ShowDiagnostics)
    ManagementTabs.UseTab()
    ManagementBack := ManagementWindow.AddButton("x16 y614 w140 h32","パレットへ戻る")
    ManagementBack.OnEvent("Click",ReturnToPalette)
    ManagementStatus := ManagementWindow.AddEdit("x16 y614 w720 h34 ReadOnly Multi VScroll Hidden", "")
    ManagementWindow.OnEvent("Close",(*) => ManagementWindow.Hide())
    ManagementWindow.OnEvent("Escape",(*) => ManagementWindow.Hide())
    ManagementWindow.OnEvent("Size",ResizeManagement)
    RefreshReactionDefaultControls()
    RefreshManagement()
    global ManagementViewport := PanelViewport(ManagementWindow,360,520,LayoutManagement)
}


RefreshManagement() {
    global EditProfileIndex, EditScopeShared
    if !ManagementWindow
        return
    names := ["共通の弾幕"]
    for profile in Profiles
        names.Push(profile.Name)
    SyncChoiceNames(ManagementTarget,names)
    if EditProfileIndex < 1 || EditProfileIndex > Profiles.Length
        EditScopeShared := true, EditProfileIndex := 0
    ManagementTarget.Choose(EditScopeShared ? 1 : EditProfileIndex+1)
    ManagementTitle.Text := "編集する弾幕"
    ManagementChannel.Text := EditScopeShared ? "すべてのチャンネルで使う弾幕です。" : "チャンネル：" (Profiles[EditProfileIndex].Channel != "" ? Profiles[EditProfileIndex].Channel : "チャンネル未連携")
    for button in ManagementButtons
        button.Enabled := !EditScopeShared
    position := BeginListRefresh(ManagedList,2)
    try {
        ManagedList.Delete()
        for item in GetEditingDanmakuItems()
            ManagedList.Add("",item.Name,item.Text,ItemSlot(item) ? "Ctrl+Alt+" (ItemSlot(item)+(EditScopeShared ? 2 : 0)) : "")
        ManagedList.ModifyCol(1,160), ManagedList.ModifyCol(2,380), ManagedList.ModifyCol(3,110)
    } finally {
        EndListRefresh(ManagedList,position,2)
    }
    UpdateManagementActions()
    RefreshManagementUndo()
    ManagementWindow.GetClientPos(,,&width,&height)
    if width > 0
        ResizeManagement(ManagementWindow,0,width,height)
}


RefreshReactionDefaultControls() {
    if !ManagementWindow
        return
    ReactionDefaultChoiceControl.Choose(DefaultReactionKind)
    ChooseSetting(ReactionDefaultCountControl,ReactionCounts,DefaultReactionCount)
    ChooseSetting(ReactionDefaultIntervalControl,ReactionIntervals,DefaultReactionIntervalMs)
    KeyLabel.Text := "リアクション：" ReactionKeyLabel()
    ReactionDefaultsStatusControl.Text := "保存済み：キー実行に適用。"
        . (DefaultReactionIntervalMs = 0 ? "`n待機なし：処理終了後すぐに次を実行。" : "")
}


LayoutManagement(gui, state, width, height) {
    if state = -1
        return
    full := Max(304,width-56), half := Floor((full-8)/2)
    compact := width < 420
    ManagementTabs.Move(,,width-24,height-(compact ? 112 : 60))
    ManagementBack.Move(16,height-42,140,32)
    if compact
        ManagementStatus.Move(16,height-94,width-32,44)
    else
        ManagementStatus.Move(164,height-42,width-180,36)
    ReactionLoadButton.Move(28,compact ? 380 : 420,Min(300,full),32)
    ReactionDefaultExplanation.Move(,compact ? 282 : 320)
    ReactionDefaultsStatusControl.Move(,compact ? 346 : 384)
    for i,label in ReactionDefaultLabels
        label.Move(,compact ? 112+(i-1)*52 : 116+(i-1)*66)
    ManagementTitle.Move(28,48,full,24)
    ManagementTarget.Move(28,76,full)
    ManagementAddProfileButton.Move(28,112,half,32)
    ManagementProfileMenu.Move(36+half,112,half,32)
    ManagementChannel.Move(28,compact ? 148 : 154,full,compact ? 32 : 40)
    ManagementListHeading.Move(28,compact ? 184 : 202,full,24)
    listTop := compact ? 208 : 228
    listHeight := Max(64,height-listTop-(compact ? 248 : 220)), bottom := listTop+listHeight
    ManagedList.Move(28,listTop,full,listHeight)
    columnWidth := full-24, nameWidth := Floor(columnWidth*0.28)
    ManagedList.ModifyCol(1,nameWidth),ManagedList.ModifyCol(2,columnWidth-nameWidth-90),ManagedList.ModifyCol(3,90)
    fourth := Floor((full-24)/4)
    Loop 4
        ManagementItemButtons[A_Index].Move(28+(A_Index-1)*(fourth+8),bottom+(compact ? 4 : 8),fourth,compact ? 28 : 32)
    ManagementItemButtons[5].Move(28,bottom+(compact ? 36 : 48),fourth,compact ? 28 : 32)
    ManagementItemButtons[6].Move(36+fourth,bottom+(compact ? 36 : 48),fourth,compact ? 28 : 32)
    ManagementItemButtons[7].Move(44+fourth*2,bottom+(compact ? 36 : 48),full-fourth*2-16,compact ? 28 : 32)
    ManagementScopeHint.Move(28,bottom+(compact ? 104 : 130),full,36)
    for control in ManagementWindow {
        if control.Type = "Text" && control != ManagementTitle && control != ManagementChannel && control != ManagementStatus {
            control.GetPos(&textX)
            control.Move(,,width-textX-28)
        }
    }
    supportWidth := width-80, supportHalf := Floor((supportWidth-8)/2)
    for group in ManagementSupportGroups
        group.Move(,,width-48)
    ManagementKeyIntro.Move(,74,,compact ? 36 : 42)
    KeyLabel.Move(,compact ? 114 : 122)
    ReactionRegistrationLabel.Move(,compact ? 218 : 240)
    ManagementSupportGroups[1].Move(,48,,compact ? 136 : 156)
    ManagementSupportGroups[2].Move(,compact ? 194 : 214,,compact ? 108 : 124)
    ManagementSupportGroups[3].Move(,compact ? 312 : 348,,compact ? 104 : 120)
    ManagementSupportButtons["key"].Move(40,compact ? 140 : 154,Min(280,supportWidth),36)
    ManagementSupportButtons["register"].Move(40,compact ? 258 : 288,supportHalf,36)
    ManagementSupportButtons["check"].Move(48+supportHalf,compact ? 258 : 288,supportHalf,36)
    ManagementSupportButtons["help"].Move(40,compact ? 334 : 374,supportHalf,36)
    ManagementSupportButtons["details"].Move(48+supportHalf,compact ? 334 : 374,supportHalf,36)
    ManagementSupportButtons["diagnostics"].Move(40,compact ? 374 : 418,supportWidth,36)
    ManagementUndo.Move(28,bottom+(compact ? 68 : 90),full,compact ? 28 : 32)
    for i,control in [ReactionDefaultChoiceControl,ReactionDefaultCountControl,ReactionDefaultIntervalControl]
        control.Move(,compact ? 136+(i-1)*52 : 142+(i-1)*66,Min(300,full))
}


SelectManagedRow(index) {
    if ManagedList.GetCount() {
        ManagedList.Modify(Min(Max(1,index),ManagedList.GetCount()),"Select Focus Vis")
    }
    ; Programmatic selection must not depend on deferred ItemSelect callbacks.
    UpdateManagementActions()
}

; The palette shortcut opens a concrete choice, not just the management tab.


OpenManagedProfileMenu(*) {
    if EditScopeShared || ActiveEditorDialog || IsBrowserOperationBusy || ActiveReactionJob
        return
    menu := Menu()
    for entry in [["名前を変更…","rename"],["チャンネルと連携…","bind"],["チャンネル連携を解除","unbind"],["配信者と弾幕を削除…","delete"]]
        menu.Add(entry[1],ManageProfile.Bind(entry[2]))
    menu.Show()
}

UpdateManagementActions(*) {
    if !IsSet(ManagementItemButtons) || ManagementItemButtons.Length != 7
        return
    selected := ManagedList.GetNext(), count := ManagedList.GetCount()
    for i in [2,3,4,7]
        ManagementItemButtons[i].Enabled := selected > 0
    ManagementItemButtons[5].Enabled := selected > 1
    ManagementItemButtons[6].Enabled := selected > 0 && selected < count
}


ResizeManagement(gui, state, width, height) {
    if state = -1
        return
    if IsSet(ManagementViewport)
        ManagementViewport.Resize()
    else
        LayoutManagement(gui,state,width,height)
}

SetManagementNotice(message) {
    ManagementStatus.Text := message = "" ? "" : "通知：" message
    ManagementStatus.Visible := message != ""
}

; Reordering updates the two affected rows without rebuilding the list or resetting its viewport.
RefreshManagedOrder(previous, current) {
    items := GetEditingDanmakuItems()
    ManagedList.Opt("-Redraw")
    try {
        for index in [previous,current] {
            item := items[index]
            ManagedList.Modify(index,"",item.Name,item.Text,ItemSlot(item) ? "Ctrl+Alt+" (ItemSlot(item)+(EditScopeShared ? 2 : 0)) : "")
        }
        SelectManagedRow(current)
    } finally {
        ManagedList.Opt("+Redraw")
    }
    UpdateManagementActions()
    RefreshManagementUndo()
}

RefreshManagementUndo() {
    ManagementUndo.Enabled := LibraryHistory.Length > 0
    ManagementUndo.Text := LibraryHistory.Length ? LibraryHistory[-1].Label "を取り消す" : "取り消せる変更はありません"
}
