; Profile commands: validate, persist candidate, then publish. No GUI dependencies.
ExecuteProfileCommand(action, index, value := "", previous := 0) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        global Profiles, SelectedProfileIndex
        if !CanChangeProfile()
            throw Error("投稿者設定を保存するか、変更を戻してください。")
        if action != "add" && action != "undo" && (index < 1 || index > Profiles.Length)
            throw Error("投稿者が見つかりません。")
        state := CreateSettingsSnapshot()
        undo := {Profiles:CopyProfiles(Profiles), SelectedProfileIndex:SelectedProfileIndex}
        switch action {
            case "add":
                if !Trim(value)
                    throw Error("投稿者名を入力してください。")
                state.Profiles.Push({Name:Trim(value),Channel:"",Reaction:0,Items:[]})
                state.SelectedProfileIndex := state.Profiles.Length
            case "rename":
                if !Trim(value)
                    throw Error("投稿者名を入力してください。")
                state.Profiles[index].Name := Trim(value)
            case "bind":
                for i, profile in state.Profiles
                    if value != "" && i != index && profile.Channel == value
                        throw Error("このチャンネルは別の投稿者に関連付け済みです。")
                state.Profiles[index].Channel := value
            case "delete":
                state.Profiles.RemoveAt(index)
                state.SelectedProfileIndex := Min(index,state.Profiles.Length)
            case "undo":
                if !previous
                    throw Error("取り消せる変更がありません。")
                state.Profiles := CopyProfiles(previous.Profiles)
                state.SelectedProfileIndex := previous.SelectedProfileIndex
            default:
                throw Error("不明な投稿者操作です。")
        }
        WriteSettingsFile(state, SettingsFilePath)
        Profiles := state.Profiles, SelectedProfileIndex := state.SelectedProfileIndex
        ClearLibraryUndo()
        RebuildChannelIndex()
        BeginProfileReactionDraft()
        return action = "undo" ? 0 : undo
    } finally {
        Critical(settingsCritical)
    }
}

SaveSelectedProfile(index) {
    settingsCritical := A_IsCritical
    Critical("On")
    try {
        global SelectedProfileIndex
        if !CanChangeProfile()
            throw Error("投稿者設定を保存するか、変更を戻してください。")
        if index < 1 || index > Profiles.Length
            throw Error("投稿者が見つかりません。")
        state := CreateSettingsSnapshot()
        state.SelectedProfileIndex := index
        WriteSettingsFile(state, SettingsFilePath)
        SelectedProfileIndex := index
        BeginProfileReactionDraft()
    } finally {
        Critical(settingsCritical)
    }
}

; Shared drafts survive profile changes; only profile-owned edits block them.
CanChangeProfile() {
    return !HasUnsavedProfileReaction
}
GetSelectedProfile() {
    return SelectedProfileIndex >= 1 && SelectedProfileIndex <= Profiles.Length ? Profiles[SelectedProfileIndex] : 0
}
