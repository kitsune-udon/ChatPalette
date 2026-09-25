; Shortcut policy shared by danmaku and reactions.


ShortcutBlocked(action := "input") {
    policy := OperationPolicy(action)
    if policy.Allowed
        return false
    ShowStatusTip(policy.Message,2500)
    return true
}

WaitShortcutRelease(binding) {
    keys := [RegExReplace(binding,"[!^+]",""),"Control","Alt","Shift"]
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
    if !IsBrowser(hwnd) || !WaitShortcutRelease(GetShortcutKey(scope slot))
        return
    RequestShortcutInput(scope,slot,hwnd)
}

HandlePageShortcut(action) {
    if ShortcutBlocked("input")
        return
    hwnd := WinExist("A")
    if IsBrowser(hwnd)
        RunPageAction(action,hwnd,GetShortcutKey(action))
}
CanContinuePageAction(operation) {
    if ActivePageAction != operation || !IsTargetForeground(operation.Window)
        return false
    state := CurrentOperationState()
    ; Exclude this owner from the shared policy, while retaining the IPC busy check.
    state.BrowserBusy := IsBrowserOperationBusy
    return EvaluateOperation("input",state).Allowed
}
RunPageAction(action, hwnd, releaseBinding := "") {
    global ActivePageAction
    if !OperationAllowed("input") || !IsTargetForeground(hwnd)
        return false
    if action != "chat_focus" && action != "chat_clear" && action != "reactions_show"
        throw Error("不明なページ操作です。")
    started := AppClockMs(), stage := action = "reactions_show" ? "表示操作" : "フォーカス"
    result := {State:"unknown"}
    operation := {Window:hwnd,Pending:0,AcceptsPending:action = "chat_focus"}
    ActivePageAction := operation
    try {
        if releaseBinding != "" && !WaitShortcutRelease(releaseBinding) {
            result := {State:"cancelled"}
            return false
        }
        if !CanContinuePageAction(operation) {
            result := {State:"cancelled"}
            return false
        }
        result := RequestBrowserOperation(hwnd,action = "chat_clear" ? "chat_focus" : action)
        ; Close acceptance before deciding whether to drain; keep the page owner until publication.
        operation.AcceptsPending := false
        if !CanContinuePageAction(operation) {
            result := {State:"cancelled"}
            return false
        }
        if action = "chat_clear" && result.State = "focused" {
            stage := "クリア前の確認"
            if !result.HasOwnProp("Detail") || result.Detail = "" {
                result := {State:"wrong_input"}
                return false
            }
            result := RequestBrowserOperation(hwnd,"verify_chat",result.Video,"FocusToken=" result.Detail)
            if result.State = "ok" {
                if !CanContinuePageAction(operation) {
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
        if operation.Pending && result.State = "focused" {
            stage := "保留した弾幕の入力"
            result := CompleteFocusedDanmaku(operation,result)
        }
    } catch {
        result := {State:"unknown"}
    } finally {
        operation.AcceptsPending := false
        ; Result publication belongs to this operation; cleanup also runs if rendering fails.
        if ActivePageAction = operation {
            try {
                RecordBrowserOperation({Mode:action,State:result.State,Stage:stage,Window:hwnd,Duration:Round(AppClockMs()-started)})
                info := BrowserResultInfo(result.State)
                message := info.Summary (info.Advice != "" ? "。" info.Advice : "。")
                PaletteHint.Text := message
                ShowStatusTip(message,3000)
            } finally {
                if ActivePageAction = operation
                    ActivePageAction := 0
                RefreshOperationControls()
            }
        }
    }
    return result.State = "inserted" || result.State = "focused" || result.State = "cleared" || result.State = "hovered"
}

EffectiveShortcutSummary() {
    keys := CurrentShortcutMap(), summary := ""
    for definition in ShortcutDefinitions()
        summary .= (summary = "" ? "" : "`n") ShortcutKeyLabel(keys[definition.Id]) "：" definition.Label "（" definition.Scope "）"
    return summary
}
