; Palette orchestration and detected profile selection.
ShowPalette(*) {
    global TargetBrowserHwnd
    if RestoreActiveEditorDialog()
        return
    if ActiveReactionJob {
        ShowReactionProgress()
        return
    }
    if CurrentOperationState().BrowserBusy
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
    try DetectedChannel := ResolveBrowserChannel(hwnd)
    catch as failure
        DetectedChannel := {State:"unavailable",Channel:"",Author:"",Video:"",Detail:failure.Message}
    if DetectedChannel.State != "ok" {
        message := "動画を確認できません。YouTubeの入力欄から開き直してください。"
        if DetectedChannel.HasOwnProp("Detail") && DetectedChannel.Detail != ""
            message .= " " DetectedChannel.Detail
        SetDetectionStatus(message)
        return false
    }
    profile := FindProfileByChannel(Profiles,DetectedChannel.Channel)
    if !profile {
        SetDetectionStatus("チャンネル未連携：" DetectedChannel.Author "。「チャンネル連携」から登録できます。")
        return false
    }
    try SaveInputProfileId(profile.Id)
    catch as failure {
        SetDetectionStatus("配信者を選択できませんでした。" failure.Message)
        return false
    }
    SetDetectionStatus("自動：" DetectedChannel.Author " → " profile.Name)
    return true
}

UpdateTray() {
    profile := GetInputProfile()
    A_IconTip := "ChatPalette：" (profile ? profile.Name : "配信者未選択")
}

; A failed view must not prevent the other from reflecting committed state.
RefreshLibraryViews(updateManagement := 0) {
    errors := ""
    try RefreshVisiblePalette()
    catch as failure
        errors := "パレット：" failure.Message
    try RefreshManagement(updateManagement)
    catch as failure
        errors .= (errors = "" ? "" : "`n") "管理画面：" failure.Message
    if errors != ""
        throw Error(errors)
}

; Hidden palettes are refreshed unconditionally by ShowPalette/ReturnToPalette.
RefreshVisiblePalette() {
    if DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd)
        RefreshPalette()
    else
        UpdateTray()
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
    target := GetPaletteLibraryTarget()
    EditingProfileId := target.ProfileId
    ShowManagement(1)
    if target.Index
        SelectManagedRow(target.Index)
}

GetPaletteLibraryTarget() {
    profile := GetPaletteInputProfile(), row := GetSelectedPaletteRow()
    if row {
        shared := row.ProfileId = ""
        if shared || (profile && row.ProfileId == profile.Id) {
            items := shared ? SharedDanmakuItems : profile.Items
            if PaletteItemMatches(row,items)
                return {ProfileId:row.ProfileId, Index:row.Index}
        }
    }
    return {ProfileId:profile ? profile.Id : "", Index:0}
}

; Resolve the valid owner once for presentation or editing; manual selection survives window loss.
GetPaletteInputProfile() {
    profile := GetInputProfile()
    if profile && (!AutoMode || (IsBrowser(TargetBrowserHwnd)
        && DetectedChannel.State = "ok" && profile.Channel != "" && profile.Channel == DetectedChannel.Channel))
        return profile
    return 0
}
