; A single pending shortcut belongs to one focus operation; it is never persisted.
QueueFocusedDanmaku(scope,slot,hwnd) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        focus := ActivePageAction
        if !focus || !focus.AcceptsPending
            return false
        if focus.Pending || hwnd != focus.Window || !IsTargetForeground(hwnd)
            return true
        focus.Pending := {Scope:scope,Slot:slot,Binding:GetShortcutKey(scope slot),Deadline:AppClockMs()+5000,
            Library:{Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}}
        ShowStatusTip("フォーカス完了後に弾幕を1件入力します。")
        return true
    } finally Critical(previousCritical)
}
CompleteFocusedDanmaku(focus,result) {
    pending := focus.Pending
    cancelled := {State:"input_cancelled"}
    try {
        if !CanContinuePageAction(focus) || AppClockMs() > pending.Deadline
            return cancelled
        if !WaitShortcutRelease(pending.Binding)
            return cancelled
        if !CanContinuePageAction(focus) || AppClockMs() > pending.Deadline
            return cancelled
        if !result.HasOwnProp("Detail") || result.Detail = ""
            return cancelled
        context := ResolveInputContext(pending.Scope,focus.Window)
        if !context || !(context.Video == result.Video)
            return cancelled
        plan := PlanShortcutInput(pending.Library,context,pending.Slot)
        if !CanContinuePageAction(focus) || AppClockMs() > pending.Deadline
            return cancelled
        verified := RequestBrowserOperation(focus.Window,"verify_chat",result.Video,"FocusToken=" result.Detail)
        if verified.State != "ok" || !(verified.Video == result.Video)
            return cancelled
        if !CanContinuePageAction(focus) || AppClockMs() > pending.Deadline
            return cancelled
        return SendPlannedDanmaku(plan,focus)
    } catch {
        return cancelled
    }
}
