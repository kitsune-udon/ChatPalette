; Pure presentation builders: no controls, timers, globals or browser calls.
BuildPaletteContext(profiles, profile, autoMode, detectionMessage) {
    choices := [], index := 0
    for i, entry in profiles {
        choices.Push({Id:entry.Id,Name:entry.Name})
        if profile && entry.Id == profile.Id
            index := i
    }
    return {Choices:choices, Choice:index,
        CanChoose:!autoMode && profiles.Length > 0,
        Context:"弾幕の入力対象：" (profile ? profile.Name : "共通の弾幕のみ")
            . "`n" (autoMode ? detectionMessage : "手動選択：下の欄で配信者を選べます。")}
}
BuildPaletteItems(profile, sharedItems, query, keys) {
    rows := [], query := Trim(query)
    limit := 500
    truncated := profile ? CollectPresentationItems(rows,profile.Items,profile.Id,query,limit,keys) : false
    truncated := truncated || CollectPresentationItems(rows,sharedItems,"",query,limit,keys)
    return {Rows:rows, Truncated:truncated, Hint:truncated ? "先頭" limit "件を表示しています。検索で絞り込んでください。"
        : rows.Length ? "弾幕は入力のみ。内容を確認してYouTubeで送信します。"
        : (query != "" ? "一致する弾幕がありません。検索条件を変えてください。" : "「弾幕を追加・編集」から登録できます。共通弾幕は配信者不要です。")}
}
BuildManagementPresentation(profiles, sharedItems, editId, keys) {
    index := FindProfileIndexById(profiles,editId), profile := index ? profiles[index] : 0
    choices := [{Id:"",Name:"共通の弾幕"}], rows := []
    for entry in profiles
        choices.Push({Id:entry.Id,Name:entry.Name})
    id := profile ? profile.Id : ""
    CollectPresentationItems(rows,profile ? profile.Items : sharedItems,id,"",0,keys)
    return {Choices:choices, Choice:index+1, ProfileId:id,
        Rows:rows, Channel:profile ? "チャンネル：" (profile.Channel != "" ? profile.Channel : "チャンネル未連携") : "すべてのチャンネルで使う弾幕です。"}
}
CollectPresentationItems(rows, items, profileId, query, limit, keys) {
    for i, item in items {
        if query != "" && !InStr(item.Name " " item.Text,query)
            continue
        if limit && rows.Length >= limit
            return true
        rows.Push(BuildPresentationRow(item,i,profileId,keys))
    }
    return false
}

; Full lists and partial reorder updates use the same captured values and key label.
BuildPresentationRow(item, index, profileId, keys) {
    scope := profileId = "" ? "shared" : "profile", slot := item.Slot
    return {Index:index, ProfileId:profileId, Text:item.Text, Name:item.Name, ItemId:item.Id,
        Key:slot ? StrReplace(ShortcutKeyLabel(keys[scope slot]),"＋","+") : ""}
}
