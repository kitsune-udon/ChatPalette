; Entry adapters resolve slots/rows to IDs; the common planner only accepts identities.
ResolveInputContext(scope, hwnd) {
    if scope != "shared" && scope != "profile"
        throw Error("不明な弾幕の対象です。")
    if !IsBrowser(hwnd)
        throw Error("YouTubeのチャット欄かコメント欄をクリックしてから、" ShortcutKeyLabel(GetShortcutKey("palette")) "を押してください。")
    if scope = "profile" && AutoMode {
        selected := SelectProfileFromBrowser(hwnd)
        RefreshVisiblePalette()
        if !selected
            return 0
        video := DetectedChannel.Video
    } else {
        context := RequestBrowserOperation(hwnd,"browser_context")
        if context.State != "ok"
            throw Error("YouTubeの動画を確認できませんでした。")
        video := context.Video
    }
    profile := scope = "profile" ? GetInputProfile() : 0
    if scope = "profile" && !profile
        throw Error("配信者が変わりました。弾幕を選び直してください。")
    return {ProfileId:profile ? profile.Id : "", Window:hwnd, Video:video}
}
ResolveDanmakuInput(request) {
    context := ResolveInputContext(request.ProfileId = "" ? "shared" : "profile",request.Window)
    return context ? PlanDanmakuInput(request,context) : 0
}
ResolveShortcutInput(scope, slot, hwnd) {
    context := ResolveInputContext(scope,hwnd)
    if !context
        return 0
    items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},context.ProfileId)
    for item in items {
        if ItemSlot(item) = slot
            return PlanDanmakuInput({ProfileId:context.ProfileId, ItemId:item.Id, ExpectedText:item.Text},context)
    }
    throw Error("このキーに弾幕が割り当てられていません。")
}
PlanDanmakuInput(request, context) {
    if !(context.ProfileId == request.ProfileId)
        throw Error("配信者が変わりました。弾幕を選び直してください。")
    items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},request.ProfileId)
    for item in items {
        if item.Id == request.ItemId {
            if !(item.Text == request.ExpectedText)
                break
            return {Text:item.Text, Window:context.Window, Video:context.Video}
        }
    }
    throw Error("弾幕が変更されました。選び直してください。")
}
RequestDanmakuInput(request) {
    RunDanmakuInput(() => ResolveDanmakuInput(request),request.Origin)
}
RequestShortcutInput(scope, slot, hwnd) {
    RunDanmakuInput(() => ResolveShortcutInput(scope,slot,hwnd),"shortcut")
}
RunDanmakuInput(resolve, origin) {
    if !OperationAllowed("input")
        return
    try plan := resolve.Call()
    catch as failure {
        PaletteHint.Text := failure.Message
        ShowStatusTip(failure.Message,3000)
        return
    }
    if !plan || !OperationAllowed("input")
        return
    if origin = "palette"
        PaletteWindow.Hide()
    if !DeliverText(plan.Text,plan.Window,plan.Video,origin = "palette")
        ShowInputFailure()
}
