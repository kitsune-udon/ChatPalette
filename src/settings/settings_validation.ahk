; Application data constraints, independent of serialization and windows.
ValidateSettingsPreferences(state) {
    if !HasSettingValue([0,1],state.AutoMode) || !HasSettingValue(ReactionCounts,state.DefaultReactionCount)
        || !HasSettingValue(ReactionIntervals,state.DefaultReactionIntervalMs)
        || !IsInteger(state.DefaultReactionKind) || state.DefaultReactionKind < 1 || state.DefaultReactionKind > ReactionNames.Length
        throw Error("共通設定の値が正しくありません。")
    ValidateShortcutMap(state.ShortcutKeys)
}
ValidateSettingsText(value, label, required := false) {
    if InStr(value,"`r") || InStr(value,"`n") || (required && !Trim(value))
        throw Error(label "が空、または改行を含んでいます。")
    if StrLen(value) > 16*1024*1024
        throw Error(label "が長すぎます。")
}
HasSettingValue(values, value) {
    for entry in values
        if entry = value
            return true
    return false
}
