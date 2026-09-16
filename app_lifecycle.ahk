; Startup recovery is explicit: a failed load never silently discards settings.
InitializeAppSettings() {
    try InitializeDataDirectory(AppDataDirectory)
    catch as failure {
        if A_Args.Length && A_Args[1] = "--smoke"
            FileAppend("データフォルダーの準備失敗: " failure.Message "`n", "**")
        else
            MsgBox("データフォルダーを準備できません。書き込み権限を確認してください。`n" AppDataDirectory "`n" failure.Message, "起動エラー", "Icon!")
        return false
    }
    loop {
        try {
            ReloadAppSettings()
            return true
        } catch as failure {
            ; Automated checks must fail without leaving a modal dialog behind.
            if A_Args.Length && A_Args[1] = "--smoke" {
                FileAppend("設定の読み込み失敗: " failure.Message "`n", "**")
                return false
            }
            choice := MsgBox("設定を読み込めませんでした。`n`n" failure.Message
                . "`n`n対象：" SettingsFilePath
                . "`n`n［再試行］ファイルを修正して読み直す"
                . "`n［無視］元の設定を退避し、初期設定で起動する"
                . "`n［中止］変更せず終了する", "設定の復旧", "AbortRetryIgnore Icon! Default1")
            if choice = "Abort"
                return false
            if choice = "Ignore" {
                if MsgBox("投稿者・弾幕を0件の初期設定に戻します。元の設定は削除せず、同じフォルダーへ退避します。続けますか？", "初期化の確認", "YesNo Default2 Icon!") != "Yes"
                    continue
                try BackupSettingsForReset(SettingsFilePath)
                catch as backupError {
                    MsgBox("退避できなかったため初期化しません。`n" backupError.Message, "設定の復旧", "Icon!")
                    return false
                }
            }
        }
    }
}

InitializeDataDirectory(directory) {
    DirCreate(directory)
    ; Prefer existing data/ files. Never overwrite them with legacy root files.
    for name in ["settings.ini", "reaction_selectors.json", "video_metadata_cache.json"] {
        legacy := A_ScriptDir "\" name
        destination := directory "\" name
        if FileExist(legacy) && !FileExist(destination)
            FileMove(legacy, destination, false)
    }
}

BackupSettingsForReset(path) {
    if !FileExist(path)
        return ""
    backup := path ".backup-" FormatTime(, "yyyyMMdd-HHmmss") "-" A_TickCount
    FileMove(path, backup, false)
    return backup
}

ReadDiagnosticSnapshot() {
    browser := "未選択（YouTubeからパネルを開くと表示）"
    if TargetBrowserHwnd {
        try {
            process := StrLower(WinGetProcessName("ahk_id " TargetBrowserHwnd))
            browsers := Map("chrome.exe","Chrome", "msedge.exe","Edge", "firefox.exe","Firefox",
                "brave.exe","Brave", "opera.exe","Opera", "vivaldi.exe","Vivaldi")
            browser := browsers.Get(process, "対象外のブラウザー")
        } catch {
            browser := "対象のウィンドウは閉じられています"
        }
    }
    modes := Map("なし","まだ実行していません", "resolve","投稿者の自動判別", "verify","動画の確認",
        "verify_input","チャット欄・コメント欄の確認", "reaction_context","リアクション用の動画確認",
        "reaction_capture","リアクションボタンの登録", "reaction_check","リアクションの検出確認",
        "reaction_send","リアクションボタンの操作")
    states := Map("未実行","まだ実行していません", "ok","確認できました", "registered","登録できました",
        "ready","操作対象を確認できました", "operated","ボタンを操作しました（受理は未確認）",
        "wrong_input","入力欄を確認できませんでした", "changed","動画が変わったため中止しました",
        "wrong_window","操作先が変わったため中止しました", "unavailable","情報を取得できませんでした",
        "unknown","操作結果を確認できませんでした", "not_registered","操作ボタンが未登録です",
        "menu_closed","リアクションメニューが見つかりません", "unsupported","操作対象を識別できませんでした",
        "cooldown","操作間隔が短いため停止しました", "save_failed","登録情報を保存できませんでした")
    phases := Map("idle","待機中", "queued","キーを離すのを待っています", "running","実行中", "finished","終了")
    mode := modes.Has(LastBrowserOperation.Mode) ? LastBrowserOperation.Mode : "不明"
    state := states.Has(LastBrowserOperation.State) ? LastBrowserOperation.State : "不明"
    phase := phases.Has(ReactionExecutionStatus.Phase) ? ReactionExecutionStatus.Phase : "不明"
    return {CapturedAt:FormatTime(, "yyyy/MM/dd HH:mm:ss"), Version:AppVersion, Ahk:A_AhkVersion, OS:A_OSVersion,
        Browser:browser, Worker:WorkerProcessId && ProcessExist(WorkerProcessId) ? "起動中" : "待機中（必要なときに起動）",
        Auto:AutoMode ? "ON" : "OFF", Settings:FileExist(SettingsFilePath) ? "あり" : "なし",
        Operation:modes.Get(mode, "不明な操作"), Result:states.Get(state, "不明な結果"),
        Duration:mode = "なし" ? "—（未実行）" : LastBrowserOperation.Duration " ms",
        Phase:phases.Get(phase, "不明"), ModeCode:mode, StateCode:state, PhaseCode:phase}
}

BuildDiagnosticReport(snapshot := 0) {
    info := snapshot ? snapshot : ReadDiagnosticSnapshot()
    return "ChatPalette " info.Version
        . "`r`n取得日時: " info.CapturedAt
        . "`r`n`r`n[直近の操作]"
        . "`r`n操作: " info.Operation " (" info.ModeCode ")"
        . "`r`n結果: " info.Result " (" info.StateCode ")"
        . "`r`n処理時間: " info.Duration
        . "`r`nリアクション: " info.Phase " (" info.PhaseCode ")"
        . "`r`n`r`n[環境・動作状況]"
        . "`r`nAutoHotkey: " info.Ahk " / Windows: " info.OS
        . "`r`nブラウザー: " info.Browser
        . "`r`n補助プロセス: " info.Worker
        . "`r`n自動判別: " info.Auto " / 設定ファイル: " info.Settings
}

ShowDiagnostics(*) {
    static panel := 0
    if !panel
        panel := CreateDiagnosticPanel()
    else
        panel.Refresh.Call()
    panel.Window.Show()
}

CreateDiagnosticPanel() {
    view := Gui("+Owner" MainWindow.Hwnd, "診断情報")
    view.BackColor := "F5F7FA"
    view.SetFont("s10 c334155", "Yu Gothic UI")
    view.AddText("x20 y14 w600 h30 c183153", "診断情報").SetFont("s16 bold")
    view.AddText("x20 y52 w600 h24", "動作状況を確認し、不具合の相談に必要な情報をコピーできます。")
    captured := view.AddText("x20 y84 w600 h22 c526174", "")
    view.AddGroupBox("x20 y116 w600 h168", "直近の操作")
    operation := Row(144, "操作")
    result := Row(174, "結果")
    duration := Row(204, "処理時間")
    phase := Row(234, "リアクション")
    view.AddGroupBox("x20 y300 w600 h216", "環境・動作状況")
    version := Row(328, "アプリ")
    runtime := Row(360, "AutoHotkey")
    os := Row(392, "OS")
    browser := Row(424, "ブラウザー")
    worker := Row(456, "補助プロセス")
    settings := Row(488, "設定")
    view.AddText("x20 y532 w600 h52 c526174", "コピーには上記の情報と調査用の結果コードが含まれます。`n弾幕本文・動画URL・投稿者名・保存先のパスは含まれません。")
    refreshButton := view.AddButton("x20 y598 w128 h34", "最新の状態に更新")
    copyButton := view.AddButton("x164 y598 w230 h34", "表示中の診断情報をコピー")
    feedback := view.AddText("x20 y646 w600 h24 c526174", "")
    snapshot := 0
    refreshButton.OnEvent("Click", RefreshSnapshot)
    copyButton.OnEvent("Click", CopySnapshot)
    view.OnEvent("Close", (*) => view.Hide())
    view.OnEvent("Escape", (*) => view.Hide())
    RefreshSnapshot()
    return {Window:view, Refresh:RefreshSnapshot}

    Row(y, label) {
        view.AddText("x36 y" y " w116 h24 BackgroundF5F7FA c526174", label)
        return view.AddText("x160 y" y " w440 h24 BackgroundF5F7FA", "")
    }
    RefreshSnapshot(*) {
        snapshot := ReadDiagnosticSnapshot()
        captured.Text := "取得日時：" snapshot.CapturedAt "　（自動更新はしません）"
        operation.Text := snapshot.Operation
        result.Text := snapshot.Result
        duration.Text := snapshot.Duration
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
