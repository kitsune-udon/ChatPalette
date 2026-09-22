ReadDiagnosticSnapshot() {
    browser := "未選択（YouTubeからパネルを開くと表示）"
    hwnd := LastBrowserOperation.HasOwnProp("Window") ? LastBrowserOperation.Window : TargetBrowserHwnd
    if hwnd {
        try {
            process := StrLower(WinGetProcessName("ahk_id " hwnd))
            browsers := Map("chrome.exe","Chrome", "msedge.exe","Edge", "firefox.exe","Firefox",
                "brave.exe","Brave", "opera.exe","Opera", "vivaldi.exe","Vivaldi")
            browser := browsers.Get(process, "対象外のブラウザー")
        } catch {
            browser := "対象のウィンドウは閉じられています"
        }
    }
    modes := Map("なし","まだ実行していません", "resolve","配信者の自動判別", "verify","動画の確認",
        "verify_input","チャット欄・コメント欄の確認", "browser_context","現在の動画の確認",
        "chat_clear","チャット欄のクリア", "chat_focus","チャット欄への移動", "verify_chat","クリア前のチャット欄確認", "reactions_show","リアクションUIの表示操作",
        "reaction_capture","リアクションボタンの登録", "reaction_check","リアクションの検出確認",
        "reaction_send","リアクションボタンの操作", "reaction_status","リアクションの設定状態の確認")
    states := Map("未実行","まだ実行していません", "ok","確認できました", "registered","登録できました",
        "cleared","クリアキーを送りました（内容は未取得）", "focused","チャット欄へ移動しました", "hovered","表示用UIへマウスを移動しました（表示は未確認）",
        "configured","設定済み（認識は未確認）", "ready","操作対象を確認できました", "operated","ボタンを操作しました（受理は未確認）",
        "wrong_input","入力欄を確認できませんでした", "changed","動画が変わったため中止しました",
        "wrong_window","操作先が変わったため中止しました", "unavailable","情報を取得できませんでした",
        "unknown","操作結果を確認できませんでした", "cancelled","中止しました", "not_registered","操作ボタンが未登録です",
        "menu_closed","リアクションメニューが見つかりません", "unsupported","操作対象を識別できませんでした",
        "cooldown","操作間隔が短いため停止しました", "save_failed","登録情報を保存できませんでした", "sync_failed","登録情報を同期できませんでした")
    phases := Map("idle","待機中", "queued","キーを離すのを待っています", "running","実行中", "finished","終了")
    mode := modes.Has(LastBrowserOperation.Mode) ? LastBrowserOperation.Mode : "不明"
    state := states.Has(LastBrowserOperation.State) ? LastBrowserOperation.State : "不明"
    phase := phases.Has(ReactionExecutionStatus.Phase) ? ReactionExecutionStatus.Phase : "不明"
    return {CapturedAt:FormatTime(, "yyyy/MM/dd HH:mm:ss"), Version:AppVersion, Ahk:A_AhkVersion, OS:A_OSVersion,
        Source:AppSourceStatus(), StartedAt:AppStartedAt, Keys:EffectiveShortcutSummary(ReactionShortcut),
        Stage:LastBrowserOperation.HasOwnProp("Stage") ? LastBrowserOperation.Stage : "単一処理",
        Browser:browser, Worker:WorkerState.ProcessId && ProcessExist(WorkerState.ProcessId) ? "起動中" : "待機中（必要なときに起動）",
        Auto:AutoMode ? "ON" : "OFF", Settings:FileExist(SettingsDatabasePath) ? "あり" : "なし",
        Operation:modes.Get(mode, "不明な操作"), Result:states.Get(state, "不明な結果"),
        Duration:mode = "なし" ? "—（未実行）" : LastBrowserOperation.Duration " ms",
        Phase:phases.Get(phase, "不明"), ModeCode:mode, StateCode:state, PhaseCode:phase}
}

BuildDiagnosticReport(snapshot := 0) {
    info := snapshot ? snapshot : ReadDiagnosticSnapshot()
    return "ChatPalette " info.Version
        . "`r`n取得日時: " info.CapturedAt
        . "`r`n起動日時: " info.StartedAt " / " info.Source
        . "`r`n`r`n[直近の操作]"
        . "`r`n操作: " info.Operation " (" info.ModeCode ")"
        . "`r`n結果: " info.Result " (" info.StateCode ")"
        . "`r`n段階: " info.Stage
        . "`r`n処理時間: " info.Duration
        . "`r`nリアクション: " info.Phase " (" info.PhaseCode ")"
        . "`r`n`r`n[環境・動作状況]"
        . "`r`nAutoHotkey: " info.Ahk " / Windows: " info.OS
        . "`r`nブラウザー: " info.Browser
        . "`r`n補助プロセス: " info.Worker
        . "`r`n自動判別: " info.Auto " / 設定ファイル: " info.Settings
        . "`r`n`r`n[有効なキー]`r`n" info.Keys
}

ShowDiagnostics(*) {
    static panel := 0
    if !panel
        panel := CreateDiagnosticPanel()
    else
        panel.Refresh.Call()
    panel.Viewport.Show()
}

CreateDiagnosticPanel() {
    view := Gui("+Owner" PaletteWindow.Hwnd, "診断情報")
    view.BackColor := "F5F7FA"
    view.SetFont("s10 c334155", "Yu Gothic UI")
    view.AddText("x20 y14 w600 h30 c183153", "診断情報").SetFont("s16 bold")
    view.AddText("x20 y52 w600 h24", "動作状況を確認し、不具合の相談に必要な情報をコピーできます。")
    captured := view.AddText("x20 y130 w600 h22 c526174", "")
    view.AddGroupBox("x20 y162 w600 h168", "直近の操作")
    operation := Row(190, "操作")
    result := Row(220, "結果")
    duration := Row(250, "処理時間")
    phase := Row(280, "リアクション")
    view.AddGroupBox("x20 y346 w600 h216", "環境・動作状況")
    version := Row(374, "アプリ")
    runtime := Row(406, "AutoHotkey")
    os := Row(438, "OS")
    browser := Row(470, "ブラウザー")
    worker := Row(502, "補助プロセス")
    settings := Row(534, "設定")
    source := view.AddText("x20 y574 w600 h42 c526174", "")
    view.AddButton("x20 y616 w180 h26","ショートカットを管理").OnEvent("Click",(*) => ShowShortcutManager())
    view.AddButton("x212 y616 w180 h26","アプリを再起動").OnEvent("Click",RestartApplication)
    refreshButton := view.AddButton("x20 y84 w128 h34", "最新の状態に更新")
    copyButton := view.AddButton("x164 y84 w230 h34", "表示中の診断情報をコピー")
    feedback := view.AddText("x20 y646 w600 h24 c526174", "")
    snapshot := 0
    refreshButton.OnEvent("Click", RefreshSnapshot)
    copyButton.OnEvent("Click", CopySnapshot)
    view.OnEvent("Close", (*) => view.Hide())
    view.OnEvent("Escape", (*) => view.Hide())
    RefreshSnapshot()
    return {Window:view, Refresh:RefreshSnapshot, Viewport:PanelViewport(view, 640, 686)}

    Row(y, label) {
        view.AddText("x36 y" y " w116 h24 BackgroundF5F7FA c526174", label)
        return view.AddText("x160 y" y " w440 h24 BackgroundF5F7FA", "")
    }
    RefreshSnapshot(*) {
        snapshot := ReadDiagnosticSnapshot()
        captured.Text := "取得日時：" snapshot.CapturedAt "　（自動更新はしません）"
        operation.Text := snapshot.Operation
        result.Text := snapshot.Result
        duration.Text := snapshot.Duration " ／ " snapshot.Stage
        source.Text := snapshot.Source "`n起動：" snapshot.StartedAt
        phase.Text := snapshot.Phase
        version.Text := snapshot.Version
        runtime.Text := snapshot.Ahk
        os.Text := "Windows " snapshot.OS
        browser.Text := snapshot.Browser
        worker.Text := snapshot.Worker
        settings.Text := "自動判別 " snapshot.Auto "　／　設定ファイル " snapshot.Settings
        feedback.Text := ""
    }
    CopySnapshot(*) {
        try {
            A_Clipboard := BuildDiagnosticReport(snapshot)
            feedback.Text := "コピーしました。不具合の相談先に貼り付けてください。"
        } catch {
            feedback.Text := "コピーできませんでした。もう一度お試しください。"
        }
    }
}
