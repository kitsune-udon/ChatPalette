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

; Update commands keep this snapshot and its commit in the same Critical section.
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
    global AutoMode, DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ShortcutKeys
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
        AutoMode := state.AutoMode, DefaultReactionKind := state.DefaultReactionKind
        DefaultReactionCount := state.DefaultReactionCount, DefaultReactionIntervalMs := state.DefaultReactionIntervalMs
        ShortcutKeys := next
    } catch as failure {
        recoveryFailures := ""
        for action in installed {
            try SetShortcutHotkey(action,next[action],false)
            catch as recoveryFailure
                recoveryFailures .= "`n新しい割当の解除（" ShortcutKeyLabel(next[action]) "）: " recoveryFailure.Message
        }
        for action in disabled {
            try SetShortcutHotkey(action,previous[action])
            catch as recoveryFailure
                recoveryFailures .= "`n以前の割当の復元（" ShortcutKeyLabel(previous[action]) "）: " recoveryFailure.Message
        }
        if recoveryFailures != ""
            throw Error(failure.Message "`n一部のキー割当を元に戻せませんでした。ChatPaletteを再起動してください。" recoveryFailures)
        throw failure
    } finally Critical(previousCritical)
}


SaveReactionDefaults(draft) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        if draft.Reaction = DefaultReactionKind && draft.Count = DefaultReactionCount
            && draft.Interval = DefaultReactionIntervalMs && draft.Key == ShortcutKeys["reaction"]
            return
        preferences := CreatePreferences()
        preferences.DefaultReactionKind := draft.Reaction, preferences.DefaultReactionCount := draft.Count
        preferences.DefaultReactionIntervalMs := draft.Interval, preferences.ShortcutKeys["reaction"] := draft.Key
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
