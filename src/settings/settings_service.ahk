; Application settings lifecycle. Writes succeed before live data is published.
CopyItems(items) {
    result := []
    for item in items
        result.Push({Id:item.HasOwnProp("Id") ? item.Id : NewRecordId(), Name:item.Name, Text:item.Text, Slot:ItemSlot(item)})
    return result
}

CopyProfiles(profiles) {
    result := []
    for profile in profiles
        result.Push({Name:profile.Name, Channel:profile.Channel, Id:profile.Id, Items:CopyItems(profile.Items)})
    return result
}

CreatePreferences() {
    return {InputProfileId:InputProfileId, AutoMode:AutoMode, DefaultReactionKind:DefaultReactionKind,
        DefaultReactionCount:DefaultReactionCount, DefaultReactionIntervalMs:DefaultReactionIntervalMs, ShortcutKeys:ShortcutKeys.Clone()}
}
; A snapshot is always an independent editable copy.
CreateSettingsSnapshot() {
    state := CreatePreferences()
    state.Profiles := CopyProfiles(Profiles)
    state.SharedDanmakuItems := CopyItems(SharedDanmakuItems)
    return state
}
; The UI/session option names are translated at this one boundary.
PreferencesWithReactionOptions(draft) {
    preferences := CreatePreferences()
    preferences.DefaultReactionKind := draft.Reaction, preferences.DefaultReactionCount := draft.Count
    preferences.DefaultReactionIntervalMs := draft.Interval, preferences.ShortcutKeys["reaction"] := draft.Key
    ValidateSettingsPreferences(preferences)
    return preferences
}

ReloadAppSettings() {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        global AutoMode
        state := LoadSettings(SettingsDatabasePath)
        ApplyPreferences(state, false)
        PublishLibraryState(state)
        AutoMode := state.AutoMode
        if IsSet(LibraryHistory)
            LibraryHistory.Length := 0
    } finally {
        Critical(settingsCritical)
    }
}


ApplyPreferences(state, persist := true) {
    global DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ShortcutKeys
    ValidateSettingsPreferences(state)
    previous := CurrentShortcutMap(), next := state.ShortcutKeys.Clone()
    previousCritical := A_IsCritical
    Critical("On")
    disabled := [], installed := []
    try {
        ; Remove changed bindings first so swapping two keys is safe.
        for action,key in previous {
            if CanonicalShortcutKey(key) != CanonicalShortcutKey(next[action]) {
                SetShortcutHotkey(action,key,false)
                disabled.Push(action)
            }
        }
        for action in disabled {
            SetShortcutHotkey(action,next[action])
            installed.Push(action)
        }
        if persist
            SaveSettingsPreferences(state,SettingsDatabasePath)
        DefaultReactionKind := state.DefaultReactionKind, DefaultReactionCount := state.DefaultReactionCount
        DefaultReactionIntervalMs := state.DefaultReactionIntervalMs
        ShortcutKeys := next
    } catch as failure {
        for action in installed
            SetShortcutHotkey(action,next[action],false)
        for action in disabled
            SetShortcutHotkey(action,previous[action])
        throw failure
    } finally Critical(previousCritical)
}


SaveReactionDefaults(draft) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        preferences := PreferencesWithReactionOptions(draft)
        if draft.Reaction = DefaultReactionKind && draft.Count = DefaultReactionCount
            && draft.Interval = DefaultReactionIntervalMs && draft.Key == ShortcutKeys["reaction"]
            return
        ApplyPreferences(preferences)
    } finally {
        Critical(settingsCritical)
    }
}

SaveAutoDetection(enabled) {
    global AutoMode
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if AutoMode = (enabled ? 1 : 0)
            return
        state := CreatePreferences(), state.AutoMode := enabled ? 1 : 0
        SaveSettingsPreferences(state,SettingsDatabasePath)
        AutoMode := state.AutoMode
    } finally {
        Critical(previousCritical)
    }
}
