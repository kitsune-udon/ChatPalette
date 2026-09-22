; Application storage lifecycle and public persistence operations.
OpenSettingsRepository(path) {
    global ActiveSettingsRepository
    if IsSet(ActiveSettingsRepository) && ActiveSettingsRepository {
        if ActiveSettingsRepository.Path == path && ActiveSettingsRepository.Db.Handle
            return ActiveSettingsRepository
        CloseSettingsStore()
    }
    if !FileExist(path)
        CreateSettingsDatabase(path)
    else if FileGetSize(path) = 0
        throw Error("設定データベースが空です。初期化せず、バックアップを確認してください。")
    ActiveSettingsRepository := SettingsRepository(path)
    return ActiveSettingsRepository
}
LoadSettings(path) {
    return OpenSettingsRepository(path).Load()
}
SaveSettings(state,path) {
    OpenSettingsRepository(path).SaveAll(state)
}
SaveLibrarySettings(library,inputProfileId,path) {
    OpenSettingsRepository(path).SaveLibrary(library,inputProfileId)
}
SaveSettingsPreferences(state,path) {
    OpenSettingsRepository(path).SavePreferences(state)
}
CloseSettingsStore(*) {
    global ActiveSettingsRepository
    if IsSet(ActiveSettingsRepository) && ActiveSettingsRepository {
        ActiveSettingsRepository.Close()
        ActiveSettingsRepository := 0
    }
}
CreateSettingsDatabase(path) {
    SplitPath(path,,&directory)
    if !DirExist(directory)
        throw Error("設定の保存先フォルダーがありません。")
    legacy := directory "\settings.ini"
    state := ReadLegacySettings(legacy)
    if !ValidLegacyReactionKey(state.ReactionShortcut)
        state.ReactionShortcut := ReactionDefaults.Shortcut
    temporary := path ".creating-" NewRecordId(), store := 0
    try {
        store := SettingsRepository(temporary,true)
        store.SaveAll(state)
        store.CheckIntegrity()
        VerifySettingsMigration(state,store.Load())
        store.Close(), store := 0
        ; Never replace an existing database. An interrupted attempt leaves the INI intact.
        FileMove(temporary,path,false)
    } finally {
        if store
            store.Close()
        if FileExist(temporary)
            FileDelete(temporary)
        if FileExist(temporary "-journal")
            FileDelete(temporary "-journal")
    }
}
VerifySettingsMigration(expected,actual) {
    if expected.Profiles.Length != actual.Profiles.Length || expected.InputProfileId != actual.InputProfileId
        throw Error("配信者の移行結果が一致しません。")
    for key in ["AutoMode","DefaultReactionKind","DefaultReactionCount","DefaultReactionIntervalMs","ReactionShortcut"] {
        if !(expected.%key% == actual.%key%)
            throw Error("共通設定の移行結果が一致しません。")
    }
    expectedKeys := PreferenceShortcutMap(expected), actualKeys := PreferenceShortcutMap(actual)
    for action,key in expectedKeys
        if !(actualKeys[action] == key)
            throw Error("ショートカットの移行結果が一致しません。")
    VerifyMigratedItems(expected.SharedDanmakuItems,actual.SharedDanmakuItems)
    for i, profile in expected.Profiles {
        other := actual.Profiles[i]
        if !(profile.Id == other.Id) || !(profile.Name == other.Name) || !(profile.Channel == other.Channel)
            throw Error("配信者の移行結果が一致しません。")
        VerifyMigratedItems(profile.Items,other.Items)
    }
}
VerifyMigratedItems(expected,actual) {
    if expected.Length != actual.Length
        throw Error("弾幕の移行件数が一致しません。")
    for i, item in expected {
        other := actual[i]
        if !(item.Id == other.Id) || !(item.Name == other.Name) || !(item.Text == other.Text) || ItemSlot(item) != ItemSlot(other)
            throw Error("弾幕の移行結果が一致しません。")
    }
}
BackupSettingsDatabase(destination) {
    if FileExist(destination)
        throw Error("バックアップ先は既に存在します。新しいファイル名を指定してください。")
    temporary := destination ".creating-" NewRecordId()
    try {
        OpenSettingsRepository(SettingsDatabasePath).Db.Backup(temporary)
        FileMove(temporary,destination,false)
    } finally {
        if FileExist(temporary)
            FileDelete(temporary)
        if FileExist(temporary "-journal")
            FileDelete(temporary "-journal")
    }
}
