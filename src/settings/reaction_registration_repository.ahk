; Durable browser registrations. JSON is a validated document inside SQLite, never a second settings file.
CreateReactionRegistrationSchema(db,path) {
    db.Exec("CREATE TABLE reaction_registrations(browser TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)))")
    SplitPath(path,,&directory)
    legacy := directory "\reaction_selectors.json"
    if FileExist(legacy) {
        if FileGetSize(legacy)>65536
            throw Error("旧リアクション登録情報が上限を超えています。")
        document := FileRead(legacy,"UTF-8")
        if db.Scalar("SELECT json_valid(?)",document) != "1"
            throw Error("旧リアクション登録情報が壊れています。元ファイルを確認してください。")
        if db.Scalar("SELECT json_extract(?,'$.version')",document) != "1" || db.Scalar("SELECT json_type(?,'$.profiles')",document) != "array"
            throw Error("旧リアクション登録情報の形式に対応していません。")
        for row in db.Rows("SELECT value FROM json_each(?,'$.profiles')",document)
            WriteReactionRegistration(db,row[1])
    }
    db.Exec("PRAGMA user_version=2")
}
ValidateReactionRegistration(db,payload) {
    if StrPut(payload,"UTF-8")>8192 || db.Scalar("SELECT json_valid(?)",payload) != "1"
        throw Error("リアクション登録情報の形式が不正です。")
    browser := StrLower(db.Scalar("SELECT json_extract(?,'$.browser')",payload))
    if !RegExMatch(browser,"^[a-z][a-z0-9_-]{0,63}$") || db.Scalar("SELECT json_type(?,'$.tokens')",payload) != "array"
        throw Error("リアクション登録情報のブラウザーまたはボタンが不正です。")
    rows := db.Rows("SELECT json_type(value,'$.name'),json_type(value,'$.id'),json_type(value,'$.class'),json_type(value,'$.type'),json_extract(value,'$.type'),json_array(json_extract(value,'$.name'),json_extract(value,'$.id'),json_extract(value,'$.class'),json_extract(value,'$.type')) FROM json_each(?,'$.tokens')",payload)
    if rows.Length != 5
        throw Error("リアクションは5種類の登録が必要です。")
    signatures := Map(), signatures.CaseSense := "On"
    for row in rows {
        if row[1] != "text" || row[2] != "text" || row[3] != "text" || row[4] != "integer" || Integer(row[5])<50000 || Integer(row[5])>50040 || signatures.Has(row[6])
            throw Error("リアクションの識別情報が不正または重複しています。")
        signatures[row[6]] := true
    }
    return browser
}
WriteReactionRegistration(db,payload) {
    browser := ValidateReactionRegistration(db,payload)
    db.Run("INSERT INTO reaction_registrations VALUES(?,json_set(?,'$.browser',?)) ON CONFLICT(browser) DO UPDATE SET payload=excluded.payload",browser,payload,browser)
    ; Keep the complete startup snapshot within the existing pipe frame limit.
    if Integer(db.Scalar("SELECT COALESCE(SUM(length(CAST(payload AS BLOB))),0) FROM reaction_registrations"))>24000
        throw Error("リアクション登録情報の合計サイズが上限を超えています。")
}
SaveReactionRegistration(payload) {
    repository := OpenSettingsRepository(SettingsDatabasePath)
    repository.Db.Transaction(() => ApplyReactionRegistration(repository,payload))
}
ApplyReactionRegistration(repository,payload) {
    if repository.HasOwnProp("DataVersion") && repository.DataVersion != repository.Db.Scalar("PRAGMA data_version")
        throw Error("設定が別の接続で変更されました。再起動して最新の設定を読み込んでください。")
    WriteReactionRegistration(repository.Db,payload)
}
LoadReactionRegistrationSnapshot() {
    db := OpenSettingsRepository(SettingsDatabasePath).Db
    return db.Scalar("SELECT json_object('version',1,'profiles',json_group_array(json(payload))) FROM reaction_registrations")
}
