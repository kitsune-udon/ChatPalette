; Shortcut policy shared by danmaku and reactions.


ShortcutBlocked(action := "input") {
    policy := OperationPolicy(action)
    if policy.Allowed
        return false
    ShowStatusTip(policy.Message,2500)
    return true
}

WaitShortcutRelease(keys) {
    return RuntimePorts.ShortcutRelease ? RuntimePorts.ShortcutRelease.Call(keys) : NativeWaitShortcutRelease(keys)
}

NativeWaitShortcutRelease(keys) {
    for key in keys {
        if !KeyWait(key, "T2") {
            ShowStatusTip("キーを離してから、もう一度押してください。",2500)
            return false
        }
    }
    return true
}




HandleDanmakuShortcut(scope,slot) {
    if QueueFocusedDanmaku(scope,slot,WinExist("A"))
        return
    if ShortcutBlocked()
        return
    hwnd := WinExist("A")
    key := RegExReplace(GetShortcutKey(scope slot),"[!^+]","")
    if !IsBrowser(hwnd) || !WaitShortcutRelease([key,"Control","Alt","Shift"])
        return
    RequestShortcutInput(scope,slot,hwnd)
}

HandlePageShortcut(action, key) {
    if ShortcutBlocked("input")
        return
    hwnd := WinExist("A")
    if IsBrowser(hwnd)
        RunPageAction(action,hwnd,key)
}
RunPageAction(action, hwnd, releaseKey := "") {
    global ActiveChatFocus
    if !OperationAllowed("input") || !IsTargetForeground(hwnd)
        return false
    if action != "chat_focus" && action != "chat_clear" && action != "reactions_show"
        throw Error("不明なページ操作です。")
    started := A_TickCount, stage := action = "reactions_show" ? "表示操作" : "フォーカス"
    result := {State:"unknown"}
    focus := action = "chat_focus" ? {Window:hwnd,Pending:0} : 0
    if focus
        ActiveChatFocus := focus
    try {
        if releaseKey != "" && !WaitShortcutRelease([releaseKey,"Control","Alt","Shift"]) {
            result := {State:"cancelled"}
            return false
        }
        if !(focus ? CanContinueChatFocus(focus) : OperationAllowed("input")) || !IsTargetForeground(hwnd) {
            result := {State:"cancelled"}
            return false
        }
        result := RequestBrowserOperation(hwnd,action = "chat_clear" ? "chat_focus" : action)
        if action = "chat_clear" && result.State = "focused" {
            stage := "クリア前の確認"
            if !OperationAllowed("input") || !IsTargetForeground(hwnd) {
                result := {State:"cancelled"}
                return false
            }
            result := RequestBrowserOperation(hwnd,"verify_chat",result.Video)
            if result.State = "ok" {
                if !OperationAllowed("input") || !IsTargetForeground(hwnd) {
                    result := {State:"cancelled"}
                    return false
                }
                stage := "クリアキー送信", result := {State:"unknown"}
                if RuntimePorts.ClearChat
                    RuntimePorts.ClearChat.Call()
                else
                    Send("^a{Backspace}")
                result := {State:"cleared"}
            }
        }
        if focus {
            ; Close an empty queue atomically: a later shortcut runs normally,
            ; rather than being accepted after the drain decision.
            previousCritical := A_IsCritical
            Critical("On")
            if !focus.Pending && ActiveChatFocus = focus
                ActiveChatFocus := 0
            Critical(previousCritical)
        }
        if focus && focus.Pending && result.State = "focused" {
            stage := "保留した弾幕の入力"
            result := CompleteFocusedDanmaku(focus,result)
        }
    } catch {
        result := {State:"unknown"}
    } finally {
        if focus && ActiveChatFocus = focus
            ActiveChatFocus := 0
        RefreshOperationControls()
        RecordBrowserOperation({Mode:action,State:result.State,Stage:stage,Window:hwnd,Duration:A_TickCount-started})
        info := BrowserResultInfo(result.State)
        message := info.Summary (info.Advice != "" ? "。" info.Advice : "。")
        PaletteHint.Text := message
        ShowStatusTip(message,3000)
    }
    return result.State = "inserted" || result.State = "focused" || result.State = "cleared" || result.State = "hovered"
}

EffectiveShortcutSummary() {
    keys := CurrentShortcutMap(), summary := ""
    for definition in ShortcutDefinitions()
        summary .= (summary = "" ? "" : "`n") ShortcutKeyLabel(keys[definition.Id]) "：" definition.Label "（" definition.Scope "）"
    return summary
}
