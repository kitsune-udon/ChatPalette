; Shortcut policy shared by danmaku and reactions.


ShortcutBlocked(action := "input") {
    policy := OperationPolicy(action)
    if policy.Allowed
        return false
    ShowStatusTip(policy.Message,2500)
    return true
}


CanContinuePageAction(operation) {
    if ActivePageAction != operation || !IsTargetForeground(operation.Window)
        return false
    if operation.HasOwnProp("Shortcut") && operation.Shortcut && !ShortcutRequestCurrent(operation.Shortcut)
        return false
    state := CurrentOperationState()
    ; Exclude this owner from the shared policy, while retaining the IPC busy check.
    state.BrowserBusy := IsBrowserOperationBusy
    return EvaluateOperation("input",state).Allowed
}
RunPageAction(action, hwnd, shortcut := 0) {
    global ActivePageAction
    if !OperationAllowed("input") || !IsTargetForeground(hwnd)
        return false
    if action != "chat_focus" && action != "chat_clear" && action != "reactions_show" && action != "chat_send"
        throw Error("不明なページ操作です。")
    started := AppClockMs(), stage := action = "reactions_show" ? "表示操作" : action = "chat_send" ? "送信前の確認" : "フォーカス"
    result := {State:"unknown"}
    operation := {Window:hwnd,Video:"",Shortcut:shortcut}
    ActivePageAction := operation
    try {
        if !CanContinuePageAction(operation) {
            result := {State:"cancelled"}
            return false
        }
        if action = "chat_send"
            result := VerifyShortcutInput(hwnd,shortcut ? shortcut.Session.Video : "",shortcut)
        else
            result := RequestBrowserOperation(hwnd,action = "chat_clear" ? "chat_focus" : action,shortcut ? shortcut.Session.Video : "")
        if !CanContinuePageAction(operation) {
            result := {State:"cancelled"}
            return false
        }
        operation.Video := result.HasOwnProp("Video") ? result.Video : ""
        if shortcut && !(operation.Video == shortcut.Session.Video) {
            result := {State:"changed"}
            return false
        }
        if action = "chat_send" && result.State = "ok" {
            if !result.HasOwnProp("Detail") || result.Detail != "chat" {
                result := {State:"wrong_input"}
                return false
            }
            previousCritical := A_IsCritical
            Critical("On")
            try {
                if !CanContinuePageAction(operation) {
                    result := {State:"cancelled"}
                    return false
                }
                stage := "Enterキー送信", result := {State:"unknown"}
                if RuntimePorts.SendEnter
                    RuntimePorts.SendEnter.Call()
                else
                    Send("{Enter}")
                result := {State:"enter_sent"}
            } finally Critical(previousCritical)
        }
        if action = "chat_clear" && result.State = "focused" {
            stage := "クリア前の確認"
            result := VerifyChatFocus(hwnd,result)
            if result.State = "ok" {
                previousCritical := A_IsCritical
                Critical("On")
                try {
                    ; Keep app callbacks out of the final target check and the one deletion.
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
                } finally Critical(previousCritical)
            }
        }
    } catch {
        result := {State:"unknown"}
    } finally {
        ; Result publication belongs to this operation; cleanup also runs if rendering fails.
        if ActivePageAction = operation {
            try {
                RecordBrowserOperation({Mode:action,State:result.State,Stage:stage,Window:hwnd,Duration:Round(AppClockMs()-started)})
                message := BrowserResultInfo(result.State).Message
                PaletteHint.Text := message
                ShowStatusTip(message,3000)
            } finally {
                if ActivePageAction = operation
                    ActivePageAction := 0
                RefreshOperationControls()
            }
        }
    }
    if shortcut && ShortcutRequestCurrent(shortcut)
        shortcut.Result := result
    return result.State = "focused" || result.State = "cleared" || result.State = "hovered" || result.State = "enter_sent"
}

EffectiveShortcutSummary() {
    keys := CurrentShortcutMap(), summary := ""
    for definition in ShortcutDefinitions()
        summary .= (summary = "" ? "" : "`n") ShortcutKeyLabel(keys[definition.Id]) "：" definition.Label "（" definition.Scope "）"
    return summary
}
