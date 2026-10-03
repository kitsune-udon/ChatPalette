; Entry adapters resolve slots/rows to IDs; the common planner only accepts identities.
ResolveInputContext(scope, hwnd) {
    if scope != "shared" && scope != "profile"
        throw Error("不明な弾幕の対象です。")
    if !IsBrowser(hwnd)
        throw Error("YouTubeのチャット欄かコメント欄をクリックしてから、" ShortcutKeyLabel(GetShortcutKey("palette")) "を押してください。")
    if scope = "profile" && AutoMode {
        selected := SelectProfileFromBrowser(hwnd)
        RefreshVisiblePalette()
        return selected
    }
    context := RequestBrowserOperation(hwnd,"browser_context")
    if context.State != "ok"
        throw Error("YouTubeの動画を確認できませんでした。")
    profile := scope = "profile" ? GetInputProfile() : 0
    if scope = "profile" && !profile
        throw Error("配信者が変わりました。弾幕を選び直してください。")
    return {ProfileId:profile ? profile.Id : "", Window:hwnd, Video:context.Video}
}
ResolveDanmakuInput(request) {
    context := ResolveInputContext(request.ProfileId = "" ? "shared" : "profile",request.Window)
    return context ? PlanDanmakuInput(request,context) : 0
}
ResolveShortcutInput(scope, slot, hwnd, shortcut := 0) {
    if shortcut && !ShortcutRequestCurrent(shortcut)
        return 0
    context := ResolveInputContext(scope,hwnd)
    if !context
        return 0
    if shortcut && !(context.Video == shortcut.Session.Video)
        throw Error("動画が変わりました。ショートカットを押し直してください。")
    return PlanShortcutInput(shortcut ? shortcut.Library : {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},context,slot)
}
; Callers choose the library snapshot; assignment resolution is identical for both routes.
PlanShortcutInput(library, context, slot) {
    for item in GetLibraryItems(library,context.ProfileId) {
        if item.Slot = slot
            return PlanDanmakuInput({ProfileId:context.ProfileId, ItemId:item.Id, ExpectedText:item.Text},context)
    }
    throw Error("このキーに弾幕が割り当てられていません。")
}
PlanDanmakuInput(request, context) {
    if !(context.ProfileId == request.ProfileId)
        throw Error("配信者が変わりました。弾幕を選び直してください。")
    plan := {ProfileId:request.ProfileId, ItemId:request.ItemId, Text:request.ExpectedText,
        Window:context.Window, Video:context.Video}
    ValidateDanmakuInput(plan)
    return plan
}
ValidateDanmakuInput(plan) {
    items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},plan.ProfileId)
    for item in items {
        if item.Id == plan.ItemId {
            if !(item.Text == plan.Text)
                break
            return
        }
    }
    throw Error("弾幕が変更されました。選び直してください。")
}
SendPlannedDanmaku(plan, shortcut := 0) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        ; Prevent app callbacks between final identity validation and the one send.
        try ValidateDanmakuInput(plan)
        catch
            return {State:"input_cancelled"}
        canSend := OperationAllowed("input") && IsTargetForeground(plan.Window)
            && (!shortcut || (shortcut.Window = plan.Window && ShortcutRequestCurrent(shortcut)))
        if !canSend
            return {State:"input_cancelled"}
        return SendInputText(plan.Text)
    } finally Critical(previousCritical)
}
RequestDanmakuInput(request) {
    RunDanmakuInput(() => ResolveDanmakuInput(request),request.Origin)
}
RequestShortcutInput(scope, slot, hwnd, shortcut := 0) {
    return RunDanmakuInput(() => ResolveShortcutInput(scope,slot,hwnd,shortcut),"shortcut",shortcut)
}
RunDanmakuInput(resolve, origin, shortcut := 0) {
    if !OperationAllowed("input")
        return {State:"input_cancelled"}
    try {
        plan := resolve.Call()
        if !plan || !OperationAllowed("input")
            return {State:"input_cancelled"}
        if origin = "palette"
            PaletteWindow.Hide()
        result := DeliverDanmakuInput(plan,origin = "palette",shortcut)
    } catch as failure {
        PaletteHint.Text := failure.Message
        ShowStatusTip(failure.Message,3000)
        return {State:"input_cancelled"}
    }
    if result.State != "inserted"
        ShowInputFailure(result.State)
    return result
}
DeliverDanmakuInput(plan, activate := false, shortcut := 0) {
    hwnd := plan.Window
    if activate {
        try WinActivate("ahk_id " hwnd)
        catch TargetError
            return {State:"input_cancelled"}
        if !WinWaitActive("ahk_id " hwnd, , 2)
            return {State:"input_cancelled"}
        KeyWait("Enter")
        KeyWait("LButton")
    }
    if !IsTargetForeground(hwnd)
        return {State:"input_cancelled"}
    if shortcut && shortcut.Session.Focus {
        focus := shortcut.Session.Focus
        shortcut.Session.Focus := 0
        verified := VerifyChatFocus(hwnd,focus)
    } else
        verified := VerifyInputTarget(hwnd, plan.Video)
    if verified.State != "ok"
        return verified
    return SendPlannedDanmaku(plan,shortcut)
}
