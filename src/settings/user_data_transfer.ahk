; Transfer only validated values; never install an imported database schema.
ReadStoredUserData(path) {
    source := SettingsRepository(path,false,true)
    try return source.Db.Transaction(() => ReadUserDataSnapshot(source),false)
    finally source.Close()
}
ReadUserDataSnapshot(source, loaded := 0) {
    if source.Db.Scalar("PRAGMA application_id") != SettingsRepository.ApplicationId
        || (source.Db.Scalar("PRAGMA user_version") != 4 && source.Db.Scalar("PRAGMA user_version") != SettingsRepository.SchemaVersion)
        throw Error("未対応のユーザーデータです。対応するChatPaletteで開いてください。")
    source.Db.CheckIntegrity()
    state := loaded ? loaded.State : source.ReadState().State, db := source.Db
    CheckReactionRegistrationSize(db)
    registrations := [], browsers := Map()
    for row in db.Rows("SELECT browser,json_set(payload,'$.browser',browser),json_type(payload,'$.browser') FROM reaction_registrations ORDER BY browser") {
        if row[3] != "" || browsers.Has(row[1]) || !(ValidateReactionRegistration(db,row[2]) == row[1])
            throw Error("リアクション登録情報のブラウザー名が不正です。")
        browsers[row[1]] := true
        registrations.Push(row[2])
    }
    return {State:state,Registrations:registrations}
}
ReplaceStoredUserData(repository,data) {
    repository.EnsureLoaded()
    ValidateSettingsPreferences(data.State)
    plan := BuildLibraryStoragePlan(data.State,Map(),true)
    preferences := repository.CopyPreferences(data.State)
    version := repository.Db.Transaction(() => ApplyUserDataReplacement(repository,plan,preferences,data.Registrations))
    repository.Saved := {Scopes:plan.Scopes,Preferences:preferences,DataVersion:version}
}
ApplyUserDataReplacement(repository,plan,preferences,registrations) {
    version := repository.VerifyDataVersion(), db := repository.Db
    db.Exec("DELETE FROM preferences; DELETE FROM items; DELETE FROM scopes; DELETE FROM reaction_registrations")
    repository.ApplyLibrary(plan,Map())
    repository.ApplyPreferences(preferences,0)
    for payload in registrations
        ApplyReactionRegistration(repository,payload)
    return version
}
