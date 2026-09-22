; Pure presentation builders: no controls, timers, globals or browser calls.
BuildPaletteContext(profiles, inputId, autoMode, matched, detectionMessage) {
    names := []
    for profile in profiles
        names.Push(profile.Name)
    index := FindProfileIndexById(profiles,inputId), profile := index ? profiles[index] : 0
    return {Names:names, Choice:autoMode && !matched ? 0 : index,
        CanChoose:!autoMode && profiles.Length > 0,
        Context:"弾幕の入力対象：" (profile && matched ? profile.Name : "共通の弾幕のみ")
            . "`n" (autoMode ? detectionMessage : "手動選択：下の欄で配信者を選べます。")}
}
BuildPaletteItems(profiles, sharedItems, inputId, matched, query, keys := 0) {
    rows := [], query := Trim(query), profile := FindProfileById(profiles,inputId)
    limit := 500
    truncated := profile && matched ? CollectPresentationItems(rows,profile.Items,profile.Id,query,limit,keys) : false
    truncated := truncated || CollectPresentationItems(rows,sharedItems,"",query,limit,keys)
    return {Rows:rows, Truncated:truncated, Hint:truncated ? "先頭" limit "件を表示しています。検索で絞り込んでください。"
        : rows.Length ? "弾幕は入力のみ。内容を確認してYouTubeで送信します。"
        : (query != "" ? "一致する弾幕がありません。検索条件を変えてください。" : "「弾幕を追加・編集」から登録できます。共通弾幕は配信者不要です。")}
}
BuildManagementPresentation(profiles, sharedItems, editId, keys := 0) {
    index := FindProfileIndexById(profiles,editId), profile := index ? profiles[index] : 0
    names := ["共通の弾幕"], rows := []
    for entry in profiles
        names.Push(entry.Name)
    id := profile ? profile.Id : ""
    CollectPresentationItems(rows,profile ? profile.Items : sharedItems,id,"",0,keys)
    return {Names:names, Choice:index+1, ProfileId:id,
        HasProfile:!!profile, Rows:rows, Channel:profile ? "チャンネル：" (profile.Channel != "" ? profile.Channel : "チャンネル未連携") : "すべてのチャンネルで使う弾幕です。"}
}
CollectPresentationItems(rows, items, profileId, query := "", limit := 0, keys := 0) {
    keys := keys ? keys : DefaultShortcutKeys()
    for i, item in items {
        if query != "" && !InStr(item.Name " " item.Text,query)
            continue
        if limit && rows.Length >= limit
            return true
        slot := ItemSlot(item), shared := profileId = ""
        rows.Push({Shared:shared, Index:i, ProfileId:profileId, Text:item.Text, Name:item.Name,
            ItemId:item.Id, Label:item.Name "　" item.Text,
            Key:slot ? StrReplace(ShortcutKeyLabel(keys[(shared ? "shared" : "profile") slot]),"＋","+") : ""})
    }
    return false
}
