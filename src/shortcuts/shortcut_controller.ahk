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


ReactionKeyLabel(key := "") {
    return ShortcutKeyLabel(key != "" ? key : ReactionShortcut)
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
        LastBrowserOperation := {Mode:action,State:result.State,Stage:stage,Window:hwnd,Duration:A_TickCount-started}
    }
    messages := Map("focused","チャット入力欄へ移動しました。",
        "cleared","チャット入力欄をクリアしました。",
        "hovered","リアクション表示用のUIへマウスを移動しました。",
        "wrong_input","チャット入力欄を一意に確認できません。チャットを表示してやり直してください。",
        "unsupported","リアクション表示用のUIを確認できません。YouTubeの♡にマウスを重ねてください。",
        "changed","動画が変わったため中止しました。",
        "wrong_window","操作先が変わったため中止しました。",
        "unknown","操作結果を確認できませんでした。自動では再実行しません。")
    message := messages.Get(result.State,"操作できませんでした。YouTubeの動画ページを最前面にしてやり直してください。")
    PaletteHint.Text := message
    ToolTip(message)
    SetTimer(() => ToolTip(),-3000)
    return result.State = "focused" || result.State = "cleared" || result.State = "hovered"
}

EffectiveShortcutSummary(reactionKey := "") {
    keys := CurrentShortcutMap(), summary := ""
    if reactionKey != ""
        keys["reaction"] := reactionKey
    for definition in ShortcutDefinitions()
        summary .= (summary = "" ? "" : "`n") ShortcutKeyLabel(keys[definition.Id]) "：" definition.Label "（" definition.Scope "）"
    return summary
}
