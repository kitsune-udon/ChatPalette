; Pure key validation and normalization; no UI or hotkey registration.
CanonicalShortcutKey(key) {
    return (InStr(key,"^") ? "^" : "") (InStr(key,"!") ? "!" : "") (InStr(key,"+") ? "+" : "") StrLower(RegExReplace(key,"[!^+]",""))
}

; Runtime registration and editor dirty state share semantic key equality.
ChangedShortcutBindings(previous, next) {
    changed := Map()
    for action, key in next
        if CanonicalShortcutKey(previous.Get(action,"")) != CanonicalShortcutKey(key)
            changed[action] := key
    return changed
}

ShortcutDefinitions() {
    static definitions := [
        {Id:"palette",Label:"パレットを開く",Default:"^!q",Scope:"どの画面でも"},
        {Id:"profile1",Label:"配信者の弾幕 1",Default:"^!1",Scope:"ブラウザー"},
        {Id:"profile2",Label:"配信者の弾幕 2",Default:"^!2",Scope:"ブラウザー"},
        {Id:"shared1",Label:"共通の弾幕 1",Default:"^!3",Scope:"ブラウザー"},
        {Id:"shared2",Label:"共通の弾幕 2",Default:"^!4",Scope:"ブラウザー"},
        {Id:"chat_focus",Label:"チャット欄へフォーカス",Default:"^!f",Scope:"ブラウザー"},
        {Id:"chat_clear",Label:"チャット欄をクリア",Default:"^!w",Scope:"ブラウザー"},
        {Id:"reactions_show",Label:"リアクションUIを表示",Default:"^!r",Scope:"ブラウザー"},
        {Id:"reaction",Label:"リアクションを実行",Default:"^!t",Scope:"ブラウザー"},
        {Id:"chat_send",Label:"Enterでメッセージ送信",Default:"^!e",Scope:"ブラウザー"},
        {Id:"stop",Label:"リアクションを停止",Default:"Esc",Scope:"実行・待機中"}]
    return definitions
}
DefaultShortcutKeys() {
    keys := Map()
    for definition in ShortcutDefinitions()
        keys[definition.Id] := definition.Default
    return keys
}
; Only validated v4/v1 maps use this conversion. Custom assignments never change.
UpgradeLegacyShortcutKeys(legacy) {
    if legacy.Has("chat_send")
        throw Error("旧形式のキー設定に不明な操作があります。")
    keys := legacy.Clone(), keys["chat_send"] := ""
    ValidateShortcutMap(keys)
    oldDefaults := Map("chat_clear","^!c","reactions_show","^!e","reaction","^!r")
    moved := Map(), defaults := DefaultShortcutKeys()
    for action, key in oldDefaults {
        if CanonicalShortcutKey(keys[action]) = key {
            moved[action] := keys[action]
            keys[action] := defaults[action]
        }
    }
    ; Reverting one blocked move can block another; the valid old map bounds the loop.
    loop {
        reverted := false
        for action, original in moved {
            if CanonicalShortcutKey(keys[action]) = CanonicalShortcutKey(original)
                continue
            for other, key in keys {
                if other != action && key != "" && CanonicalShortcutKey(key) = CanonicalShortcutKey(keys[action]) {
                    keys[action] := original, reverted := true
                    break
                }
            }
        }
        if !reverted
            break
    }
    available := true
    for action, key in keys
        if CanonicalShortcutKey(key) = CanonicalShortcutKey(defaults["chat_send"])
            available := false
    keys["chat_send"] := available ? defaults["chat_send"] : ""
    ValidateShortcutMap(keys)
    return keys
}
ValidShortcutKey(key) {
    return RegExMatch(key,"^[!^+]*(?:[A-Za-z0-9]|[Ff](?:[1-9]|1[0-2]))$")
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
        canonical := CanonicalShortcutKey(key)
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
