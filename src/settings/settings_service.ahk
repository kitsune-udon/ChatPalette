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

CreateSettingsSnapshot(copyLibrary := true) {
    return {Profiles:copyLibrary ? CopyProfiles(Profiles) : Profiles, SharedDanmakuItems:copyLibrary ? CopyItems(SharedDanmakuItems) : SharedDanmakuItems, InputProfileIndex:InputProfileIndex, AutoMode:AutoMode,
        DefaultReactionKind:DefaultReactionKind, DefaultReactionCount:DefaultReactionCount, DefaultReactionIntervalMs:DefaultReactionIntervalMs, ReactionShortcut:ReactionShortcut}
}

ReloadAppSettings() {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        global Profiles, SharedDanmakuItems, InputProfileIndex, AutoMode, DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ReactionShortcut
        state := LoadSettings(SettingsDatabasePath)
        if IsSet(ReactionsInitialized) && ReactionsInitialized
            ApplyReactionDefaults(state, false)
        Profiles := state.Profiles, SharedDanmakuItems := state.SharedDanmakuItems
        InputProfileIndex := state.InputProfileIndex, AutoMode := state.AutoMode
        DefaultReactionKind := state.DefaultReactionKind, DefaultReactionCount := state.DefaultReactionCount
        DefaultReactionIntervalMs := state.DefaultReactionIntervalMs, ReactionShortcut := state.ReactionShortcut
        RebuildChannelIndex()
        if IsSet(LibraryHistory)
            LibraryHistory.Length := 0
    } finally {
        Critical(settingsCritical)
    }
}


ApplyReactionDefaults(state, persist := true) {
    global DefaultReactionKind, DefaultReactionCount, DefaultReactionIntervalMs, ReactionShortcut
    if !ValidReactionKey(state.ReactionShortcut)
        throw Error("Ctrl＋Alt、またはCtrl＋Shiftを含む、弾幕・パネル用以外のキーを指定してください。")
    oldKey := ReactionShortcut
    changed := CanonicalReactionKey(oldKey) != CanonicalReactionKey(state.ReactionShortcut)
    ; Key changes cannot run callbacks until persistence succeeds or rollback completes.
    previousCritical := A_IsCritical
    Critical("On")
    installed := false
    try {
        if changed {
            SetReactionHotkey(state.ReactionShortcut)
            installed := true
            SetReactionHotkey(oldKey, false)
        }
        if persist
            SaveSettingsPreferences(state, SettingsDatabasePath)
        DefaultReactionKind := state.DefaultReactionKind, DefaultReactionCount := state.DefaultReactionCount
        DefaultReactionIntervalMs := state.DefaultReactionIntervalMs, ReactionShortcut := state.ReactionShortcut
    } catch as failure {
        if installed {
            SetReactionHotkey(oldKey)
            SetReactionHotkey(state.ReactionShortcut, false)
        }
        throw failure
    } finally {
        Critical(previousCritical)
    }
}

SaveReactionDefaults(draft) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        if !IsInteger(draft.Reaction) || draft.Reaction < 1 || draft.Reaction > ReactionNames.Length || !HasSettingValue(ReactionCounts,draft.Count) || !HasSettingValue(ReactionIntervals,draft.Interval)
            throw Error("リアクション設定の値が正しくありません。")
        if !ValidReactionKey(draft.Key)
            throw Error("Ctrl＋Alt、またはCtrl＋Shiftを含む、弾幕・パネル用以外のキーを指定してください。")
        if draft.Reaction = DefaultReactionKind && draft.Count = DefaultReactionCount
            && draft.Interval = DefaultReactionIntervalMs && draft.Key == ReactionShortcut
            return
        state := CreateSettingsSnapshot(false)
        state.DefaultReactionKind := draft.Reaction, state.DefaultReactionCount := draft.Count
        state.DefaultReactionIntervalMs := draft.Interval, state.ReactionShortcut := draft.Key
        ApplyReactionDefaults(state)
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
        state := CreateSettingsSnapshot(false), state.AutoMode := enabled ? 1 : 0
        SaveSettingsPreferences(state,SettingsDatabasePath)
        AutoMode := state.AutoMode
    } finally {
        Critical(previousCritical)
    }
}
