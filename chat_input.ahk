; Delivery receives a resolved string and target, never list controls or profile selection.
DeliverText(text, hwnd, expectedVideo := "", activate := false) {
    if activate {
        WinActivate("ahk_id " hwnd)
        if !WinWaitActive("ahk_id " hwnd, , 2)
            return false
        KeyWait("Enter")
        KeyWait("LButton")
    }
    if !WinActive("ahk_id " hwnd)
        return false
    if !VerifyInputTarget(hwnd, expectedVideo)
        return false
    SendText(text)
    return true
}

InsertProfileDanmaku(n, hwnd, fromPanel := false) {
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob || ProfileManagerActive || n < 1
        return
    if !IsBrowser(hwnd) {
        PanelStatusText.Text := "入力先がありません。チャット欄をクリックし、Ctrl＋Alt＋Qで開き直してください。"
        return
    }
    profile := GetSelectedProfile()
    if AutoMode && !SelectProfileFromBrowser(hwnd)
        return
    if fromPanel && profile != GetSelectedProfile() {
        PanelStatusText.Text := "投稿者が変わりました。弾幕を選び直してください。"
        return
    }
    if !GetSelectedProfile()
        return
    items := GetDanmakuItems(false, GetSelectedProfile())
    if n > items.Length
        return
    text := items[n].Text
    video := AutoMode ? DetectedChannel.Video : ""
    if fromPanel
        MainWindow.Hide()
    if !DeliverText(text, hwnd, video, fromPanel)
        ShowInputFailure()
}


HandleSharedDanmakuShortcut(n) {
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob || ProfileManagerActive
        return
    hwnd := WinExist("A")
    if !IsBrowser(hwnd) || !WaitShortcutRelease([String(n + 2), "Control", "Alt"])
        return
    InsertSharedDanmaku(n, hwnd)
}

InsertSharedDanmaku(n, hwnd, fromPanel := false) {
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob || ProfileManagerActive || n < 1 || n > SharedDanmakuItems.Length
        return
    if !IsBrowser(hwnd) {
        PanelStatusText.Text := "YouTubeのチャット欄またはコメント欄をクリックしてCtrl＋Alt＋Qで開き直してください。"
        return
    }
    text := SharedDanmakuItems[n].Text
    context := RequestBrowserOperation(hwnd, "reaction_context")
    if context.State != "ok" {
        ToolTip("YouTubeの動画を確認できません。チャット欄をクリックして再試行してください。")
        SetTimer(() => ToolTip(), -2500)
        return
    }
    if fromPanel
        MainWindow.Hide()
    if !DeliverText(text, hwnd, context.Video, fromPanel)
        ShowInputFailure()
}
