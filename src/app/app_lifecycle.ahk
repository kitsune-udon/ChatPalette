; Startup recovery is explicit: a failed load never silently discards settings.
InitializeAppSettings(showRecoveryDialogs) {
    try DirCreate(AppDataDirectory)
    catch as failure {
        if !showRecoveryDialogs
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
            if !showRecoveryDialogs {
                FileAppend("設定の読み込み失敗: " failure.Message "`n", "**")
                return false
            }
            choice := MsgBox("設定を読み込めませんでした。`n`n" failure.Message
                . "`n`n対象：" SettingsDatabasePath
                . "`n`n［再試行］ファイルを修正して読み直す"
                . "`n［無視］元の設定を退避し、初期設定で起動する"
                . "`n［中止］変更せず終了する", "設定の復旧", "AbortRetryIgnore Icon! Default1")
            if choice = "Abort"
                return false
            if choice = "Ignore" {
                if MsgBox("配信者・弾幕を0件の初期設定に戻します。元の設定は削除せず、同じフォルダーへ退避します。続けますか？", "初期化の確認", "YesNo Default2 Icon!") != "Yes"
                    continue
                try BackupSettingsForReset(SettingsDatabasePath)
                catch as backupError {
                    MsgBox("退避できなかったため初期化しません。`n" backupError.Message, "設定の復旧", "Icon!")
                    return false
                }
            }
        }
    }
}

BackupSettingsForReset(path) {
    CloseSettingsStore()
    suffix := ".backup-" FormatTime(, "yyyyMMdd-HHmmss") "-" A_TickCount
    moved := []
    try {
        ; Preserve sidecar names; only completed moves need a rollback record.
        for tail in ["", "-journal", "-wal", "-shm"] {
            pair := [path tail,path suffix tail]
            if FileExist(pair[1]) {
                FileMove(pair[1],pair[2],false)
                moved.Push(pair)
            }
        }
    } catch as failure {
        unrestored := ""
        while moved.Length {
            pair := moved.Pop()
            try FileMove(pair[2],pair[1],false)
            catch
                unrestored .= "`n" pair[2] " → " pair[1]
        }
        if unrestored != ""
            throw Error(failure.Message "`n`n元に戻せなかったファイルがあります。退避先 → 元の場所：" unrestored)
        throw failure
    }
    return path suffix
}

ExportSettingsBackup(*) {
    destination := FileSelect("S2",,"弾幕・設定・ボタン登録のバックアップ先（新しいファイル名）","SQLite database (*.db)")
    if destination = ""
        return
    try {
        BackupSettingsDatabase(destination)
        MsgBox("弾幕・配信者・共通設定・リアクションボタンの登録情報を保存しました。","バックアップ完了")
    } catch as failure {
        MsgBox("バックアップできませんでした。`n" failure.Message,"バックアップ失敗","Icon!")
    }
}
