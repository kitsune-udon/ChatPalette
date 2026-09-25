# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
$release = New-TestRuntime

foreach ($module in @('src\shortcuts\shortcut_policy.ahk','src\settings\settings_schema.ahk','src\settings\settings_store.ahk','src\settings\settings_repository.ahk','src\settings\reaction_registration_repository.ahk','src\settings\library_storage_plan.ahk','src\settings\legacy_settings_import.ahk','src\storage\sqlite_connection.ahk','src\browser\worker_client.ahk','src\library\danmaku_library.ahk','src\library\library_service.ahk','src\library\profile_service.ahk','src\settings\settings_service.ahk')) {
    $moduleText = [IO.File]::ReadAllText((Join-Path $release $module))
    $moduleText = [regex]::Replace($moduleText, '(?m)^\s*;.*$', '')
    if ($moduleText -match '\b(PaletteWindow|ManagementWindow|ManagementStatus|ManagedList|EditingProfileId|ActiveEditorDialog|DanmakuEditorWindow|RefreshProfiles|RefreshManagement|RefreshPalette|ToolTip|MsgBox|InputBox|Gui)\b') {
        throw "Boundary regression: $module depends on GUI"
    }
}
# Application Gui.Show calls belong only to the shared presenter (menus/viewport wrappers excluded).
foreach ($file in Get-ChildItem -LiteralPath $release -Filter '*.ahk' -Recurse -File) {
    if ($file.Name -eq 'window_presenter.ahk') { continue }
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -match '(?m)^\s*(?!menu\.|popup\.|panel\.Viewport\.)[\w.]+\.Show\(') {
        throw "Presentation boundary regression: $($file.Name) directly shows a Gui"
    }
}
Invoke-AppFixture -Runtime $release -Body @'
    Assert(!ManagementWindow,"management is lazy before first palette action")
    ShowPalette()
    PaletteSettingsStatus.GetPos(,&settingsY)
    PaletteStatusControl.GetPos(,&reactionY)
    Assert(settingsY!=reactionY,"first palette frame separates notification rows")
    WinActivate("ahk_id " PaletteWindow.Hwnd)
    Assert(WinWaitActive("ahk_id " PaletteWindow.Hwnd,,2),"palette active before first click")
    global PaletteClickCount := 0
    PaletteManageButton.OnEvent("Click",RecordPaletteClick)
    PaletteManageButton.GetPos(&clickX,&clickY,&clickWidth,&clickHeight)
    clickReady := "enabled=" PaletteManageButton.Enabled " visible=" PaletteManageButton.Visible
        . " refreshing=" PaletteRefresh.Active " search_pending=" PaletteSearchPending
        . " bounds=" clickX "," clickY "," clickWidth "," clickHeight
    ControlClick(PaletteManageButton.Hwnd)
    deadline := A_TickCount+2000
    while !ManagementWindow && A_TickCount<deadline
        Sleep(10)
    if !ManagementWindow {
        policy := OperationPolicy("edit")
        FileAppend("Palette click diagnostic: " clickReady " events=" PaletteClickCount
            . " active=" (!!WinActive("ahk_id " PaletteWindow.Hwnd)) " edit_allowed=" policy.Allowed
            . " refreshing=" PaletteRefresh.Active " search_pending=" PaletteSearchPending "`n","*")
    }
    Assert(!!ManagementWindow,"first palette click creates management")
    Assert(WinWaitActive("ahk_id " ManagementWindow.Hwnd,,2),"first palette click opens management")
    coldControls := [ManagementTitle,ManagementTarget,ManagementAddProfileButton,ManagementProfileMenu,ManagedList,ManagementUndo,ManagementScopeHint]
    initialRects := []
    for control in coldControls {
        control.GetPos(&x,&y,&w,&h)
        initialRects.Push({X:x,Y:y,W:w,H:h})
    }
    Assert(initialRects[1].Y=48 && initialRects[2].Y=76 && initialRects[3].Y=112,"initial layout already has final coordinates")
    ManagementWindow.Hide()
    ShowManagement(1)
    for i,control in coldControls {
        control.GetPos(&x,&y,&w,&h)
        rect := initialRects[i]
        Assert(x=rect.X && y=rect.Y && w=rect.W && h=rect.H,"initial layout equals reopened layout " i " first=" rect.X "," rect.Y "," rect.W "," rect.H " now=" x "," y "," w "," h)
    }
    ManagementWindow.Hide()

    ; Cross-screen UX contracts: returning does not silently reset session options.
    PaletteCount.Choose(2)
    returnCount := PaletteCount.Value
    ReturnToPalette()
    Assert(DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd),"back returns to palette")
    Assert(PaletteCount.Value=returnCount,"back preserves session options")
    ShowManagement(2)
    LoadDefaultsAndReturn()
    Assert(ReactionCounts[PaletteCount.Value]=DefaultReactionCount,"explicit load applies defaults")
    TargetBrowserHwnd := 0
    RefreshReactionRegistration()
    Assert(InStr(ReactionRegistrationLabel.Text,"未選択"),"registration state distinguishes missing browser")
    ShowManagement(1)
    EditingProfileId := ""
    RefreshManagement()
    OpenDanmakuEditor(true)
    for control in DanmakuEditorWindow
        if control.Type="DDL"
            assignControl := control
    Assert(InStr(ControlGetItems(assignControl.Hwnd)[2],SharedDanmakuItems[1].Name),"slot labels identify current owner")
    CloseDanmakuEditor()
    TransferItem()
    for control in ActiveEditorDialog.Window
        if control.Type="DDL"
            moveTarget := control
    Assert(ControlGetItems(moveTarget.Hwnd).Length=Profiles.Length,"shared move excludes source")
    WinClose("ahk_id " ActiveEditorDialog.Window.Hwnd)
    Sleep(30)
    savedProfiles := Profiles
    Profiles := []
    TransferItem()
    noTargetEnabled := true
    for control in ActiveEditorDialog.Window
        if control.Type="Button" && control.Text="移動"
            noTargetEnabled := control.Enabled
    Assert(!noTargetEnabled,"move disabled with no destination")
    WinClose("ahk_id " ActiveEditorDialog.Window.Hwnd)
    Sleep(30)
    Profiles := savedProfiles
    Help()
    helpHwnd := WinExist("使い方 ahk_pid " DllCall("GetCurrentProcessId"))
    Assert(!!helpHwnd,"task-oriented help opens")
    WinClose("ahk_id " helpHwnd)
    Sleep(30)
    ManagementWindow.Hide()


'@ -Helpers @'
RecordPaletteClick(*) {
    global PaletteClickCount
    PaletteClickCount++
}
'@
