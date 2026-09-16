; Resolve once, then verify the pinned video immediately before writing text.
ResolveDanmakuInput(shared, itemReference, hwnd, bySlot := false, expectedProfileId := "") {
    if !IsBrowser(hwnd)
        throw Error("YouTubeのチャット欄かコメント欄をクリックしてから、Ctrl＋Alt＋Qを押してください。")
    if !shared && AutoMode {
        if !SelectProfileFromBrowser(hwnd)
            return 0
        video := DetectedChannel.Video
    } else {
        context := RequestBrowserOperation(hwnd,"browser_context")
        if context.State != "ok"
            throw Error("YouTubeの動画を確認できませんでした。")
        video := context.Video
    }
    profile := GetInputProfile()
    if !shared && (!profile || (expectedProfileId != "" && profile.Id != expectedProfileId))
        throw Error("配信者が変わりました。弾幕を選び直してください。")
    items := shared ? SharedDanmakuItems : profile.Items
    index := bySlot ? 0 : itemReference
    if bySlot {
        for i,item in items
            if ItemSlot(item) = itemReference {
                index := i
                break
            }
    }
    if index < 1 || index > items.Length
        throw Error(bySlot ? "このキーに弾幕が割り当てられていません。" : "弾幕を選び直してください。")
    return {Text:items[index].Text, Window:hwnd, Video:video}
}


RequestDanmakuInput(shared, itemReference, hwnd, bySlot := false, fromPalette := false, expectedProfileId := "") {
    if IsBrowserOperationBusy || ActiveReactionJob || ActiveEditorDialog
        return
    try plan := ResolveDanmakuInput(shared,itemReference,hwnd,bySlot,expectedProfileId)
    catch as failure {
        PaletteHint.Text := failure.Message
        ToolTip(failure.Message)
        SetTimer(() => ToolTip(),-3000)
        return
    }
    if !plan
        return
    if fromPalette
        PaletteWindow.Hide()
    if !DeliverText(plan.Text,plan.Window,plan.Video,fromPalette)
        ShowInputFailure()
}
