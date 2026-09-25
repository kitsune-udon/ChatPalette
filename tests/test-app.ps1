# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
$release = New-TestRuntime

foreach ($module in @('src\shortcuts\shortcut_policy.ahk','src\settings\settings_schema.ahk','src\settings\settings_store.ahk','src\settings\settings_repository.ahk','src\settings\reaction_registration_repository.ahk','src\settings\library_storage_plan.ahk','src\storage\sqlite_connection.ahk','src\browser\worker_client.ahk','src\library\danmaku_library.ahk','src\library\library_service.ahk','src\library\profile_service.ahk','src\settings\settings_service.ahk')) {
    $moduleText = [IO.File]::ReadAllText((Join-Path $release $module))
    $moduleText = [regex]::Replace($moduleText, '(?m)^\s*;.*$', '')
    if ($moduleText -match '\b(PaletteWindow|ManagementWindow|ManagementStatus|ManagedList|EditingProfileId|ActiveEditorDialog|RefreshLibraryViews|RefreshManagement|RefreshPalette|ToolTip|MsgBox|InputBox|Gui)\b') {
        throw "Boundary regression: $module depends on GUI"
    }
}
# Application Gui.Show calls belong only to the shared presenter (menus/viewport wrappers excluded).
foreach ($file in Get-ChildItem -LiteralPath $release -Filter '*.ahk' -Recurse -File) {
    if ($file.Name -eq 'window_presenter.ahk') { continue }
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -match '(?m)^\s*(?!menu\.|popup\.|(?:panel\.)?viewport\.)[\w.]+\.Show\(') {
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
    PaletteManageButton.OnEvent("Click",RecordPaletteClick,-1)
    PaletteManageButton.GetPos(&clickX,&clickY,&clickWidth,&clickHeight)
    clickReady := "enabled=" PaletteManageButton.Enabled " visible=" PaletteManageButton.Visible
        . " refreshing=" PaletteRefresh.Active " search_pending=" PaletteSearchPending
        . " bounds=" clickX "," clickY "," clickWidth "," clickHeight
    SendMessage(0xF5,0,0,PaletteManageButton.Hwnd) ; BM_CLICK keeps native button dispatch independent of pointer movement.
    deadline := A_TickCount+2000
    while !ManagementWindow && A_TickCount<deadline
        Sleep(10)
    if !ManagementWindow {
        policy := OperationPolicy("edit")
        FileAppend("Palette click diagnostic: " clickReady " events=" PaletteClickCount
            . " active=" (!!WinActive("ahk_id " PaletteWindow.Hwnd)) " edit_allowed=" policy.Allowed
            . " refreshing=" PaletteRefresh.Active " search_pending=" PaletteSearchPending "`n","*")
    }
    Assert(ManagementWindow && PaletteClickCount=1,"first palette click creates management exactly once")
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
    for control in ActiveEditorDialog.Window
        if control.Type="DDL"
            assignControl := control
    Assert(InStr(ControlGetItems(assignControl.Hwnd)[2],SharedDanmakuItems[1].Name),"slot labels identify current owner")
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    TransferItem()
    for control in ActiveEditorDialog.Window
        if control.Type="DDL"
            moveTarget := control
    Assert(ControlGetItems(moveTarget.Hwnd).Length=Profiles.Length,"shared move excludes source")
    editorHwnd := ActiveEditorDialog.Window.Hwnd
    WinClose("ahk_id " editorHwnd)
    Assert(WinWaitClose("ahk_id " editorHwnd,,2) && !ActiveEditorDialog,"editor finishes closing before the next operation")
    savedProfiles := Profiles
    Profiles := []
    TransferItem()
    noTargetEnabled := true
    for control in ActiveEditorDialog.Window
        if control.Type="Button" && control.Text="移動"
            noTargetEnabled := control.Enabled
    Assert(!noTargetEnabled,"move disabled with no destination")
    editorHwnd := ActiveEditorDialog.Window.Hwnd
    WinClose("ahk_id " editorHwnd)
    Assert(WinWaitClose("ahk_id " editorHwnd,,2) && !ActiveEditorDialog,"editor finishes closing before the next operation")
    Profiles := savedProfiles
    Help()
    helpHwnd := WinExist("使い方 ahk_pid " DllCall("GetCurrentProcessId"))
    Assert(!!helpHwnd,"task-oriented help opens")
    helpKeyButton := 0
    for control in GuiFromHwnd(helpHwnd)
        if control.Type="Button" && control.Text="ショートカットを管理…"
            helpKeyButton := control
    Assert(!!helpKeyButton,"help offers a direct route to the shortcut manager")
    global HelpKeyClicks := 0
    helpKeyButton.OnEvent("Click",RecordHelpKeyClick,-1)
    WinActivate("ahk_id " helpHwnd)
    helpActive := WinWaitActive("ahk_id " helpHwnd,,2)
    Assert(helpActive,"help is active before shortcut click: visible=" DllCall("IsWindowVisible","Ptr",helpHwnd)
        . " enabled=" DllCall("IsWindowEnabled","Ptr",helpHwnd) " owner_enabled=" DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)
        . " editor=" (ActiveEditorDialog ? ActiveEditorDialog.Label : "none") " foreground_is_app=" IsAppWindow(WinExist("A")))
    SendMessage(0xF5,0,0,helpKeyButton.Hwnd) ; BM_CLICK keeps native button dispatch independent of pointer movement.
    deadline := A_TickCount+2000
    while !ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    if !ActiveEditorDialog {
        policy := OperationPolicy("edit")
        FileAppend("Help click diagnostic: events=" HelpKeyClicks " enabled=" helpKeyButton.Enabled " visible=" helpKeyButton.Visible
            . " active=" (!!WinActive("ahk_id " helpHwnd)) " edit_allowed=" policy.Allowed " reason=" policy.Reason "`n","*")
    }
    Assert(ActiveEditorDialog && ActiveEditorDialog.Label="ショートカットの管理" && HelpKeyClicks=1,"help button opens the shared shortcut editor exactly once")
    WinClose("ahk_id " ActiveEditorDialog.Window.Hwnd)
    deadline := A_TickCount+2000
    while ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    Assert(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"closing shortcut editor from help releases ownership and restores parent")
    WinClose("ahk_id " helpHwnd)
    Assert(WinWaitClose("ahk_id " helpHwnd,,2),"help closes before management operations resume")
    ManagementWindow.Hide()


    ; The same policy controls the actual UI and the owning editor.
    ShowManagement(1)
    RefreshPaletteItems()
    RefreshOperationControls()
    Assert(PaletteInsert.Enabled && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"idle controls allow actions")
    ActiveReactionJob := CreateReactionJob({Mode:"queued"})
    RefreshOperationControls()
    Assert(!PaletteInsert.Enabled && !PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"reaction state disables the same actions as handlers")
    CancelReaction()
    Assert(PaletteInsert.Enabled && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"stopping restores action controls")
    IsBrowserOperationBusy := true
    RefreshOperationControls()
    Assert(!PaletteInsert.Enabled && !PaletteDefaults.Enabled && !ManagementItemButtons[1].Enabled,"worker state disables conflicting controls")
    IsBrowserOperationBusy := false
    RefreshOperationControls()
    ShowShortcutManager()
    Assert(!OperationAllowed("input") && OperationAllowed("preferences"),"editor state permits its own settings save")
    SaveReactionDefaults(CreateReactionOptions(2,10,25))
    Assert(DefaultReactionCount=10,"preferences save succeeds inside editor")
    editorHwnd := ActiveEditorDialog.Window.Hwnd
    WinClose("ahk_id " editorHwnd)
    Assert(WinWaitClose("ahk_id " editorHwnd,,2) && !ActiveEditorDialog,"editor finishes closing before the next operation")
    Assert(!ActiveEditorDialog && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"closing editor restores actions")
'@ -Helpers @'
RecordHelpKeyClick(*) {
    global HelpKeyClicks
    HelpKeyClicks++
}
RecordPaletteClick(*) {
    global PaletteClickCount
    PaletteClickCount++
}
'@
