; Pure key validation and normalization; no UI or hotkey registration.
ValidLegacyReactionKey(key) {
    return !IsLegacyReservedReactionKey(key) && RegExMatch(key, "^[!^+]*(?:[A-Za-z0-9]|F(?:[1-9]|1[0-2]))$")
        && InStr(key, "^") && (InStr(key, "!") || InStr(key, "+"))
}

CanonicalReactionKey(key) {
    return (InStr(key,"^") ? "^" : "") (InStr(key,"!") ? "!" : "") (InStr(key,"+") ? "+" : "") StrLower(RegExReplace(key,"[!^+]",""))
}

IsLegacyReservedReactionKey(key) {
    plain := StrLower(RegExReplace(key, "[!^+]", ""))
    return InStr(key, "^") && InStr(key, "!") && !InStr(key, "+") && (plain = "1" || plain = "2" || plain = "3" || plain = "4" || plain = "q")
}

ShortcutDefinitions() {
    static definitions := [
        {Id:"palette",Label:"パレットを開く",Default:"^!q",Scope:"どの画面でも"},
        {Id:"profile1",Label:"配信者の弾幕 1",Default:"^!1",Scope:"ブラウザー"},
        {Id:"profile2",Label:"配信者の弾幕 2",Default:"^!2",Scope:"ブラウザー"},
        {Id:"shared1",Label:"共通の弾幕 1",Default:"^!3",Scope:"ブラウザー"},
        {Id:"shared2",Label:"共通の弾幕 2",Default:"^!4",Scope:"ブラウザー"},
        {Id:"chat_focus",Label:"チャット欄へフォーカス",Default:"^!f",Scope:"ブラウザー"},
        {Id:"chat_clear",Label:"チャット欄をクリア",Default:"^!c",Scope:"ブラウザー"},
        {Id:"reactions_show",Label:"リアクションUIを表示",Default:"^!e",Scope:"ブラウザー"},
        {Id:"reaction",Label:"リアクションを実行",Default:"^!r",Scope:"ブラウザー"},
        {Id:"stop",Label:"リアクションを停止",Default:"Esc",Scope:"実行・待機中"}]
    return definitions
}
DefaultShortcutKeys(reactionKey := "") {
    keys := Map()
    for definition in ShortcutDefinitions() {
        if definition.Id = "reaction"
            continue
        key := definition.Default
        ; Old versions gave a saved reaction key priority over page actions.
        if reactionKey != "" && CanonicalReactionKey(key) = CanonicalReactionKey(reactionKey)
            key := ""
        keys[definition.Id] := key
    }
    return keys
}
PreferenceShortcutMap(state) {
    keys := state.HasOwnProp("ShortcutKeys") ? state.ShortcutKeys.Clone() : DefaultShortcutKeys(state.ReactionShortcut)
    keys["reaction"] := state.ReactionShortcut
    return keys
}
ValidShortcutKey(key) {
    return RegExMatch(key,"^[!^+]*(?:[A-Za-z0-9]|F(?:[1-9]|1[0-2]))$")
        && InStr(key,"^") && (InStr(key,"!") || InStr(key,"+"))
        && StrLen(RegExReplace(key,"[^!^+]","")) = !!InStr(key,"^")+!!InStr(key,"!")+!!InStr(key,"+")
}
ValidateShortcutMap(keys) {
    if keys.Count != ShortcutDefinitions().Length
        throw Error("キー設定の項目が不足または不正です。")
    used := Map()
    for definition in ShortcutDefinitions() {
        if !keys.Has(definition.Id)
            throw Error("キー設定の項目がありません。")
        key := keys[definition.Id]
        if key = "" {
            if definition.Id = "palette" || definition.Id = "reaction" || definition.Id = "stop"
                throw Error("「" definition.Label "」のキーを指定してください。")
            continue
        }
        if !(definition.Id = "stop" && StrLower(key) = "esc") && !ValidShortcutKey(key)
            throw Error("「" definition.Label "」はCtrl＋Alt、またはCtrl＋Shiftを含むキーを指定してください。")
        canonical := CanonicalReactionKey(key)
        if used.Has(canonical)
            throw Error("「" used[canonical] "」と「" definition.Label "」のキーが重複しています。")
        used[canonical] := definition.Label
    }
}
ShortcutKeyLabel(key) {
    if key = ""
        return "未割当"
    if StrLower(key) = "esc"
        return "Esc"
    return (InStr(key,"^") ? "Ctrl＋" : "") (InStr(key,"!") ? "Alt＋" : "")
        . (InStr(key,"+") ? "Shift＋" : "") StrUpper(RegExReplace(key,"[!^+]",""))
}
