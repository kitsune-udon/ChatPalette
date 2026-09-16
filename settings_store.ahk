; Persistence only: no views, undo policy, or derived indexes.
ReadSettingsFile(path) {
    state := {Profiles: [], SharedDanmakuItems: []}
    commonCount := ReadSettingInteger(path, "CommonDanmaku", "Count", "-1")
    if commonCount < -1
        throw Error("共通弾幕の件数が正しくありません。")
    if commonCount > 0 {
        Loop commonCount
            state.SharedDanmakuItems.Push({Name: IniRead(path, "CommonDanmaku", "Label" A_Index, "弾幕" A_Index), Text: IniRead(path, "CommonDanmaku", "Text" A_Index, "")})
    }
    state.AutoMode := ReadSettingInteger(path, "General", "AutoMode", "1")
    count := ReadSettingInteger(path, "General", "Count", "0")
    if count < 0 || !HasSettingValue([0,1],state.AutoMode)
        throw Error("投稿者数または自動判別設定が正しくありません。")
    Loop count {
        section := "Profile" A_Index
        p := {Name: IniRead(path, section, "Name", "投稿者" A_Index), Channel: IniRead(path, section, "Channel", ""), Reaction: ReadSettingInteger(path, section, "Reaction", "0"), Items: []}
        itemCount := ReadSettingInteger(path, section, "Count", "0")
        if itemCount < 0
            throw Error("弾幕の件数が正しくありません。")
        Loop itemCount
            p.Items.Push({Name: IniRead(path, section, "Label" A_Index, "弾幕" A_Index),
                Text: IniRead(path, section, "Text" A_Index, "")})
        state.Profiles.Push(p)
    }
    state.SelectedProfileIndex := Min(Max(ReadSettingInteger(path, "General", "Current", "1"), 1), state.Profiles.Length)
    state.Migrate := !FileExist(path) || commonCount < 0
    return ReadReactionSettings(state, path)
}

ReadReactionSettings(state, path) {
    state.ReactionDefault := Min(5, Max(1, ReadSettingInteger(path, "General", "ReactionDefault", ReactionDefaults.Choice)))
    state.ReactionCount := ReadSettingInteger(path, "General", "ReactionCount", ReactionDefaults.Count)
    if !HasSettingValue(ReactionCounts, state.ReactionCount)
        state.ReactionCount := ReactionDefaults.Count
    state.ReactionInterval := ReadSettingInteger(path, "General", "ReactionInterval", ReactionDefaults.Interval)
    if !HasSettingValue(ReactionIntervals, state.ReactionInterval)
        state.ReactionInterval := ReactionDefaults.Interval
    state.ReactionShortcut := IniRead(path, "General", "ReactionShortcut", ReactionDefaults.Shortcut)
    for profile in state.Profiles
        if profile.Reaction < 0 || profile.Reaction > 5
            profile.Reaction := 0
    return state
}

HasSettingValue(values, value) {
    for entry in values
        if entry = value
            return true
    return false
}

WriteSettingsFile(state, path) {
    ; Rewrite to a new file so removed records do not remain in the settings.
    destination := path ".new"
    try {
        if FileExist(destination)
            FileDelete(destination)
        IniWrite(state.Profiles.Length, destination, "General", "Count")
        IniWrite(state.SelectedProfileIndex, destination, "General", "Current")
        IniWrite(state.AutoMode, destination, "General", "AutoMode")
        IniWrite(state.ReactionDefault, destination, "General", "ReactionDefault")
        IniWrite(state.ReactionCount, destination, "General", "ReactionCount")
        IniWrite(state.ReactionInterval, destination, "General", "ReactionInterval")
        IniWrite(state.ReactionShortcut, destination, "General", "ReactionShortcut")
        for i, p in state.Profiles {
            section := "Profile" i
            WriteSettingText(p.Name, destination, section, "Name")
            WriteSettingText(p.Channel, destination, section, "Channel")
            IniWrite(p.Reaction, destination, section, "Reaction")
            IniWrite(p.Items.Length, destination, section, "Count")
            for j, item in p.Items {
                WriteSettingText(item.Name, destination, section, "Label" j)
                WriteSettingText(item.Text, destination, section, "Text" j)
            }
        }
        IniWrite(state.SharedDanmakuItems.Length, destination, "CommonDanmaku", "Count")
        for j, item in state.SharedDanmakuItems {
            WriteSettingText(item.Name, destination, "CommonDanmaku", "Label" j)
            WriteSettingText(item.Text, destination, "CommonDanmaku", "Text" j)
        }
        FileMove(destination, path, true)
    } finally {
        if FileExist(destination) {
            try FileDelete(destination)
        }
    }
}

WriteSettingText(value, path, section, key) {
    if InStr(value, "`r") || InStr(value, "`n")
        throw Error("設定の文字列には改行を含められません：[" section "] " key)
    ; The INI API strips one enclosing quote pair and unquoted edge spaces.
    ; Always wrap literal strings so their original quotes/spaces survive reload.
    IniWrite(Chr(34) value Chr(34), path, section, key)
}

ReadSettingInteger(path, section, key, fallback) {
    value := IniRead(path, section, key, fallback)
    try return Integer(value)
    catch
        throw Error("設定値が整数ではありません：[" section "] " key)
}
