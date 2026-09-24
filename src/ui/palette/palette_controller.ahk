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
    RefreshPaletteForTarget()
    ShowFittedWindow(PaletteWindow, 560, 740, ResizePalette)
}

; Opening and returning both resolve the current input target, independently of editing.
RefreshPaletteForTarget() {
    global DetectedChannel
    if AutoMode {
        if !IsBrowser(TargetBrowserHwnd) {
            DetectedChannel := {State:"unavailable", Channel:"", Author:"", Video:""}
            SetDetectionStatus("YouTubeの入力欄からパレットを開いてください。")
        } else if !ActiveReactionJob
            SelectProfileFromBrowser(TargetBrowserHwnd)
    }
    RefreshPalette()
}

HidePalette(*) {
    CancelScheduledPaletteSearch()
    PaletteWindow.Hide()
}

SelectProfileFromBrowser(hwnd) {
    global DetectedChannel
    DetectedChannel := ResolveBrowserChannel(hwnd)
    if DetectedChannel.State != "ok" {
        SetDetectionStatus("動画を確認できません。YouTubeの入力欄から開き直してください。")
        return false
    }
    found := ChannelIndex.Get(DetectedChannel.Channel, "")
    if found = "" {
        SetDetectionStatus(ChannelIndex.Has(DetectedChannel.Channel) ? "チャンネル連携が重複しています。管理画面で確認してください。" : "チャンネル未連携：" DetectedChannel.Author "。「チャンネル連携」から登録できます。")
        return false
    }
    try SaveInputProfileId(found)
    catch as failure {
        SetDetectionStatus("配信者を選択できませんでした。" failure.Message)
        return false
    }
    SetDetectionStatus("自動：" DetectedChannel.Author " → " FindProfileById(Profiles,found).Name)
    return true
}

UpdateTray() {
    profile := GetInputProfile()
    A_IconTip := "ChatPalette：" (profile ? profile.Name : "配信者未選択")
}

RefreshProfiles() {
    RefreshVisiblePalette()
    if ManagementWindow && DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd)
        RefreshManagement()
}

; Hidden palettes are refreshed unconditionally by ShowPalette/ReturnToPalette.
RefreshVisiblePalette() {
    UpdateTray()
    if DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd)
        RefreshPalette()
}

; Editing starts from the selected palette item, without changing the input profile.
OpenPaletteLibrary(*) {
    if PaletteRefresh.Active
        return
    if FlushPendingPaletteSearch()
        return
    global EditingProfileId
    if RestoreActiveEditorDialog() || !OperationAllowed("edit")
        return
    if DanmakuEditorWindow {
        PresentWindow(DanmakuEditorWindow)
        return
    }
    target := GetPaletteLibraryTarget()
    EditingProfileId := target.ProfileId
    ShowManagement(1)
    if target.Index
        SelectManagedRow(target.Index)
}

GetPaletteLibraryTarget() {
    selected := PaletteList.GetNext()
    if selected && selected <= PaletteRows.Length {
        row := PaletteRows[selected]
        index := row.Shared ? 0 : FindProfileIndexById(Profiles,row.ProfileId)
        if row.Shared || (index && HasPaletteInputProfile() && row.ProfileId = InputProfileId) {
            items := row.Shared ? SharedDanmakuItems : Profiles[index].Items
            if PaletteItemMatches(row,items)
                return {ProfileId:row.Shared ? "" : row.ProfileId, Index:row.Index}
        }
    }
    profile := GetInputProfile()
    matched := HasPaletteInputProfile()
    return {ProfileId:matched ? profile.Id : "", Index:0}
}

; Display and editing use the same validity rule; manual selection survives window loss.
HasPaletteInputProfile() {
    return !!GetInputProfile() && (!AutoMode || (IsBrowser(TargetBrowserHwnd)
        && DetectedChannel.State = "ok" && ChannelIndex.Get(DetectedChannel.Channel,"") = InputProfileId))
}
