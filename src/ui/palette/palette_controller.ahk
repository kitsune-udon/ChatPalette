; Palette orchestration and detected profile selection.
ShowPalette(*) {
    global TargetBrowserHwnd
    if DanmakuEditorWindow {
        PresentWindow(DanmakuEditorWindow)
        return
    }
    if RestoreActiveEditorDialog()
        return
    if ActiveReactionJob {
        ShowReactionProgress()
        return
    }
    if IsBrowserOperationBusy
        return
    active := WinExist("A")
    if IsBrowser(active)
        TargetBrowserHwnd := active
    else if !IsAppWindow(active)
        TargetBrowserHwnd := 0
    if AutoMode && TargetBrowserHwnd && !ActiveReactionJob
        SelectProfileFromBrowser(TargetBrowserHwnd)
    RefreshPalette()
    ShowFittedWindow(PaletteWindow, 560, 740, ResizePalette)
}

HidePalette(*) {
    PaletteWindow.Hide()
}

SelectProfileFromBrowser(hwnd) {
    global DetectedChannel
    DetectedChannel := ResolveBrowserChannel(hwnd)
    if DetectedChannel.State != "ok" {
        SetDetectionStatus("動画を確認できません。YouTubeの入力欄から開き直してください。")
        return false
    }
    found := ChannelIndex.Get(DetectedChannel.Channel, 0)
    if found <= 0 {
        SetDetectionStatus(found = -1 ? "チャンネル連携が重複しています。管理画面で確認してください。" : "チャンネル未連携：" DetectedChannel.Author "。「チャンネル連携」から登録できます。")
        return false
    }
    try SaveInputProfileSelection(found)
    catch as failure {
        SetDetectionStatus("配信者を選択できませんでした。" failure.Message)
        return false
    }
    SetDetectionStatus("自動：" DetectedChannel.Author " → " Profiles[found].Name)
    return true
}

UpdateTray() {
    A_IconTip := "ChatPalette：" (GetInputProfile() ? GetInputProfile().Name : "配信者未選択")
}

RefreshProfiles() {
    RefreshPalette()
    RefreshManagement()
}
