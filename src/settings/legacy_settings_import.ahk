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

ReadLegacySettings(path) {
    document := ReadSettingsDocument(path)
    if FileExist(path) && Integer(ReadSettingValue(document,"General","Schema","0")) > 3
        throw Error("未対応のINI設定形式です。")
    ; Missing files initialize normally; existing files must declare their records.
    if FileExist(path) {
        RequireSettingCount(document, "General")
        if document.Has("CommonDanmaku")
            RequireSettingCount(document, "CommonDanmaku")
    }
    state := {Profiles: [], SharedDanmakuItems: []}
    commonCount := ReadSettingInteger(document, "CommonDanmaku", "Count", "-1")
    if commonCount < -1 || (document.Has("CommonDanmaku") && commonCount < 0)
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
    for section in document {
        if RegExMatch(section, "i)^Profile(\d+)$", &match)
            if Integer(match[1]) < 1 || Integer(match[1]) > count || section != "Profile" Integer(match[1])
                throw Error("配信者数とセクションが一致しません：[" section "] / [General] Count")
    }
    Loop count {
        section := "Profile" A_Index
        if !document.Has(section) || !document[section].Has("Name")
            throw Error("配信者の必須項目がありません：[" section "] Name")
        p := {Name: ReadSettingValue(document, section, "Name", "配信者" A_Index), Channel: ReadSettingValue(document, section, "Channel", ""), Id: ReadSettingValue(document, section, "Id", NewRecordId()), Items: []}
        RequireSettingCount(document, section)
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
    index := Min(Max(ReadSettingInteger(document, "General", "Current", "0"), 0), state.Profiles.Length)
    NormalizeLibrarySlots(state.SharedDanmakuItems)
    ids := Map()
    for profile in state.Profiles {
        if profile.Id = "" || ids.Has(profile.Id)
            profile.Id := NewRecordId()
        ids[profile.Id] := true
        NormalizeLibrarySlots(profile.Items)
    }
    state.InputProfileId := index ? state.Profiles[index].Id : ""
    return ReadReactionSettings(state, document)
}

ReadReactionSettings(state, document) {
    state.DefaultReactionKind := Min(ReactionNames.Length, Max(1, ReadSettingInteger(document, "General", "ReactionDefault", ReactionDefaults.Choice)))
    state.DefaultReactionCount := ReadSettingInteger(document, "General", "ReactionCount", ReactionDefaults.Count)
    if !HasSettingValue(ReactionCounts, state.DefaultReactionCount)
        state.DefaultReactionCount := ReactionDefaults.Count
    state.DefaultReactionIntervalMs := ReadSettingInteger(document, "General", "ReactionInterval", ReactionDefaults.Interval)
    if !HasSettingValue(ReactionIntervals, state.DefaultReactionIntervalMs)
        state.DefaultReactionIntervalMs := ReactionDefaults.Interval
    key := ReadSettingValue(document, "General", "ReactionShortcut", DefaultShortcutKeys()["reaction"])
    state.ShortcutKeys := ImportShortcutKeys(ValidLegacyReactionKey(key) ? key : DefaultShortcutKeys()["reaction"])
    return state
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
    if document.Has(section) {
        for key in document[section] {
            if RegExMatch(key, "i)^(Text|Label|Slot)(\d+)$", &match)
                if Integer(match[2]) < 1 || Integer(match[2]) > count || key != match[1] Integer(match[2])
                    throw Error("弾幕数と項目が一致しません：[" section "] " key " / Count")
        }
    }
    Loop count {
        key := "Text" A_Index
        if !document.Has(section) || !document[section].Has(key) || !Trim(document[section][key])
            throw Error("弾幕の本文がないか空です：[" section "] " key)
    }
}

RequireSettingCount(document, section) {
    if !document.Has(section) || !document[section].Has("Count")
        throw Error("設定の必須項目がありません：[" section "] Count")
}

ValidLegacyReactionKey(key) {
    return !IsLegacyReservedReactionKey(key) && RegExMatch(key, "^[!^+]*(?:[A-Za-z0-9]|F(?:[1-9]|1[0-2]))$")
        && InStr(key, "^") && (InStr(key, "!") || InStr(key, "+"))
}

IsLegacyReservedReactionKey(key) {
    plain := StrLower(RegExReplace(key, "[!^+]", ""))
    return InStr(key, "^") && InStr(key, "!") && !InStr(key, "+") && (plain = "1" || plain = "2" || plain = "3" || plain = "4" || plain = "q")
}
