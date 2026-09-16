BuildPalette() {
    global PaletteTitle, PaletteWindow, PaletteContext, PaletteMode, PaletteProfile, PaletteSearch, PaletteList
    global PaletteInsert, PaletteBind, PaletteChoice, PaletteCount, PaletteInterval, PaletteStart, PaletteStop
    global PaletteOptionLabels, PaletteSettingsStatus, PaletteManageButton, PaletteReactionHeading, PaletteIntervalHint
    global PaletteHint, PaletteStatusControl, PaletteMenuButton, PaletteDefaults, PaletteReset, PalettePreview
    PaletteWindow := Gui("+Resize +MinSize360x620", "ChatPalette")
    PaletteWindow.BackColor := "F5F7FA"
    PaletteWindow.SetFont("s10", "Yu Gothic UI")
    PaletteTitle := PaletteWindow.AddText("x16 y14 w240 h26", "ChatPalette")
    PaletteTitle.SetFont("s15 bold")
    PaletteMenuButton := PaletteWindow.AddButton("x430 y12 w110 h30", "管理・ヘルプ")
    PaletteMenuButton.OnEvent("Click", OpenPaletteMenu)
    PaletteContext := PaletteWindow.AddText("x16 y50 w524 h42", "")
    PaletteMode := PaletteWindow.AddDropDownList("x16 y100 w110 Choose1", ["自動判別", "手動選択"])
    PaletteMode.OnEvent("Change", ChangePaletteMode)
    PaletteProfile := PaletteWindow.AddDropDownList("x134 y100 w260", [])
    PaletteProfile.OnEvent("Change", SelectPaletteProfile)
    PaletteBind := PaletteWindow.AddButton("x402 y98 w138 h28", "チャンネル連携…")
    PaletteBind.OnEvent("Click", OpenChannelLinkDialog)
    PaletteSearch := PaletteWindow.AddEdit("x16 y140 w524 h28")
    DllCall("SendMessage", "Ptr", PaletteSearch.Hwnd, "UInt", 0x1501, "Ptr", 1, "Str", "弾幕名・本文を検索")
    PaletteSearch.OnEvent("Change", (*) => RefreshPaletteItems())
    PaletteList := PaletteWindow.AddListView("x16 y176 w524 h200 -Multi", ["対象", "弾幕・本文", "キー"])
    PaletteList.OnEvent("ItemSelect", PreviewPaletteItem)
    PalettePreview := PaletteWindow.AddEdit("x16 y346 w524 h36 ReadOnly -VScroll", "")
    PaletteInsert := PaletteWindow.AddButton("x16 y386 w180 h32 Default", "選んだ弾幕を入力")
    PaletteInsert.OnEvent("Click", InsertPaletteItem)
    PaletteManageButton := PaletteWindow.AddButton("x204 y386 w160 h32", "弾幕を追加・編集")
    PaletteManageButton.OnEvent("Click", (*) => ShowManagement())
    PaletteHint := PaletteWindow.AddText("x16 y426 w524 h24", "弾幕は入力のみ。内容を確認してYouTubeで送信します。")
    PaletteReactionHeading := PaletteWindow.AddText("x16 y460 w260 h24", "今回のリアクション")
    PaletteReactionHeading.SetFont("bold")
    PaletteOptionLabels := []
    for label in ["種類","回数","間隔"]
        PaletteOptionLabels.Push(PaletteWindow.AddText("x16 y480 w120 h20",label))
    PaletteChoice := PaletteWindow.AddDropDownList("x16 y490 w160", ReactionNames)
    PaletteCount := PaletteWindow.AddDropDownList("x184 y490 w120", SettingOptionLabels(ReactionCounts, "回"))
    intervalLabels := ReactionIntervalLabels(), intervalLabels[1] := "待機なし"
    PaletteInterval := PaletteWindow.AddDropDownList("x312 y490 w228", intervalLabels)
    PaletteInterval.OnEvent("Change",RefreshPaletteIntervalHint)
    PaletteIntervalHint := PaletteWindow.AddText("x16 y524 w524 h24", "処理間隔：処理時間を含みます。待機なしは追加待機なし。")
    PaletteStart := PaletteWindow.AddButton("x16 y556 w170 h32", "リアクションを開始（3秒後）")
    PaletteStart.OnEvent("Click", StartPaletteReaction)
    PaletteStop := PaletteWindow.AddButton("x194 y556 w80 h32", "停止")
    PaletteStop.OnEvent("Click", CancelReaction)
    PaletteDefaults := PaletteWindow.AddButton("x282 y556 w132 h32", "標準設定に保存")
    PaletteDefaults.OnEvent("Click", SavePaletteDefaults)
    PaletteReset := PaletteWindow.AddButton("x422 y556 w118 h32", "標準設定を読み込む")
    PaletteReset.OnEvent("Click", (*) => ResetPaletteSession())
    PaletteSettingsStatus := PaletteWindow.AddText("x16 y598 w524 h36", "")
    PaletteStatusControl := PaletteWindow.AddText("x16 y598 w524 h42", LastReactionResult.Message)
    PaletteWindow.OnEvent("Close", HidePalette)
    PaletteWindow.OnEvent("Escape", HidePalette)
    PaletteWindow.OnEvent("Size", ResizePalette)
    PaletteStop.Visible := false
    PaletteStop.Enabled := false
    ResetPaletteSession()
    RefreshPalette()
    global PaletteViewport := PanelViewport(PaletteWindow,360,620,LayoutPalette)
}


LayoutPalette(gui, state, width, height) {
    if state = -1
        return
    full := Max(328, width-32), half := Floor((full-8)/2)
    PaletteTitle.Move(,,Max(100,width-158))
    PaletteMenuButton.Move(width-126)
    PaletteContext.Move(,,full)
    if width < 420 {
        PaletteMode.Move(16,,90)
        PaletteProfile.Move(114,,full-206)
        PaletteBind.Move(width-116,,100)
        PaletteBind.Text := "連携…"
    } else {
        PaletteMode.Move(16,,110)
        PaletteProfile.Move(134,,width-296)
        PaletteBind.Move(width-154,,138)
        PaletteBind.Text := "チャンネル連携…"
    }
    PaletteSearch.Move(,,full)
    listHeight := Max(60,height-560), base := 220+listHeight
    PalettePreview.Move(16,180+listHeight,full,36)
    PaletteList.Move(,,full,listHeight)
    PaletteList.ModifyCol(1,64), PaletteList.ModifyCol(2,Max(100,full-174)), PaletteList.ModifyCol(3,86)
    PaletteInsert.Move(16,base,half,32)
    ; Controls below the list reflow to two rows for narrow screens.
    PaletteManageButton.Move(24+half,base,half,32)
    PaletteReactionHeading.Move(16,base+74,full,22)
    PaletteIntervalHint.Move(16,base+146,full,32)
    PaletteHint.Move(16,base+36,full,36)
    third := Floor((full-16)/3)
    for i, label in PaletteOptionLabels
        label.Move(16+(i-1)*(third+8),base+98,third,18)
    PaletteChoice.Move(16,base+118,third), PaletteCount.Move(24+third,base+118,third)
    PaletteInterval.Move(32+third*2,base+118,third)
    PaletteStart.Move(16,base+180,PaletteStop.Visible ? half : full,36), PaletteStop.Move(24+half,base+180,half,36)
    PaletteDefaults.Move(16,base+226,half,28), PaletteReset.Move(24+half,base+226,half,28)
    PaletteSettingsStatus.Move(16,base+260,full,36)
    PaletteStatusControl.Move(16,base+300,full,36)
}


OpenPaletteMenu(*) {
    popup := Menu()
    popup.Add("弾幕・配信者を管理", (*) => ShowManagement(1))
    popup.Add("リアクションの標準設定", (*) => ShowManagement(2))
    popup.Add("操作・サポート", (*) => ShowManagement(3))
    popup.Add("リアクションの実行結果", ShowReactionDetails)
    popup.Add("診断情報", ShowDiagnostics)
    popup.Add("終了", (*) => ExitApp())
    popup.Show()
}


RefreshPalette() {
    PaletteMode.Choose(AutoMode ? 1 : 2)
    names := []
    for profile in Profiles
        names.Push(profile.Name)
    PaletteProfile.Delete(), PaletteProfile.Add(names)
    if InputProfileIndex
        PaletteProfile.Choose(InputProfileIndex)
    PaletteProfile.Enabled := !AutoMode && Profiles.Length > 0
    profile := GetInputProfile()
    matched := !AutoMode || (DetectedChannel.State = "ok" && ChannelIndex.Get(DetectedChannel.Channel,0) = InputProfileIndex && InputProfileIndex > 0)
    if AutoMode && !matched
        PaletteProfile.Choose(0)
    PaletteContext.Text := "弾幕の入力対象：" (profile && matched ? profile.Name : "共通の弾幕のみ")
        . "`n" (AutoMode ? DetectionMessage : "手動選択：下の欄で配信者を選べます。")
    RefreshPaletteItems()
    UpdateTray()
}


RefreshPaletteItems() {
    global PaletteRows := []
    PaletteList.Delete()
    query := Trim(PaletteSearch.Value)
    profile := GetInputProfile()
    matched := !AutoMode || (DetectedChannel.State = "ok" && ChannelIndex.Get(DetectedChannel.Channel,0) = InputProfileIndex && InputProfileIndex > 0)
    if profile && matched
        AddPaletteItems(profile.Items, false, query)
    AddPaletteItems(SharedDanmakuItems, true, query)
    if PaletteRows.Length
        PaletteList.Modify(1,"Select Focus")
    PreviewPaletteItem()
    PaletteInsert.Enabled := PaletteRows.Length > 0
    PaletteHint.Text := PaletteRows.Length ? "弾幕は入力のみ。内容を確認してYouTubeで送信します。" : (query != "" ? "一致する弾幕がありません。検索条件を変えてください。" : "「弾幕を追加・編集」から登録できます。共通弾幕は配信者不要です。")
}


AddPaletteItems(items, shared, query) {
    for i, item in items {
        if query != "" && !InStr(item.Name " " item.Text, query)
            continue
        slot := ItemSlot(item)
        PaletteList.Add("", shared ? "共通" : "配信者", item.Name "　" item.Text, slot ? "Ctrl+Alt+" (slot+(shared ? 2 : 0)) : "")
        PaletteRows.Push({Shared:shared, Index:i, ProfileId:!shared && GetInputProfile() ? GetInputProfile().Id : "", Text:item.Text})
    }
}


InsertPaletteItem(*) {
    if IsBrowserOperationBusy || ActiveReactionJob || DanmakuEditorWindow
        return
    index := PaletteList.GetNext()
    if !index
        return
    row := PaletteRows[index]
    items := row.Shared ? SharedDanmakuItems : (GetInputProfile() && GetInputProfile().Id = row.ProfileId ? GetInputProfile().Items : [])
    if row.Index > items.Length || items[row.Index].Text != row.Text {
        RefreshPalette()
        return
    }
    if row.Shared
        RequestDanmakuInput(true,row.Index,TargetBrowserHwnd,false,true)
    else
        RequestDanmakuInput(false,row.Index,TargetBrowserHwnd,false,true,row.ProfileId)
}


ChangePaletteMode(*) {
    global AutoMode
    try SaveAutoDetection(PaletteMode.Value = 1)
    catch as failure {
        PaletteMode.Choose(AutoMode ? 1 : 2)
        PaletteHint.Text := "保存できませんでした。" failure.Message
        return
    }
    if AutoMode && IsBrowser(TargetBrowserHwnd)
        SelectProfileFromBrowser(TargetBrowserHwnd)
    RefreshPalette()
}


SelectPaletteProfile(*) {
    try SaveInputProfileSelection(PaletteProfile.Value)
    catch as failure {
        RefreshPalette()
        PaletteHint.Text := "選択を保存できませんでした。" failure.Message
        return
    }
    RefreshPalette()
}


SetDetectionStatus(message) {
    global DetectionMessage := message
    if IsSet(PaletteContext)
        RefreshPalette()
}


ResetPaletteSession(*) {
    PaletteChoice.Choose(DefaultReactionKind)
    ChooseSetting(PaletteCount,ReactionCounts,DefaultReactionCount)
    ChooseSetting(PaletteInterval,ReactionIntervals,DefaultReactionIntervalMs)
    RefreshPaletteIntervalHint()
    PaletteSettingsStatus.Text := "標準設定を読み込みました。`n変更は今回の実行だけに適用します。"
}

PaletteOptions() {
    return CreateReactionOptions(PaletteChoice.Value, ReactionCounts[PaletteCount.Value], ReactionIntervals[PaletteInterval.Value], ReactionShortcut)
}

StartPaletteReaction(*) {
    ScheduleReaction("reaction_send",3,PaletteOptions())
}

SavePaletteDefaults(*) {
    if IsBrowserOperationBusy || ActiveReactionJob
        return
    try SaveReactionDefaults(PaletteOptions())
    catch as failure {
        PaletteSettingsStatus.Text := "保存できませんでした。" failure.Message
        return
    }
    RefreshReactionDefaultControls()
    PaletteSettingsStatus.Text := "標準設定を保存しました。`nショートカット実行にも使います。"
}


PreviewPaletteItem(*) {
    index := PaletteList.GetNext()
    PaletteInsert.Enabled := index > 0
    PalettePreview.Value := index && index <= PaletteRows.Length ? PaletteRows[index].Text : ""
}

RefreshPaletteIntervalHint(*) {
    PaletteIntervalHint.Text := PaletteInterval.Value = 1
        ? "前の操作が終わり次第、次を実行します。"
        : "指定間隔には処理時間を含みます。`n処理が長い場合は、指定より遅くなります。"
}


ResizePalette(gui, state, width, height) {
    if state = -1
        return
    if IsSet(PaletteViewport)
        PaletteViewport.Resize()
    else
        LayoutPalette(gui,state,width,height)
}
