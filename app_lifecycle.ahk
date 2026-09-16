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

BuildDiagnosticReport() {
    browser := "未選択"
    if TargetBrowserHwnd {
        try browser := WinGetProcessName("ahk_id " TargetBrowserHwnd)
    }
    return "YouTube チャットヘルパー " AppVersion
        . "`r`nAutoHotkey: " A_AhkVersion " / Windows: " A_OSVersion
        . "`r`nブラウザー: " browser
        . "`r`n補助プロセス: " (WorkerProcessId && ProcessExist(WorkerProcessId) ? "起動中" : "停止中")
        . "`r`n自動判別: " (AutoMode ? "ON" : "OFF")
        . "`r`n直近の要求: " LastBrowserOperation.Mode " / " LastBrowserOperation.State
        . "`r`n処理時間: " LastBrowserOperation.Duration " ms"
        . "`r`nリアクション状態: " ReactionExecutionStatus.Phase
        . "`r`n設定ファイル: " (FileExist(SettingsFilePath) ? "あり" : "なし")
        . "`r`n※弾幕本文・動画URL・投稿者名・ファイルパスは含みません。"
}

ShowDiagnostics(*) {
    view := Gui("+Owner" MainWindow.Hwnd, "診断情報")
    view.SetFont("s10", "Yu Gothic UI")
    report := BuildDiagnosticReport()
    view.AddEdit("w600 r12 ReadOnly", report)
    view.AddButton("w160", "診断情報をコピー").OnEvent("Click", (*) => A_Clipboard := report)
    view.OnEvent("Escape", (*) => view.Destroy())
    view.Show()
}
