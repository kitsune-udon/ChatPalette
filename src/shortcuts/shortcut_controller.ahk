; Shortcut policy shared by danmaku and reactions.


ShortcutBlocked(action := "input") {
    policy := OperationPolicy(action)
    if policy.Allowed
        return false
    ToolTip(policy.Message)
    SetTimer(() => ToolTip(), -2500)
    return true
}

WaitShortcutRelease(keys) {
    return RuntimePorts.ShortcutRelease ? RuntimePorts.ShortcutRelease.Call(keys) : NativeWaitShortcutRelease(keys)
}

NativeWaitShortcutRelease(keys) {
    for key in keys {
        if !KeyWait(key, "T2") {
            ToolTip("キーを離してから、もう一度押してください。")
            SetTimer(() => ToolTip(), -2500)
            return false
        }
    }
    return true
}




HandleDanmakuShortcut(shared,slot) {
    if ShortcutBlocked()
        return
    hwnd := WinExist("A")
    key := RegExReplace(GetShortcutKey((shared ? "shared" : "profile") slot),"[!^+]","")
    if !IsBrowser(hwnd) || !WaitShortcutRelease([key,"Control","Alt","Shift"])
        return
    RequestShortcutInput(shared ? "shared" : "profile",slot,hwnd)
}

HandlePageShortcut(action, key) {
    if ShortcutBlocked("input")
        return
    hwnd := WinExist("A")
    if !IsBrowser(hwnd) || !WaitShortcutRelease([key,"Control","Alt","Shift"])
        return
    RunPageAction(action,hwnd)
}
RunPageAction(action, hwnd) {
    global LastBrowserOperation
    if !OperationAllowed("input") || !IsTargetForeground(hwnd)
        return false
    if action != "chat_focus" && action != "chat_clear" && action != "reactions_show"
        throw Error("不明なページ操作です。")
    started := A_TickCount, stage := action = "reactions_show" ? "表示操作" : "フォーカス"
    result := {State:"unknown"}
    try {
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
    } catch {
        result := {State:"unknown"}
    } finally {
        RecordBrowserOperation({Mode:action,State:result.State,Stage:stage,Window:hwnd,Duration:A_TickCount-started})
    }
    info := BrowserResultInfo(result.State)
    message := info.Summary (info.Advice != "" ? "。" info.Advice : "。")
    PaletteHint.Text := message
    ToolTip(message)
    SetTimer(() => ToolTip(),-3000)
    return result.State = "focused" || result.State = "cleared" || result.State = "hovered"
}

EffectiveShortcutSummary() {
    keys := CurrentShortcutMap(), summary := ""
    for definition in ShortcutDefinitions()
        summary .= (summary = "" ? "" : "`n") ShortcutKeyLabel(keys[definition.Id]) "：" definition.Label "（" definition.Scope "）"
    return summary
}
