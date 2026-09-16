; Application settings lifecycle. Writes succeed before live data is published.
CopyItems(items) {
    result := []
    for item in items
        result.Push({Name:item.Name, Text:item.Text})
    return result
}

CopyProfiles(profiles) {
    result := []
    for profile in profiles
        result.Push({Name:profile.Name, Channel:profile.Channel, Reaction:profile.Reaction, Items:CopyItems(profile.Items)})
    return result
}

CreateSettingsSnapshot() {
    return {Profiles:CopyProfiles(Profiles), SharedDanmakuItems:CopyItems(SharedDanmakuItems), SelectedProfileIndex:SelectedProfileIndex, AutoMode:AutoMode,
        ReactionDefault:ReactionDefault, ReactionCount:ReactionCount, ReactionInterval:ReactionInterval, ReactionShortcut:ReactionShortcut}
}

ReloadAppSettings() {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        global Profiles, SharedDanmakuItems, SelectedProfileIndex, AutoMode, ReactionDefault, ReactionCount, ReactionInterval, ReactionShortcut
        state := ReadSettingsFile(SettingsFilePath)
        if !ValidReactionKey(state.ReactionShortcut)
            state.ReactionShortcut := ReactionDefaults.Shortcut
        if IsSet(ReactionsInitialized) && ReactionsInitialized
            ApplyCommonTransaction(state, state.Migrate)
        else if state.Migrate
            WriteSettingsFile(state, SettingsFilePath)
        Profiles := state.Profiles, SharedDanmakuItems := state.SharedDanmakuItems
        SelectedProfileIndex := state.SelectedProfileIndex, AutoMode := state.AutoMode
        ReactionDefault := state.ReactionDefault, ReactionCount := state.ReactionCount
        ReactionInterval := state.ReactionInterval, ReactionShortcut := state.ReactionShortcut
        RebuildChannelIndex()
        ClearLibraryUndo()
        BeginReactionEditing()
    } finally {
        Critical(settingsCritical)
    }
}

SaveAppSettingsSnapshot() {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        WriteSettingsFile(CreateSettingsSnapshot(), SettingsFilePath)
    } finally {
        Critical(settingsCritical)
    }
}

SaveLibraryTargets(targets, replacements) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        state := CreateSettingsSnapshot()
        for i, targetItems in targets {
            found := false
            if targetItems = SharedDanmakuItems {
                state.SharedDanmakuItems := CopyItems(replacements[i])
                found := true
            } else {
                for j, profile in Profiles {
                    if targetItems = profile.Items {
                        state.Profiles[j].Items := CopyItems(replacements[i])
                        found := true
                        break
                    }
                }
            }
            if !found
                throw Error("編集対象が変わりました。画面を開き直してください。")
        }
        WriteSettingsFile(state, SettingsFilePath)
        for i, targetItems in targets {
            targetItems.Length := 0
            for item in replacements[i]
                targetItems.Push({Name:item.Name,Text:item.Text})
        }
    } finally {
        Critical(settingsCritical)
    }
}

SaveLibraryUndo(snapshot) {
    targets := [], values := []
    for change in snapshot.Changes {
        targets.Push(change.Target)
        values.Push(change.Before)
    }
    SaveLibraryTargets(targets, values)
}

CommitProfileReactionDraft(draft, profile) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        if draft.Profile != profile || draft.Reaction < 0 || draft.Reaction > 5
            throw Error("編集対象が変わりました。変更を戻してから編集し直してください。")
        index := 0
        for i, candidate in Profiles
            if candidate = profile
                index := i
        if !index
            throw Error("編集対象の投稿者が見つかりません。")
        state := CreateSettingsSnapshot()
        state.Profiles[index].Reaction := draft.Reaction
        WriteSettingsFile(state, SettingsFilePath)
        profile.Reaction := draft.Reaction
    } finally {
        Critical(settingsCritical)
    }
}

ValidReactionKey(key) {
    return !IsReservedReactionKey(key) && RegExMatch(key, "^[!^+]*(?:[A-Za-z0-9]|F(?:[1-9]|1[0-2]))$")
        && InStr(key, "^") && (InStr(key, "!") || InStr(key, "+"))
}

CanonicalReactionKey(key) {
    return (InStr(key,"^") ? "^" : "") (InStr(key,"!") ? "!" : "") (InStr(key,"+") ? "+" : "") StrLower(RegExReplace(key,"[!^+]",""))
}

ApplyCommonTransaction(state, persist := true) {
    global ReactionDefault, ReactionCount, ReactionInterval, ReactionShortcut
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
            WriteSettingsFile(state, SettingsFilePath)
        ReactionDefault := state.ReactionDefault, ReactionCount := state.ReactionCount
        ReactionInterval := state.ReactionInterval, ReactionShortcut := state.ReactionShortcut
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

CommitSharedReactionDraft(draft) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        state := CreateSettingsSnapshot()
        state.ReactionDefault := draft.Reaction, state.ReactionCount := draft.Count
        state.ReactionInterval := draft.Interval, state.ReactionShortcut := draft.Key
        if draft.Reaction < 1 || draft.Reaction > 5 || !HasSettingValue(ReactionCounts,draft.Count) || !HasSettingValue(ReactionIntervals,draft.Interval)
            throw Error("リアクション設定の値が正しくありません。")
        ApplyCommonTransaction(state)
    } finally {
        Critical(settingsCritical)
    }
}
