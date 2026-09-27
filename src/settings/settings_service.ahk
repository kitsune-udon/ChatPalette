; Application settings lifecycle. Writes succeed before live data is published.
; Update commands keep this snapshot and its commit in the same Critical section.
CreatePreferences() {
    return {InputProfileId:InputProfileId, AutoMode:AutoMode, DefaultReactionKind:DefaultReactionKind,
        DefaultReactionCount:DefaultReactionCount, DefaultReactionIntervalMs:DefaultReactionIntervalMs, ShortcutKeys:ShortcutKeys.Clone()}
}
ReloadAppSettings() {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        state := LoadSettings(SettingsDatabasePath)
        ApplyPreferences(state, false)
        PublishLibraryState(state)
        if IsSet(LibraryHistory)
            LibraryHistory.Length := 0
    } finally {
        Critical(settingsCritical)
    }
}


ApplyPreferences(state, persist := true) {
    CommitPreferences(state,persist ? SaveSettingsPreferences.Bind(state,SettingsDatabasePath) : 0)
}
; Normal saves, reloads and imports share key rollback and publish only after commit.
CommitPreferences(state,commit := 0) {
    global AutoMode, DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ShortcutKeys
    ValidateSettingsPreferences(state)
    previousCritical := A_IsCritical
    Critical("On")
    try {
        next := state.ShortcutKeys.Clone()
        if ApplicationShortcutsInstalled
            CommitShortcutBindings(CurrentShortcutMap(),next,commit)
        else if commit
            commit.Call()
        AutoMode := state.AutoMode, DefaultReactionKind := state.DefaultReactionKind
        DefaultReactionCount := state.DefaultReactionCount, DefaultReactionIntervalMs := state.DefaultReactionIntervalMs
        ShortcutKeys := next
    } finally Critical(previousCritical)
}


ImportUserData(data,backupPath) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        repository := OpenSettingsRepository(SettingsDatabasePath)
        repository.VerifyDataVersion()
        ExportUserData(backupPath)
        CommitPreferences(data.State,ReplaceStoredUserData.Bind(repository,data))
        PublishLibraryState(data.State)
        LibraryHistory.Length := 0
        InvalidateWorkerRegistration()
    } finally Critical(previousCritical)
}

SaveReactionDefaults(draft) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        if draft.Reaction = DefaultReactionKind && draft.Count = DefaultReactionCount
            && draft.Interval = DefaultReactionIntervalMs
            return
        preferences := CreatePreferences()
        preferences.DefaultReactionKind := draft.Reaction, preferences.DefaultReactionCount := draft.Count
        preferences.DefaultReactionIntervalMs := draft.Interval
        ApplyPreferences(preferences)
    } finally {
        Critical(settingsCritical)
    }
}

SaveAutoDetection(enabled) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if AutoMode = (enabled ? 1 : 0)
            return
        state := CreatePreferences(), state.AutoMode := enabled ? 1 : 0
        ApplyPreferences(state)
    } finally Critical(previousCritical)
}
