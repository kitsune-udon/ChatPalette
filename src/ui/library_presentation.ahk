; Pure presentation builders: no controls, timers, globals or browser calls.
BuildPaletteContext(profiles, profile, autoMode, detectionMessage) {
    index := profile ? FindProfileIndexById(profiles,profile.Id) : 0
    ; Published profiles are immutable; SyncProfileChoices owns the displayed snapshot.
    return {Choices:profiles, Choice:index,
        Context:"弾幕の入力対象：" (profile ? profile.Name : "共通の弾幕のみ")
            . "`n" (autoMode ? detectionMessage : "手動選択：下の欄で配信者を選べます。")}
}
BuildPaletteItems(profile, sharedItems, query, keys) {
    rows := [], query := Trim(query)
    limit := 500
    truncated := profile ? CollectPresentationItems(rows,profile.Items,profile.Id,query,limit,keys) : false
    truncated := truncated || CollectPresentationItems(rows,sharedItems,"",query,limit,keys)
    return {Rows:rows, Hint:truncated ? "先頭" limit "件を表示しています。検索で絞り込んでください。"
        : rows.Length ? "弾幕は入力のみ。内容を確認してYouTubeで送信します。"
        : (query != "" ? "一致する弾幕がありません。検索条件を変えてください。" : "「弾幕を追加・編集」から登録できます。共通弾幕は配信者不要です。")}
}
BuildManagementPresentation(profiles, sharedItems, editId, keys) {
    index := FindProfileIndexById(profiles,editId), profile := index ? profiles[index] : 0
    choices := profiles.Clone()
    choices.InsertAt(1,{Id:"",Name:"共通の弾幕"})
    id := profile ? profile.Id : ""
    return {Choices:choices, Choice:index+1, ProfileId:id,
        Content:BuildManagedContent(profile ? profile.Items : sharedItems,id,keys),
        Channel:profile ? "チャンネル：" (profile.Channel != "" ? profile.Channel : "チャンネル未連携") : "すべてのチャンネルで使う弾幕です。"}
}
CollectPresentationItems(rows, items, profileId, query, limit, keys) {
    for i, item in items {
        if query != "" && !InStr(item.Name " " item.Text,query)
            continue
        if rows.Length >= limit
            return true
        rows.Push(BuildPresentationRow(item,i,profileId,keys))
    }
    return false
}

; Palette rows capture the displayed values independently of the live items.
BuildPresentationRow(item, index, profileId, keys) {
    scope := profileId = "" ? "shared" : "profile", slot := item.Slot
    return {Index:index, ProfileId:profileId, Text:item.Text, Name:item.Name, ItemId:item.Id,
        Key:slot ? StrReplace(ShortcutKeyLabel(keys[scope slot]),"＋","+") : ""}
}

; Own one immutable item sequence and its key labels, not a second object per item.
BuildManagedContent(items, profileId, keys) {
    scope := profileId = "" ? "shared" : "profile"
    return {Items:items, KeyLabels:["",StrReplace(ShortcutKeyLabel(keys[scope 1]),"＋","+"),StrReplace(ShortcutKeyLabel(keys[scope 2]),"＋","+")]}
}
ManagedCellText(content, index, column) {
    if index < 1 || index > content.Items.Length
        return ""
    item := content.Items[index]
    switch column {
        case 1: return item.Name
        case 2: return item.Text
        case 3: return content.KeyLabels[item.Slot+1]
        case 4: return item.Id
    }
    return ""
}
