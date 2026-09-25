ReadDiagnosticSnapshot() {
    operation := LastBrowserOperation
    browser := "未選択（YouTubeからパネルを開くと表示）"
    hwnd := operation.Window ? operation.Window : TargetBrowserHwnd
    if hwnd {
        try {
            process := StrLower(WinGetProcessName("ahk_id " hwnd))
            browser := BrowserNames().Get(process, "対象外のブラウザー")
        } catch {
            browser := "対象のウィンドウは閉じられています"
        }
    }
    static phases := Map("idle","待機中", "queued","キーを離すのを待っています", "waiting","開始・登録待ち",
        "running","実行中", "stopping","停止処理中", "finished","終了")
    mode := operation.Mode
    state := operation.State
    job := ActiveReactionJob
    phase := job ? job.Phase : ReactionExecutionStatus.Phase
    return {CapturedAt:FormatTime(, "yyyy/MM/dd HH:mm:ss"), Version:AppVersion, Ahk:A_AhkVersion, OS:A_OSVersion,
        Source:AppSourceStatus(), StartedAt:AppStartedAt, Keys:EffectiveShortcutSummary(),
        Stage:operation.Stage,
        Browser:browser, Worker:IsWorkerRunning() ? "起動中" : "待機中（必要なときに起動）",
        Auto:AutoMode ? "ON" : "OFF", Settings:FileExist(SettingsDatabasePath) ? "あり" : "なし",
        Operation:BrowserOperationLabel(mode), Result:BrowserResultInfo(state).Summary,
        Duration:mode = "なし" ? "—（未実行）" : operation.Duration " ms",
        Phase:phases.Get(phase, "不明"), ModeCode:mode, StateCode:state, PhaseCode:phase}
}

BuildDiagnosticReport(info) {
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
    try {
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
    } catch as failure {
        view.Destroy()
        throw failure
    }

    Row(y, label) {
        view.AddText("x36 y" y " w116 h24 BackgroundF5F7FA c526174", label)
        return view.AddText("x160 y" y " w440 h24 BackgroundF5F7FA", "")
    }
    RefreshSnapshot(*) {
        next := ReadDiagnosticSnapshot()
        refreshCritical := A_IsCritical
        Critical("On")
        try {
            snapshot := 0
            copyButton.Enabled := false
            captured.Text := "取得日時：" next.CapturedAt "　（自動更新はしません）"
            operation.Text := next.Operation
            result.Text := next.Result
            duration.Text := next.Duration " ／ " next.Stage
            source.Text := next.Source "`n起動：" next.StartedAt
            phase.Text := next.Phase
            version.Text := next.Version
            runtime.Text := next.Ahk
            os.Text := "Windows " next.OS
            browser.Text := next.Browser
            worker.Text := next.Worker
            settings.Text := "自動判別 " next.Auto "　／　設定ファイル " next.Settings
            feedback.Text := ""
            snapshot := next
            copyButton.Enabled := true
        } finally Critical(refreshCritical)
    }
    CopySnapshot(*) {
        if !snapshot
            return
        try {
            A_Clipboard := BuildDiagnosticReport(snapshot)
            feedback.Text := "コピーしました。不具合の相談先に貼り付けてください。"
        } catch {
            feedback.Text := "コピーできませんでした。もう一度お試しください。"
        }
    }
}
