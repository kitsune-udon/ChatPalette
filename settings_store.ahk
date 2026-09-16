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
    ; Serialize before touching disk; one write preserves the same UTF-16 INI format.
    text := "[General]`r`nCount=" state.Profiles.Length "`r`nCurrent=" state.SelectedProfileIndex
        . "`r`nAutoMode=" state.AutoMode "`r`nReactionDefault=" state.ReactionDefault
        . "`r`nReactionCount=" state.ReactionCount "`r`nReactionInterval=" state.ReactionInterval "`r`n"
        . SettingTextLine("ReactionShortcut", state.ReactionShortcut, "General")
    for i, p in state.Profiles {
        section := "Profile" i
        text .= "`r`n[" section "]`r`n" SettingTextLine("Name", p.Name, section)
            . SettingTextLine("Channel", p.Channel, section)
            . "Reaction=" p.Reaction "`r`nCount=" p.Items.Length "`r`n"
        for j, item in p.Items
            text .= SettingTextLine("Label" j, item.Name, section) SettingTextLine("Text" j, item.Text, section)
    }
    text .= "`r`n[CommonDanmaku]`r`nCount=" state.SharedDanmakuItems.Length "`r`n"
    for j, item in state.SharedDanmakuItems
        text .= SettingTextLine("Label" j, item.Name, "CommonDanmaku") SettingTextLine("Text" j, item.Text, "CommonDanmaku")
    destination := path ".new"
    try {
        if FileExist(destination)
            FileDelete(destination)
        FileAppend(text, destination, "UTF-16")
        FileMove(destination, path, true)
    } finally {
        if FileExist(destination) {
            try FileDelete(destination)
        }
    }
}

SettingTextLine(key, value, section) {
    if InStr(value, "`r") || InStr(value, "`n")
        throw Error("設定の文字列には改行を含められません：[" section "] " key)
    ; INI reading strips one enclosing quote pair. Preserve literal quotes/spaces.
    return key "=" Chr(34) value Chr(34) "`r`n"
}
ReadSettingInteger(path, section, key, fallback) {
    value := IniRead(path, section, key, fallback)
    if !IsInteger(value)
        throw Error("設定値が整数ではありません：[" section "] " key)
    try return Integer(value)
    catch
        throw Error("設定値が整数ではありません：[" section "] " key)
}
