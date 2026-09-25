; A single pending shortcut belongs to one focus operation; it is never persisted.
QueueFocusedDanmaku(scope,slot,hwnd) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        focus := ActiveChatFocus
        if !focus
            return false
        if focus.Pending || hwnd != focus.Window || !IsTargetForeground(hwnd)
            return true
        key := RegExReplace(GetShortcutKey(scope slot),"[!^+]","")
        focus.Pending := {Scope:scope,Slot:slot,Key:key,Deadline:A_TickCount+5000,
            Library:{Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}}
        ShowStatusTip("フォーカス完了後に弾幕を1件入力します。")
        return true
    } finally Critical(previousCritical)
}
CanContinueChatFocus(focus) {
    if ActiveChatFocus != focus || !IsTargetForeground(focus.Window)
        return false
    state := CurrentOperationState()
    ; Only this operation may proceed while it owns the pending input.
    state.BrowserBusy := IsBrowserOperationBusy
    return EvaluateOperation("input",state).Allowed
}
CompleteFocusedDanmaku(focus,result) {
    pending := focus.Pending
    cancelled := {State:"input_cancelled"}
    try {
        if !CanContinueChatFocus(focus) || A_TickCount > pending.Deadline
            return cancelled
        if !WaitShortcutRelease([pending.Key,"Control","Alt","Shift"])
            return cancelled
        if !CanContinueChatFocus(focus) || A_TickCount > pending.Deadline
            return cancelled
        if !result.HasOwnProp("Detail") || result.Detail = ""
            return cancelled
        context := ResolveInputContext(pending.Scope,focus.Window)
        if !context || !(context.Video == result.Video)
            return cancelled
        request := 0
        for item in GetLibraryItems(pending.Library,context.ProfileId)
            if ItemSlot(item) = pending.Slot {
                request := {ProfileId:context.ProfileId,ItemId:item.Id,ExpectedText:item.Text}
                break
            }
        if !request
            return cancelled
        plan := PlanDanmakuInput(request,context)
        if !CanContinueChatFocus(focus) || A_TickCount > pending.Deadline
            return cancelled
        verified := RequestBrowserOperation(focus.Window,"verify_chat",result.Video,"FocusToken=" result.Detail)
        if verified.State != "ok" || !(verified.Video == result.Video)
            return cancelled
        if !CanContinueChatFocus(focus) || A_TickCount > pending.Deadline
            return cancelled
        ; Verify the frozen item again after yielding to the worker.
        PlanDanmakuInput(request,context)
        return SendInputText(plan.Text)
    } catch {
        return cancelled
    }
}
