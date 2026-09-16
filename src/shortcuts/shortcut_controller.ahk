; Shortcut policy shared by danmaku and reactions.


ShortcutBlocked() {
    if ActiveEditorDialog {
        ToolTip("「" ActiveEditorDialog.Label "」を閉じてから実行してください。")
        SetTimer(() => ToolTip(), -2500)
        return true
    }
    if !IsBrowserOperationBusy && !DanmakuEditorWindow && !ActiveReactionJob
        return false
    message := ActiveReactionJob ? "リアクション処理中です。Escで停止してから押してください。"
        : (IsBrowserOperationBusy ? "前の処理を確認中です。完了後にもう一度押してください。" : "編集中です。編集画面を閉じてください。")
    ToolTip(message)
    SetTimer(() => ToolTip(), -2500)
    return true
}


WaitShortcutRelease(keys) {
    for key in keys {
        if !KeyWait(key, "T2") {
            ToolTip("キーを離してから、もう一度押してください。")
            SetTimer(() => ToolTip(), -2500)
            return false
        }
    }
    return true
}


ReactionKeyLabel() {
    return (InStr(ReactionShortcut, "^") ? "Ctrl＋" : "")
        . (InStr(ReactionShortcut, "!") ? "Alt＋" : "")
        . (InStr(ReactionShortcut, "+") ? "Shift＋" : "")
        . StrUpper(RegExReplace(ReactionShortcut, "[!^+]", ""))
}

HandleProfileDanmakuShortcut(slot) {
    HandleDanmakuShortcut(false,slot)
}
HandleSharedDanmakuShortcut(slot) {
    HandleDanmakuShortcut(true,slot)
}
HandleDanmakuShortcut(shared,slot) {
    if ShortcutBlocked()
        return
    hwnd := WinExist("A")
    key := String(slot + (shared ? 2 : 0))
    if !IsBrowser(hwnd) || !WaitShortcutRelease([key,"Control","Alt"])
        return
    RequestDanmakuInput(shared,slot,hwnd,true)
}
