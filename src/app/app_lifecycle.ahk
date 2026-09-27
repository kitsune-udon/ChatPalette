; Startup recovery is explicit: a failed load never silently discards settings.
InitializeAppSettings(showRecoveryDialogs) {
    try DirCreate(AppDataDirectory)
    catch as failure {
        if !showRecoveryDialogs
            FileAppend("データフォルダーの準備失敗: " failure.Message "`n", "**", "UTF-8-RAW")
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
                FileAppend("設定の読み込み失敗: " failure.Message "`n", "**", "UTF-8-RAW")
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
            catch as restoreFailure
                unrestored .= "`n" pair[2] " → " pair[1] "`n理由: " restoreFailure.Message
        }
        if unrestored != ""
            failure.Message .= "`n`n元に戻せなかったファイルがあります。退避先 → 元の場所：" unrestored
        throw failure
    }
    return path suffix
}

ExportSettingsBackup(*) {
    if !BeginSettingsTransfer()
        return
    try {
        destination := FileSelect("S2", "ChatPalette-" FormatTime(,"yyyyMMdd-HHmmss") ".json","ユーザーデータのエクスポート先（新しいファイル名）","JSON (*.json)")
        if destination = ""
            return
        SplitPath(destination,,,&extension)
        if extension = ""
            destination .= ".json"
        ExportUserData(destination)
        MsgBox("弾幕・配信者・共通設定・ショートカット・リアクションボタンの登録情報を保存しました。`n`n" destination,"エクスポート完了")
    } catch as failure {
        MsgBox("エクスポートできませんでした。`n" failure.Message,"エクスポート失敗","Icon!")
    } finally EndSettingsTransfer()
}

ImportSettingsBackup(*) {
    if !BeginSettingsTransfer()
        return
    try {
        source := FileSelect(1,,"インポートするChatPaletteのユーザーデータ","JSON (*.json)")
        if source = ""
            return
        data := ReadUserData(source), count := data.State.SharedDanmakuItems.Length
        for profile in data.State.Profiles
            count += profile.Items.Length
        if MsgBox("次のファイルで現在のユーザーデータをすべて置き換えます。追加・統合はしません。`n`n" source
            . "`n`n配信者：" data.State.Profiles.Length "件 ／ 弾幕：" count "件"
            . "`nショートカット・標準設定・リアクションボタン登録も置き換わります。"
            . "`n現在のデータは自動バックアップします。取り消し履歴は消去されます。`n`nインポートしますか？",
            "ユーザーデータのインポート","YesNo Default2 Icon!") != "Yes"
            return
        backup := SettingsDatabasePath ".before-import-" FormatTime(,"yyyyMMdd-HHmmss") "-" NewRecordId() ".json"
        ImportUserData(data,backup)
        ; A display failure cannot turn a committed import into a reported save failure.
        message := "インポートしました。`n以前のデータのバックアップ：`n" backup
        try RefreshImportedUserData()
        catch as failure
            message .= "`n`nデータは保存済みですが画面を更新できませんでした。再起動してください。`n" failure.Message
        MsgBox(message,"インポート完了")
    } catch as failure {
        MsgBox("インポートできませんでした。`n" failure.Message,"インポート失敗","Icon!")
    } finally EndSettingsTransfer()
}

BeginSettingsTransfer() {
    global SettingsTransferActive
    previousCritical := A_IsCritical
    Critical("On")
    try {
        policy := OperationPolicy("edit")
        if !policy.Allowed {
            ShowStatusTip(policy.Message,3000)
            return false
        }
        SettingsTransferActive := true
        return true
    } finally Critical(previousCritical)
}
EndSettingsTransfer() {
    global SettingsTransferActive := false
    RefreshOperationControls()
}
RefreshImportedUserData() {
    global EditingProfileId := "", DetectedChannel := {State:"unavailable",Channel:"",Author:"",Video:""}
    CancelScheduledPaletteSearch()
    PaletteSearch.Value := ""
    SetDetectionStatus("ユーザーデータを読み込みました。YouTubeから開くとチャンネルを確認します。")
    ResetPaletteSession()
    RefreshReactionDefaultControls()
    RefreshLibraryViews()
    RefreshReactionRegistration()
}
