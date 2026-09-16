; View construction, rendering, and UI event adapters.
BuildPanel() {
    global MainWindow, FeatureTabs, PanelStatusText, UiX, UiY
    MainWindow := Gui("", "ChatPalette")
    MainWindow.BackColor := "F5F7FA"
    MainWindow.SetFont("s10", "Yu Gothic UI")
    MainWindow.MarginX := 16, MainWindow.MarginY := 16
    MainWindow.AddText("x20 y14 w460 h30 c183153", "ChatPalette").SetFont("s16 bold")
    MainWindow.AddText("x20 y48 w500 h22 c526174", "YouTube向けの弾幕入力・リアクション補助ツール")
    MainWindow.AddButton("x482 y22 w108 h30", "診断情報").OnEvent("Click", ShowDiagnostics)
    MainWindow.AddButton("x600 y22 w140 h30", "使い方").OnEvent("Click", Help)
    FeatureTabs := MainWindow.AddTab3("x16 y82 w728 h522 Choose1", ["ホーム", "弾幕ライブラリ", "投稿者別設定", "共通設定", "環境・登録"])
    UiX := 32, UiY := 120
    FeatureTabs.UseTab(1)
    BuildHomeView()
    FeatureTabs.UseTab(2)
    BuildLibraryView()
    FeatureTabs.UseTab(3)
    BuildProfileView()
    FeatureTabs.UseTab(4)
    BuildCommonView()
    FeatureTabs.UseTab(5)
    BuildEnvironmentView()
    FeatureTabs.UseTab()
    PanelStatusText := MainWindow.AddText("x20 y614 w720 h36 c526174", "")
    MainWindow.AddText("x20 y656 w720 h22 c526174", "Ctrl＋Alt＋Q：開く／進捗を見る　　Esc：実行を停止／画面を隠す")
    FeatureTabs.OnEvent("Change", UpdateTabContext)
    MainWindow.OnEvent("Close", HidePanel)
    MainWindow.OnEvent("Escape", HidePanel)
    RefreshProfiles()
    UpdateTabContext()
}

UiText(x, y, w, h, text, heading := false) {
    control := MainWindow.AddText("x" (UiX+x) " y" (UiY+y) " w" w " h" h " c" (heading ? "183153" : "334155"), text)
    if heading
        control.SetFont("bold")
    return control
}
UiButton(x, y, w, text, callback) {
    control := MainWindow.AddButton("x" (UiX+x) " y" (UiY+y) " w" w " h32", text)
    control.OnEvent("Click", callback)
    return control
}
UiLine(y) {
    MainWindow.AddText("x" UiX " y" (UiY+y) " w692 h2 0x10")
}

BeginWorkerWait(mode) {
    enabled := !!DllCall("IsWindowEnabled", "Ptr", MainWindow.Hwnd)
    MainWindow.Opt("+Disabled")
    message := mode = "resolve" ? "YouTubeの投稿者を確認しています…"
        : mode = "verify" || mode = "reaction_context" ? "YouTubeの動画を確認しています…"
        : mode = "verify_input" ? "チャット欄・コメント欄を確認しています…"
        : "リアクションの操作対象を確認しています…"
    notification := () => ToolTip(message)
    SetTimer(notification, -400)
    return {Enabled: enabled, Notification: notification}
}

EndWorkerWait(view) {
    SetTimer(view.Notification, 0)
    if view.Enabled && !DanmakuEditorWindow && !ProfileManagerActive
        MainWindow.Opt("-Disabled")
    ToolTip()
}

ShowInputFailure() {
    ToolTip("入力を止めました。YouTubeのチャット欄またはコメント欄をクリックして再試行してください。")
    SetTimer(() => ToolTip(), -2800)
}

BuildHomeView() {
    global HomeAuthor, HomeDanmaku, ReactionSettingsInfo, ReactionInfo, HomeInput, HomeCommon, HomeCommonInput
    HomeAuthor := UiText(0, 0, 692, 44, "", true)
    UiLine(50)
    UiText(0, 66, 320, 24, "投稿者別の弾幕　Ctrl＋Alt＋1／2", true)
    HomeDanmaku := MainWindow.AddDropDownList("x" UiX " y" (UiY+102) " w320", [])
    HomeInput := UiButton(0, 148, 190, "選んだ弾幕を入力", InsertHomeProfileDanmaku)
    UiButton(202, 148, 118, "編集する", (*) => OpenLibrary(false))
    UiText(0, 192, 320, 24, "共通の弾幕　Ctrl＋Alt＋3／4", true)
    HomeCommon := MainWindow.AddDropDownList("x" UiX " y" (UiY+220) " w320", [])
    HomeCommonInput := UiButton(0, 258, 190, "共通の弾幕を入力", InsertHomeSharedDanmaku)
    UiButton(202, 258, 118, "編集する", (*) => OpenLibrary(true))
    UiText(0, 294, 320, 22, "弾幕は入力のみ。送信はYouTubeで。")
    UiText(364, 66, 320, 24, "リアクションを送る", true)
    ReactionSettingsInfo := UiText(364, 102, 320, 104, "")
    UiButton(364, 216, 196, "3秒後に送信を開始", (*) => ScheduleReaction("reaction_send", 3))
    UiButton(572, 216, 112, "設定する", (*) => NavigatePanel(4))
    UiText(364, 260, 320, 42, "YouTubeの♡メニューを開いてください。`n実行中はEscで停止できます。")
    UiLine(318)
    UiText(0, 334, 480, 24, "直近の操作結果", true)
    UiButton(560, 330, 124, "結果の詳細", ShowReactionDetails)
    ReactionInfo := UiText(0, 376, 692, 88, "まだ実行していません。")
}

BuildLibraryView() {
    global LibraryScope, LibraryDescription, LibraryManage, TransferButton
    global LibraryProfilePicker, DetectionLabel, BindShortcut, DanmakuListView, DanmakuPreview, EditButton, DuplicateButton, UpButton, DownButton, DeleteButton, UndoButton
    LibraryScope := MainWindow.AddDropDownList("x" UiX " y" UiY " w200 Choose1", ["投稿者別の弾幕", "共通の弾幕"])
    LibraryScope.OnEvent("Change", ChangeLibraryScope)
    LibraryDescription := UiText(220, 0, 464, 24, "選択した投稿者で使用・Ctrl＋Alt＋1／2")
    LibraryProfilePicker := MainWindow.AddDropDownList("x" UiX " y" (UiY+30) " w400", [])
    LibraryProfilePicker.OnEvent("Change", ChangeProfile)
    LibraryManage := UiButton(418, 28, 266, "投稿者・チャンネル管理", ShowProfileManager)
    DetectionLabel := UiText(0, 70, 514, 44, AutoMode ? "自動判別ON：YouTubeからCtrl＋Alt＋Qで判別します。" : "手動選択：選択した投稿者を使用します。")
    BindShortcut := UiButton(532, 70, 152, "関連付ける", ShowProfileManager)
    BindShortcut.Visible := false
    DanmakuListView := MainWindow.AddListView("x" UiX " y" (UiY+122) " w692 h174 -Multi", ["キー", "弾幕名", "入力文字列"])
    DanmakuListView.OnEvent("ItemSelect", ShowPreview)
    DanmakuListView.OnEvent("DoubleClick", (*) => OpenDanmakuEditor(false))
    DanmakuPreview := MainWindow.AddEdit("x" UiX " y" (UiY+306) " w692 h46 ReadOnly", "")
    UiButton(0, 368, 88, "追加", (*) => OpenDanmakuEditor(true))
    EditButton := UiButton(100, 368, 88, "編集", (*) => OpenDanmakuEditor(false))
    DuplicateButton := UiButton(200, 368, 88, "複製", DuplicateSelectedDanmaku)
    UpButton := UiButton(300, 368, 80, "↑ 上へ", (*) => MoveSelectedDanmaku(-1))
    DownButton := UiButton(392, 368, 80, "↓ 下へ", (*) => MoveSelectedDanmaku(1))
    DeleteButton := UiButton(484, 368, 88, "削除", DeleteSelectedDanmaku)
    UndoButton := UiButton(0, 412, 188, "直前の操作を戻す", UndoLibraryChange)
    UndoButton.Enabled := false
    TransferButton := UiButton(204, 412, 180, "共通へ移す", TransferSelectedDanmaku)
    UiText(400, 410, 284, 54, "変更はその都度保存されます。`n先頭2件がキーに割り当てられます。")
}

BuildProfileView() {
    global ProfilePicker, ProfileDetectionLabel, ProfileBindShortcut, ProfileSettingsLabel, ReactionScope, ReactionChoice, ProfileSaveButton, ProfileResetButton, ProfileSettingsInfo
    UiText(0, 0, 500, 22, "投稿者別のリアクション", true)
    ProfilePicker := MainWindow.AddDropDownList("x" UiX " y" (UiY+30) " w400", [])
    ProfilePicker.OnEvent("Change", ChangeProfile)
    UiButton(418, 28, 266, "投稿者・チャンネル管理", ShowProfileManager)
    ProfileDetectionLabel := UiText(0, 70, 514, 44, DetectionLabel.Text)
    ProfileBindShortcut := UiButton(532, 70, 152, "関連付ける", ShowProfileManager)
    ProfileBindShortcut.Visible := false
    UiLine(126)
    ProfileSettingsLabel := UiText(0, 146, 684, 24, "", true)
    ReactionScope := MainWindow.AddCheckbox("x" UiX " y" (UiY+188) " w600", "共通の種類を上書きし、この投稿者専用の種類を使う")
    ReactionChoice := MainWindow.AddDropDownList("x" UiX " y" (UiY+228) " w320 Choose1", ReactionNames)
    UiText(0, 276, 684, 52, "チェックを外すと共通の種類に戻ります。`n回数・待ち時間・キーは「共通設定」で変更します。")
    UiLine(352)
    ProfileSaveButton := UiButton(0, 376, 230, "この投稿者の設定を保存", SaveProfileReactionEdits)
    ProfileResetButton := UiButton(246, 376, 200, "未保存の変更を戻す", DiscardProfileReactionEdits)
    ProfileSettingsInfo := UiText(0, 426, 684, 44, "")
    ReactionScope.OnEvent("Click", CaptureProfileReactionEdits)
    ReactionChoice.OnEvent("Change", CaptureProfileReactionEdits)
}

UpdateProfileDraftFromControls() {
    if ProfileReactionDraft
        ProfileReactionDraft.Reaction := ReactionScope.Value ? ReactionChoice.Value : 0
}

UpdateSharedDraftFromControls() {
    global SharedReactionDraft
    SharedReactionDraft := CreateSharedReactionDraft(ReactionDefaultChoice.Value,
        ReactionCounts[ReactionCountChoice.Value], ReactionIntervals[ReactionIntervalChoice.Value], ReactionKeyControl.Value)
}

BuildCommonView() {
    global ReactionDefaultChoice, ReactionCountChoice, ReactionIntervalChoice, ReactionKeyControl, ReactionSaveButton, ReactionResetButton, CommonSettingsInfo
    UiText(0, 0, 684, 24, "全投稿者に共通のリアクション設定", true)
    UiText(0, 40, 260, 22, "既定の種類")
    ReactionDefaultChoice := MainWindow.AddDropDownList("x" UiX " y" (UiY+70) " w320 Choose" ReactionDefault, ReactionNames)
    UiText(352, 70, 332, 44, "投稿者別に種類を指定している場合は、`n投稿者別設定が優先されます。")
    UiText(0, 124, 220, 22, "1回の実行で操作する回数")
    ReactionCountChoice := MainWindow.AddDropDownList("x" UiX " y" (UiY+154) " w200", SettingOptionLabels(ReactionCounts, "回"))
    for i, value in ReactionCounts
        if value = ReactionCount
            ReactionCountChoice.Choose(i)
    UiText(236, 124, 240, 22, "操作の完了後に待つ時間")
    ReactionIntervalChoice := MainWindow.AddDropDownList("x" (UiX+236) " y" (UiY+154) " w200", SettingOptionLabels(ReactionIntervals, " ms"))
    for i, value in ReactionIntervals
        if value = ReactionInterval
            ReactionIntervalChoice.Choose(i)
    UiText(0, 198, 684, 24, "実際の操作間隔には、検出・操作にかかる時間も加わります。")
    UiLine(236)
    UiText(0, 254, 684, 22, "送信ショートカット", true)
    ReactionKeyControl := MainWindow.AddHotkey("x" UiX " y" (UiY+286) " w320", ReactionShortcut)
    UiButton(352, 282, 224, "Ctrl＋Alt＋R に戻す", ResetReactionKey)
    UiText(0, 326, 684, 44, "キー欄をクリック → Ctrl＋Alt（またはCtrl＋Shift）と英数字キーを押す。`nすべてのキーを離し、下の「共通設定を保存」を押してください。")
    UiLine(380)
    ReactionSaveButton := UiButton(0, 398, 230, "共通設定を保存", SaveSharedReactionEdits)
    ReactionResetButton := UiButton(246, 398, 200, "未保存の変更を戻す", DiscardSharedReactionEdits)
    CommonSettingsInfo := UiText(0, 444, 684, 28, "")
    for control in [ReactionDefaultChoice, ReactionCountChoice, ReactionIntervalChoice, ReactionKeyControl]
        control.OnEvent("Change", CaptureSharedReactionEdits)
}

BuildEnvironmentView() {
    global AutoCheck
    UiText(0, 0, 684, 24, "投稿者の選び方", true)
    AutoCheck := MainWindow.AddCheckbox("x" UiX " y" (UiY+42) " w600", "表示中の動画から投稿者を自動判別する")
    AutoCheck.Value := AutoMode
    AutoCheck.OnEvent("Click", ToggleAuto)
    UiText(0, 84, 684, 68, "ON：関連付け済みの投稿者へ自動で切り替えます。`nOFF：弾幕ライブラリ／投稿者別設定で選んだ投稿者を使います。`nこの変更はすぐに保存されます。")
    UiLine(174)
    UiText(0, 194, 684, 24, "ブラウザーの準備", true)
    UiText(0, 236, 684, 48, "初回、またはリアクションメニューを検出できない場合に使います。`n正常に動いている場合、再登録は不要です。")
    UiButton(0, 304, 240, "操作ボタンを登録・再登録", (*) => ScheduleReaction("reaction_capture", 0))
    UiButton(256, 304, 200, "送信せずに検出を確認", (*) => ScheduleReaction("reaction_check", 5))
    UiText(0, 354, 684, 54, "登録開始後はYouTubeの♡にマウスを重ねてください。`n5種類のボタンを検出すると登録が完了します。Escで中止できます。")
}

UpdateTabContext(*) {
    PanelStatusText.Visible := FeatureTabs.Value <= 2
    RefreshReactionUI()
}

NavigatePanel(page) {
    FeatureTabs.Choose(page)
    UpdateTabContext()
}

InsertHomeProfileDanmaku(*) {
    if !HomeDanmaku.Value
        return
    InsertProfileDanmaku(HomeDanmaku.Value, TargetBrowserHwnd, true)
}

RefreshHome() {
    HomeAuthor.Text := !GetSelectedProfile() ? "投稿者は未登録です。「投稿者別設定」→「投稿者・チャンネル管理」から追加できます。" : "選択中：" Profiles[SelectedProfileIndex].Name "`n" (AutoMode ? "自動判別ON：実行時の動画によって適用する投稿者が変わります。" : "手動選択：この投稿者の設定を使います。")
    names := []
    for item in GetDanmakuItems(false, GetSelectedProfile())
        names.Push(item.Name)
    selected := HomeDanmaku.Value
    HomeDanmaku.Delete()
    HomeDanmaku.Add(names)
    if names.Length
        HomeDanmaku.Choose(Min(Max(selected, 1), names.Length))
    HomeInput.Enabled := names.Length > 0
    names := []
    for item in SharedDanmakuItems
        names.Push(item.Name)
    selected := HomeCommon.Value
    HomeCommon.Delete()
    HomeCommon.Add(names)
    if names.Length
        HomeCommon.Choose(Min(Max(selected, 1), names.Length))
    HomeCommonInput.Enabled := names.Length > 0
}

BuildProfileManager() {
    manager := Gui("+Owner" MainWindow.Hwnd, "投稿者・チャンネル管理")
    manager.BackColor := "F5F7FA"
    manager.SetFont("s10", "Yu Gothic UI")
    candidate := DetectedChannel.State = "ok" ? DetectedChannel : 0, undo := 0
    manager.AddText("x12 y12 w210", "投稿者一覧")
    listing := manager.AddListBox("x12 y38 w210 h350", [])
    listing.OnEvent("Change", SelectProfile)
    manager.AddButton("x12 y400 w210", "投稿者を追加").OnEvent("Click", AddManaged)
    manager.AddText("x244 y12 w460", "基本情報（このツール内の表示名）").SetFont("bold")
    title := manager.AddText("x244 y40 w460", "")
    renameButton := manager.AddButton("x244 y68 w130", "名前変更")
    renameButton.OnEvent("Click", RenameManaged)
    addDanmakuButton := manager.AddButton("x388 y68 w160", "弾幕を追加する…")
    addDanmakuButton.OnEvent("Click", AddDanmaku)
    manager.AddText("x244 y110 w460 h2 0x10")
    manager.AddText("x244 y122 w460", "現在の関連付け").SetFont("bold")
    channel := manager.AddEdit("x244 y148 w460 ReadOnly", "")
    unlink := manager.AddButton("x244 y180 w160", "関連付けを解除")
    unlink.OnEvent("Click", UnlinkManaged)
    manager.AddText("x244 y222 w460", "YouTubeから検出した変更候補").SetFont("bold")
    candidateText := manager.AddText("x244 y250 w460 r3", "未検出です。YouTubeからCtrl＋Alt＋Qで開き、「再検出」を押してください。")
    manager.AddButton("x244 y318 w100", "再検出").OnEvent("Click", DetectCandidate)
    bind := manager.AddButton("x356 y318 w160 Disabled", "関連付ける")
    bind.OnEvent("Click", BindManaged)
    jump := manager.AddButton("x528 y318 w176 Disabled", "関連付け先を表示")
    jump.OnEvent("Click", JumpAssigned)
    result := manager.AddText("x244 y362 w460 r3", "操作はこの画面で保存されます。取り消しは次の変更または画面を閉じるまで有効です。")
    undoButton := manager.AddButton("x244 y428 w160 Disabled", "直前の変更を戻す")
    undoButton.OnEvent("Click", UndoManaged)
    manager.AddText("x244 y474 w460 h2 0x10")
    deleteProfileButton := manager.AddButton("x244 y486 w200", "この投稿者を削除…")
    deleteProfileButton.OnEvent("Click", DeleteManaged)
    manager.OnEvent("Close", CloseManager)
    manager.OnEvent("Escape", CloseManager)
    RefreshManager()
    return manager

    RefreshManager() {
        names := []
        for p in Profiles
            names.Push(p.Name)
        listing.Delete()
        listing.Add(names)
        listing.Choose(SelectedProfileIndex)
        renameButton.Enabled := addDanmakuButton.Enabled := deleteProfileButton.Enabled := !!GetSelectedProfile()
        title.Text := !GetSelectedProfile() ? "投稿者は未登録です。左の「投稿者を追加」から登録してください。" : Profiles[SelectedProfileIndex].Name "（弾幕 " Profiles[SelectedProfileIndex].Items.Length "件）"
        channel.Value := GetSelectedProfile() && Profiles[SelectedProfileIndex].Channel != "" ? Profiles[SelectedProfileIndex].Channel : "未関連付け"
        unlink.Enabled := GetSelectedProfile() && Profiles[SelectedProfileIndex].Channel != ""
        bind.Text := GetSelectedProfile() && Profiles[SelectedProfileIndex].Channel != "" ? "関連付けを変更" : "関連付ける"
        assigned := candidate ? ChannelIndex.Get(candidate.Channel, 0) : 0
        bind.Enabled := !!GetSelectedProfile() && !!candidate && assigned != -1 && (assigned = 0 || assigned = SelectedProfileIndex) && Profiles[SelectedProfileIndex].Channel != candidate.Channel
        jump.Enabled := assigned > 0 && assigned != SelectedProfileIndex
        if candidate
            candidateText.Text := candidate.Author "`n" candidate.Channel "`n" (assigned > 0 ? "関連付け済み：" Profiles[assigned].Name : assigned = -1 ? "関連付けが重複しています。各投稿者の関連付けを確認してください。" : "未関連付け")
        undoButton.Enabled := !!undo
        RefreshProfiles()
    }
    SelectProfile(*) {
        if !SelectCurrentProfile(listing.Value)
            return
        RefreshManager()
        result.Text := "選択中：" Profiles[SelectedProfileIndex].Name
    }
    Commit(action, value, message) {
        try {
            undo := ExecuteProfileCommand(action, SelectedProfileIndex, value, undo)
            RefreshManager()
            result.Text := message
        } catch as failure {
            result.Text := "変更を保存できませんでした。" failure.Message
        }
    }
    AddManaged(*) {
        global SelectedProfileIndex
        manager.Opt("+OwnDialogs")
        reply := InputBox("このツール内の表示名", "投稿者を追加", "w360 h130")
        if reply.Result != "OK" || !Trim(reply.Value)
            return
        Commit("add", reply.Value, "追加しました。「再検出」でチャンネルを関連付けるか、「弾幕を追加する」へ進めます。")
    }
    RenameManaged(*) {
        manager.Opt("+OwnDialogs")
        reply := InputBox("このツール内の表示名（YouTubeの名前は変わりません）", "名前変更", "w400 h140", Profiles[SelectedProfileIndex].Name)
        if reply.Result != "OK" || !Trim(reply.Value) || reply.Value = Profiles[SelectedProfileIndex].Name
            return
        Commit("rename", reply.Value, "表示名を変更しました。")
    }
    DetectCandidate(*) {
        if IsBrowserOperationBusy
            return
        candidate := 0
        manager.Opt("+Disabled")
        try {
            DetectedChannel := ResolveBrowserChannel(TargetBrowserHwnd)
            if DetectedChannel.State = "ok" {
                candidate := DetectedChannel
                result.Text := "検出候補を確認してから関連付けてください。"
            } else {
                candidateText.Text := "検出できません。YouTubeからCtrl＋Alt＋Qで開き直してください。"
                result.Text := "関連付けは変更していません。"
            }
        } finally {
            manager.Opt("-Disabled")
            RefreshManager()
        }
    }
    BindManaged(*) {
        if !candidate || IsBrowserOperationBusy
            return
        manager.Opt("+Disabled")
        try {
            fresh := ResolveBrowserChannel(TargetBrowserHwnd)
        } finally {
            manager.Opt("-Disabled")
        }
        if fresh.State != "ok" || fresh.Channel != candidate.Channel {
            candidate := 0
            candidateText.Text := "動画または検出候補が変わりました。「再検出」してください。"
            RefreshManager()
            return
        }
        assigned := ChannelIndex.Get(candidate.Channel, 0)
        if assigned && assigned != SelectedProfileIndex {
            RefreshManager()
            return
        }
        manager.Opt("+OwnDialogs")
        if Profiles[SelectedProfileIndex].Channel != "" && MsgBox("現在：" Profiles[SelectedProfileIndex].Channel "`n変更先：" candidate.Author "`n" candidate.Channel "`n関連付けを変更しますか？", "関連付けを変更", "YesNo Default2") != "Yes"
            return
        Commit("bind", candidate.Channel, "「" Profiles[SelectedProfileIndex].Name "」を「" candidate.Author "」に関連付けました。")
    }
    UnlinkManaged(*) {
        if Profiles[SelectedProfileIndex].Channel = ""
            return
        Commit("bind", "", "関連付けを解除しました。直前の変更を戻せます。")
    }
    JumpAssigned(*) {
        assigned := candidate ? ChannelIndex.Get(candidate.Channel, 0) : 0
        if assigned > 0 && SelectCurrentProfile(assigned) {
            RefreshManager()
            result.Text := "この投稿者に関連付け済みです。変更する場合は関連付けを解除してください。"
        }
    }
    DeleteManaged(*) {
        global SelectedProfileIndex
        manager.Opt("+OwnDialogs")
        if MsgBox("「" Profiles[SelectedProfileIndex].Name "」を削除しますか？`n弾幕 " Profiles[SelectedProfileIndex].Items.Length "件・チャンネルの関連付け・投稿者別リアクション設定が削除されます。", "投稿者を削除", "YesNo Default2 Icon?") != "Yes"
            return
        Commit("delete", "", "投稿者を削除しました。この画面で直前の変更を戻せます。")
    }
    UndoManaged(*) {
        global Profiles, SelectedProfileIndex
        if !undo
            return
        Commit("undo", "", "直前の変更を元に戻しました。")
    }
    AddDanmaku(*) {
        SetLibraryScope(false)
        CloseManager()
        NavigatePanel(2)
        OpenDanmakuEditor(true)
    }
    CloseManager(*) {
        global ProfileManagerActive := false
        MainWindow.Opt("-Disabled")
        manager.Hide()
    }
}

OpenDanmakuEditor(isNew) {
    if !IsSharedLibrarySelected && !GetSelectedProfile() {
        ShowProfileManager()
        return
    }
    global DanmakuEditorWindow
    items := GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())
    n := isNew ? 0 : DanmakuListView.GetNext()
    if !isNew && !n
        return
    DanmakuEditorWindow := Gui("+Owner" MainWindow.Hwnd, isNew ? "弾幕を追加" : "弾幕を編集")
    DanmakuEditorWindow.BackColor := "F5F7FA"
    DanmakuEditorWindow.SetFont("s10", "Yu Gothic UI")
    DanmakuEditorWindow.AddText("w480", "編集対象：" (IsSharedLibrarySelected ? "共通（すべての投稿者）" : Profiles[SelectedProfileIndex].Name)).SetFont("bold")
    DanmakuEditorWindow.AddText(, "弾幕名（例：定番、サビ、拍手）")
    label := DanmakuEditorWindow.AddEdit("w480", n ? items[n].Name : "")
    DanmakuEditorWindow.AddText(, "入力文字列（1行）")
    content := DanmakuEditorWindow.AddEdit("w480", n ? items[n].Text : "")
    DanmakuEditorWindow.AddButton("Default w100", "保存").OnEvent("Click", SaveItem)
    DanmakuEditorWindow.AddButton("x+8 w100", "キャンセル").OnEvent("Click", CloseDanmakuEditor)
    DanmakuEditorWindow.OnEvent("Close", CloseDanmakuEditor)
    DanmakuEditorWindow.OnEvent("Escape", CloseDanmakuEditor)
    MainWindow.Opt("+Disabled")
    DanmakuEditorWindow.Show()

    SaveItem(*) {
        DanmakuEditorWindow.Opt("+OwnDialogs")
        if !Trim(label.Value) || !Trim(content.Value) {
            MsgBox("弾幕名と入力文字列を入力してください。", "入力内容の確認")
            return
        }
        item := {Name: Trim(label.Value), Text: content.Value}
        updated := CopyItems(items)
        SetDanmakuItem(updated, n, item)
        try SaveLibraryTargets([items], [updated])
        catch as failure {
            MsgBox("保存できませんでした。入力内容は保持しています。`n" failure.Message, "保存エラー")
            return
        }
        ClearLibraryUndo()
        CloseDanmakuEditor()
        RefreshRows(n ? n : items.Length)
    }
}

CloseDanmakuEditor(*) {
    global DanmakuEditorWindow
    MainWindow.Opt("-Disabled")
    DanmakuEditorWindow.Destroy()
    DanmakuEditorWindow := 0
    MainWindow.Show()
}

Help(*) {
    MainWindow.Opt("+OwnDialogs")
    MsgBox("【ホーム】`nYouTubeのチャット欄またはコメント欄をクリックしてCtrl＋Alt＋Q。弾幕を選んで入力します。送信はYouTube側で行ってください。`nリアクションは♡メニューを開いたまま実行。Escで停止、Ctrl＋Alt＋Qで進捗を確認できます。`n`n【弾幕ライブラリ】`n投稿者を選び、追加・編集・複製・並べ替え。ダブルクリックで編集します。`n投稿者別／共通を選んで編集します。Ctrl＋Alt＋1／2は投稿者別、3／4は共通の先頭2種類を入力します。`n`n【投稿者別設定／共通設定】`n種類の上書きは投稿者別、既定の種類・回数・待ち時間・キーは共通です。それぞれの画面で保存します。`n現在のリアクションキー：" ReactionKeyLabel() "`n`n【環境・登録】`n自動判別の切り替えと、ブラウザーの初回登録・検出確認。正常に動く場合は再登録不要です。`n`n×／Escは画面を隠します。終了はタスクトレイ → Exit。", "使い方")
}


SetLibraryScope(common) {
    global IsSharedLibrarySelected
    IsSharedLibrarySelected := common
    LibraryScope.Choose(common ? 2 : 1)
    UpdateLibraryScope()
    RefreshRows()
}

ChangeLibraryScope(*) {
    SetLibraryScope(LibraryScope.Value = 2)
}

UpdateLibraryScope() {
    LibraryProfilePicker.Enabled := LibraryManage.Enabled := !IsSharedLibrarySelected
    DetectionLabel.Visible := !IsSharedLibrarySelected
    BindShortcut.Visible := !IsSharedLibrarySelected && DetectedChannel.State = "ok" && ChannelIndex.Get(DetectedChannel.Channel, 0) = 0
    LibraryDescription.Text := IsSharedLibrarySelected ? "全投稿者で使用・Ctrl＋Alt＋3／4" : "選択した投稿者で使用・Ctrl＋Alt＋1／2"
    TransferButton.Text := IsSharedLibrarySelected ? "投稿者別へ移す" : "共通へ移す"
}

InsertHomeSharedDanmaku(*) {
    if HomeCommon.Value
        InsertSharedDanmaku(HomeCommon.Value, TargetBrowserHwnd, true)
}

OpenLibrary(common) {
    SetLibraryScope(common)
    NavigatePanel(2)
}

SetDetectionStatus(message) {
    DetectionLabel.Text := message
    ProfileDetectionLabel.Text := message
    missing := DetectedChannel.State = "ok" && ChannelIndex.Get(DetectedChannel.Channel, 0) = 0
    ProfileBindShortcut.Visible := missing
    BindShortcut.Visible := missing && !IsSharedLibrarySelected
}

RefreshProfiles() {
    names := []
    for p in Profiles
        names.Push(p.Name)
    LibraryProfilePicker.Delete()
    LibraryProfilePicker.Add(names)
    LibraryProfilePicker.Choose(SelectedProfileIndex)
    ProfilePicker.Delete()
    ProfilePicker.Add(names)
    ProfilePicker.Choose(SelectedProfileIndex)
    RefreshRows()
    RefreshReactionUI()
}

RefreshRows(selected := 1) {
    UndoButton.Enabled := !!LibraryUndoSnapshot
    DanmakuListView.Delete()
    for i, item in GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())
        DanmakuListView.Add("", i <= 2 ? "Ctrl＋Alt＋" (i + (IsSharedLibrarySelected ? 2 : 0)) : "", item.Name, item.Text)
    DanmakuListView.ModifyCol(1, 145)
    DanmakuListView.ModifyCol(2, 110)
    DanmakuListView.ModifyCol(3, 410)
    if GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile()).Length
        DanmakuListView.Modify(Min(selected, GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile()).Length), "Select Focus")
    ShowPreview()
    RefreshHome()
    UpdateTray()
}

ShowPreview(*) {
    n := DanmakuListView.GetNext()
    DanmakuPreview.Value := n ? GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())[n].Text : (!IsSharedLibrarySelected && !GetSelectedProfile() ? "投稿者が未登録です。「追加」から投稿者を登録してください。" : "「追加」から弾幕を登録してください。")
    if IsSet(EditButton) {
        EditButton.Enabled := DuplicateButton.Enabled := DeleteButton.Enabled := !!n
        TransferButton.Enabled := !!n && !!GetSelectedProfile()
        UpButton.Enabled := n > 1
        DownButton.Enabled := n > 0 && n < GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile()).Length
    }
}

RefreshReactionUI() {
    if !ReactionChoice
        return
    ProfileSettingsLabel.Text := ProfileReactionDraft ? "設定対象：" ProfileReactionDraft.Profile.Name : "投稿者を追加すると、投稿者別の種類を設定できます。"
    value := ProfileReactionDraft ? ProfileReactionDraft.Reaction : 0
    ReactionScope.Value := value >= 1 && value <= ReactionNames.Length
    ReactionChoice.Choose(ReactionScope.Value ? value : ReactionDefault)
    UpdateReactionSettingsInfo()
}

UpdateReactionSettingsInfo() {
    if !ReactionSettingsInfo
        return
    ReactionSaveButton.Enabled := ReactionResetButton.Enabled := HasUnsavedSharedReaction
    ProfileSaveButton.Enabled := ProfileResetButton.Enabled := HasUnsavedProfileReaction
    ReactionScope.Enabled := !!ProfileReactionDraft
    ReactionChoice.Enabled := !!ProfileReactionDraft && !!ReactionScope.Value
    ProfileSettingsInfo.Text := !ProfileReactionDraft ? "投稿者は未登録です。上の「投稿者・チャンネル管理」から追加してください。" : HasUnsavedProfileReaction ? "この投稿者の変更は未保存です。" : "この投稿者の設定は保存済みです。"
    CommonSettingsInfo.Text := HasUnsavedSharedReaction ? "共通のリアクション設定は未保存です。" : "共通のリアクション設定は保存済みです。"
    key := ReactionKeyLabel()
    choice := GetSelectedProfile() && Profiles[SelectedProfileIndex].Reaction ? Profiles[SelectedProfileIndex].Reaction : ReactionDefault
    ReactionSettingsInfo.Text := (HasUnsavedReactionSettings ? "未保存の変更があります。設定画面で保存してください。`n" : "")
        . ReactionNames[choice] (GetSelectedProfile() && Profiles[SelectedProfileIndex].Reaction ? "（投稿者別）" : "（共通）")
        . "`n" ReactionCount "回 / 待ち時間 " ReactionInterval " ms`n" key
        . (AutoMode ? "`n種類は実行時の動画から選びます。" : "")
}

RenderReactionStatus(message, final) {
    global ReactionStatusFinal
    SetTimer(HideFinishedReactionProgress, 0)
    ReactionStatusFinal := final
    ReactionInfo.Text := message
    if ReactionOverlayText
        ReactionOverlayText.Text := message "`n" ReactionProgressHint()
    if final
        SetTimer(HideFinishedReactionProgress, -4000)
}

ReactionProgressHint() {
    return ReactionStatusFinal ? "4秒後に表示を消します。結果はCtrl＋Alt＋Q → ホーム → 結果の詳細。"
        : "Esc：処理を停止　Ctrl＋Alt＋Q：進捗を表示"
}

HideFinishedReactionProgress() {
    if !ActiveReactionJob && ReactionOverlay
        ReactionOverlay.Hide()
}

ShowReactionProgress(*) {
    global ReactionOverlay, ReactionOverlayText
    if !ReactionOverlay {
        ReactionOverlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000020", "リアクション進捗")
        ReactionOverlay.SetFont("s10", "Yu Gothic UI")
        ReactionOverlayText := ReactionOverlay.AddText("w420 r6", "")
    }
    ReactionOverlayText.Text := ReactionInfo.Text "`n" ReactionProgressHint()
    ReactionOverlay.Show("NoActivate x20 y20")
    if ReactionStatusFinal
        SetTimer(HideFinishedReactionProgress, -4000)
}

ShowReactionDetails(*) {
    details := Gui("+Owner" MainWindow.Hwnd, "リアクション検出の詳細")
    details.SetFont("s10", "Yu Gothic UI")
    content := "最終結果：" ReactionLastResult "`r`n`r`n平均操作間隔はボタン操作の完了間隔です。YouTube側の受理間隔ではありません。`r`n`r`n検出の詳細：`r`n" ReactionLastDetail
    details.AddEdit("w680 r12 ReadOnly", StrReplace(content, " / ", "`r`n"))
    details.AddButton("w140", "内容をコピー").OnEvent("Click", (*) => A_Clipboard := content)
    details.OnEvent("Escape", (*) => details.Destroy())
    details.Show()
}

ReactionNotice(state, detail := "", suffix := "") {
    global ReactionLastDetail
    ReactionLastDetail := detail
    messages := Map(
        "registered", "5種類のボタンを登録しました。次は「送らずに確認」で検出を確認できます。",
        "ready", "5種類のリアクションを検出できました。送信はしていません。",
        "operated", "リアクションボタンを1回操作しました。YouTube側の受理は確認できません。",
        "save_failed", "登録情報を保存できませんでした。以前の登録は保持しています。フォルダーの書き込み権限を確認してください。",
        "not_registered", "このブラウザーの登録が必要です。「環境・登録」→「操作ボタンを登録・再登録」を実行してください。",
        "menu_closed", "登録したメニューが見つかりません。♡にマウスを重ねて5種類を表示してください。",
        "changed", "動画が変わったため中止しました。",
        "wrong_window", "操作先が変わったため中止しました。",
        "unsupported", "5種類を識別できませんでした。「結果の詳細」で原因を確認できます。",
        "cooldown", "直前に操作したため、今回の入力は受け付けませんでした。",
        "unknown", "操作結果を確認できませんでした。重複防止のため自動再送しません。",
        "unavailable", "動画または操作部を確認できませんでした。YouTubeを開いてやり直してください。")
    message := messages.Get(state, messages["unavailable"]) suffix
    SetReactionStatus(message, true)
    ToolTip(message)
    SetTimer(() => ToolTip(), -4000)
}


UpdateTray() {
    A_IconTip := "ChatPalette：" (GetSelectedProfile() ? Profiles[SelectedProfileIndex].Name : "投稿者未登録")
}
