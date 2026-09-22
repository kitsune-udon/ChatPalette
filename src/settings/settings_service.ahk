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
        DefaultReactionCount:DefaultReactionCount, DefaultReactionIntervalMs:DefaultReactionIntervalMs, ReactionShortcut:ReactionShortcut, ShortcutKeys:ShortcutKeys.Clone()}
}
CreateSettingsSnapshot(copyLibrary := true) {
    state := CreatePreferences()
    state.Profiles := copyLibrary ? CopyProfiles(Profiles) : Profiles
    state.SharedDanmakuItems := copyLibrary ? CopyItems(SharedDanmakuItems) : SharedDanmakuItems
    return state
}
; The UI/session option names are translated at this one boundary.
PreferencesWithReactionOptions(draft) {
    preferences := CreatePreferences()
    preferences.DefaultReactionKind := draft.Reaction, preferences.DefaultReactionCount := draft.Count
    preferences.DefaultReactionIntervalMs := draft.Interval, preferences.ReactionShortcut := draft.Key
    ValidateSettingsPreferences(preferences)
    return preferences
}

ReloadAppSettings() {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        global AutoMode, DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ReactionShortcut, ShortcutKeys
        state := LoadSettings(SettingsDatabasePath)
        if IsSet(ReactionsInitialized) && ReactionsInitialized
            ApplyReactionDefaults(state, false)
        PublishLibraryState(state)
        AutoMode := state.AutoMode
        DefaultReactionKind := state.DefaultReactionKind, DefaultReactionCount := state.DefaultReactionCount
        DefaultReactionIntervalMs := state.DefaultReactionIntervalMs, ReactionShortcut := state.ReactionShortcut
        ShortcutKeys := state.ShortcutKeys.Clone()
        if IsSet(LibraryHistory)
            LibraryHistory.Length := 0
    } finally {
        Critical(settingsCritical)
    }
}


ApplyReactionDefaults(state, persist := true) {
    global DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ReactionShortcut, ShortcutKeys
    ValidateSettingsPreferences(state)
    previous := CurrentShortcutMap(), next := PreferenceShortcutMap(state)
    previousCritical := A_IsCritical
    Critical("On")
    disabled := [], installed := []
    try {
        ; Remove changed bindings first so swapping two keys is safe.
        for action,key in previous {
            if CanonicalReactionKey(key) != CanonicalReactionKey(next[action]) {
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
        DefaultReactionIntervalMs := state.DefaultReactionIntervalMs, ReactionShortcut := state.ReactionShortcut
        ShortcutKeys := next.Clone(), ShortcutKeys.Delete("reaction")
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
            && draft.Interval = DefaultReactionIntervalMs && draft.Key == ReactionShortcut
            return
        ApplyReactionDefaults(preferences)
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
