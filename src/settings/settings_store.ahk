; Persistence only: no views, undo policy, or derived indexes.
ReadSettingsDocument(path) {
    sections := Map()
    sections.CaseSense := "Off"
    if !FileExist(path)
        return sections
    if FileGetSize(path) > 32*1024*1024
        throw Error("設定ファイルが上限32MiBを超えています。")
    ; BOM selects UTF-16/UTF-8; legacy files without a BOM use the system encoding.
    section := 0
    for line in StrSplit(FileRead(path, "CP0"), "`n", "`r") {
        line := Trim(line, " `t")
        if line = "" || SubStr(line, 1, 1) = ";"
            continue
        if RegExMatch(line, "^\[([^\]]+)\]", &match) {
            name := Trim(match[1], " `t")
            if !sections.Has(name) {
                values := Map()
                values.CaseSense := "Off"
                sections[name] := values
            }
            section := sections[name]
            continue
        }
        separator := InStr(line, "=")
        if !section || !separator
            continue
        key := Trim(SubStr(line, 1, separator - 1), " `t")
        value := Trim(SubStr(line, separator + 1), " `t")
        quote := SubStr(value, 1, 1)
        if StrLen(value) >= 2 && (quote = Chr(34) || quote = "'") && SubStr(value, -1) = quote
            value := SubStr(value, 2, StrLen(value) - 2)
        if key != "" && !section.Has(key)
            section[key] := value
    }
    return sections
}

ReadSettingValue(document, section, key, fallback) {
    return document.Has(section) ? document[section].Get(key, fallback) : fallback
}

ReadSettingsFile(path) {
    document := ReadSettingsDocument(path)
    state := {Profiles: [], SharedDanmakuItems: []}
    commonCount := ReadSettingInteger(document, "CommonDanmaku", "Count", "-1")
    if commonCount < -1
        throw Error("共通弾幕の件数が正しくありません。")
    ValidateItemSection(document,"CommonDanmaku",Max(0,commonCount))
    totalItems := Max(0,commonCount)
    if commonCount > 0 {
        Loop commonCount
            state.SharedDanmakuItems.Push({Name: ReadSettingValue(document, "CommonDanmaku", "Label" A_Index, "弾幕" A_Index), Text: ReadSettingValue(document, "CommonDanmaku", "Text" A_Index, ""), Slot: ReadSettingInteger(document, "CommonDanmaku", "Slot" A_Index, A_Index <= 2 ? A_Index : 0)})
    }
    state.AutoMode := ReadSettingInteger(document, "General", "AutoMode", "1")
    count := ReadSettingInteger(document, "General", "Count", "0")
    if count < 0 || !HasSettingValue([0,1],state.AutoMode)
        throw Error("配信者数または自動判別設定が正しくありません。")
    if count > 10000
        throw Error("配信者数が上限10000件を超えています：[General] Count")
    Loop count {
        section := "Profile" A_Index
        if !document.Has(section) || !document[section].Has("Name")
            throw Error("配信者の必須項目がありません：[" section "] Name")
        p := {Name: ReadSettingValue(document, section, "Name", "配信者" A_Index), Channel: ReadSettingValue(document, section, "Channel", ""), Id: ReadSettingValue(document, section, "Id", NewProfileId()), Items: []}
        itemCount := ReadSettingInteger(document, section, "Count", "0")
        if itemCount < 0
            throw Error("弾幕の件数が正しくありません。")
        ValidateItemSection(document,section,itemCount)
        totalItems += itemCount
        if totalItems > 100000
            throw Error("弾幕の総数が上限100000件を超えています。")
        Loop itemCount
            p.Items.Push({Name: ReadSettingValue(document, section, "Label" A_Index, "弾幕" A_Index),
                Text: ReadSettingValue(document, section, "Text" A_Index, ""), Slot: ReadSettingInteger(document, section, "Slot" A_Index, A_Index <= 2 ? A_Index : 0)})
        state.Profiles.Push(p)
    }
    state.InputProfileIndex := Min(Max(ReadSettingInteger(document, "General", "Current", "0"), 0), state.Profiles.Length)
    state.Migrate := !FileExist(path) || commonCount < 0 || ReadSettingValue(document, "General", "Schema", "") != "3"
    NormalizeLibrarySlots(state.SharedDanmakuItems)
    ids := Map()
    for profile in state.Profiles {
        if profile.Id = "" || ids.Has(profile.Id)
            profile.Id := NewProfileId()
        ids[profile.Id] := true
        NormalizeLibrarySlots(profile.Items)
    }
    return ReadReactionSettings(state, document)
}

ReadReactionSettings(state, document) {
    state.DefaultReactionKind := Min(5, Max(1, ReadSettingInteger(document, "General", "ReactionDefault", ReactionDefaults.Choice)))
    state.DefaultReactionCount := ReadSettingInteger(document, "General", "ReactionCount", ReactionDefaults.Count)
    if !HasSettingValue(ReactionCounts, state.DefaultReactionCount)
        state.DefaultReactionCount := ReactionDefaults.Count
    state.DefaultReactionIntervalMs := ReadSettingInteger(document, "General", "ReactionInterval", ReactionDefaults.Interval)
    if !HasSettingValue(ReactionIntervals, state.DefaultReactionIntervalMs)
        state.DefaultReactionIntervalMs := ReactionDefaults.Interval
    state.ReactionShortcut := ReadSettingValue(document, "General", "ReactionShortcut", ReactionDefaults.Shortcut)
    return state
}

HasSettingValue(values, value) {
    for entry in values
        if entry = value
            return true
    return false
}

WriteSettingsFile(state, path) {
    if state.Profiles.Length > 10000
        throw Error("配信者数は10000件までです。")
    totalItems := state.SharedDanmakuItems.Length
    for profile in state.Profiles
        totalItems += profile.Items.Length
    if totalItems > 100000
        throw Error("弾幕の総数は100000件までです。")
    ; Serialize before touching disk; one write preserves the same UTF-16 INI format.
    text := "[General]`r`nSchema=3`r`nCount=" state.Profiles.Length "`r`nCurrent=" state.InputProfileIndex
        . "`r`nAutoMode=" state.AutoMode "`r`nReactionDefault=" state.DefaultReactionKind
        . "`r`nReactionCount=" state.DefaultReactionCount "`r`nReactionInterval=" state.DefaultReactionIntervalMs "`r`n"
        . SettingTextLine("ReactionShortcut", state.ReactionShortcut, "General")
    for i, p in state.Profiles {
        section := "Profile" i
        text .= "`r`n[" section "]`r`n" SettingTextLine("Name", p.Name, section)
            . SettingTextLine("Channel", p.Channel, section)
            . SettingTextLine("Id", p.Id, section) "Count=" p.Items.Length "`r`n"
        for j, item in p.Items
            text .= SettingTextLine("Label" j, item.Name, section) SettingTextLine("Text" j, item.Text, section) "Slot" j "=" ItemSlot(item) "`r`n"
    }
    text .= "`r`n[CommonDanmaku]`r`nCount=" state.SharedDanmakuItems.Length "`r`n"
    for j, item in state.SharedDanmakuItems
        text .= SettingTextLine("Label" j, item.Name, "CommonDanmaku") SettingTextLine("Text" j, item.Text, "CommonDanmaku") "Slot" j "=" ItemSlot(item) "`r`n"
    if (StrLen(text)+1)*2 > 32*1024*1024
        throw Error("設定ファイルが上限32MiBを超えます。")
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
ReadSettingInteger(document, section, key, fallback) {
    value := ReadSettingValue(document, section, key, fallback)
    if !IsInteger(value)
        throw Error("設定値が整数ではありません：[" section "] " key)
    try return Integer(value)
    catch
        throw Error("設定値が整数ではありません：[" section "] " key)
}


ValidateItemSection(document, section, count) {
    if count > 100000
        throw Error("弾幕数が上限100000件を超えています：[" section "] Count")
    Loop count {
        key := "Text" A_Index
        if !document.Has(section) || !document[section].Has(key) || !Trim(document[section][key])
            throw Error("弾幕の本文がないか空です：[" section "] " key)
    }
}
