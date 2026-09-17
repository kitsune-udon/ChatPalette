$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

foreach ($module in @('src\shortcuts\shortcut_policy.ahk','src\settings\settings_schema.ahk','src\settings\settings_store.ahk','src\settings\settings_repository.ahk','src\settings\reaction_registration_repository.ahk','src\settings\library_storage_plan.ahk','src\settings\library_storage_delta.ahk','src\settings\legacy_settings_import.ahk','src\storage\sqlite_connection.ahk','src\browser\worker_client.ahk','src\library\danmaku_library.ahk','src\library\library_service.ahk','src\library\profile_service.ahk','src\settings\settings_service.ahk')) {
    $moduleText = [IO.File]::ReadAllText((Join-Path $release $module))
    $moduleText = [regex]::Replace($moduleText, '(?m)^\s*;.*$', '')
    if ($moduleText -match '\b(PaletteWindow|ManagementWindow|ManagementStatus|ManagedList|EditProfileIndex|EditScopeShared|ActiveEditorDialog|DanmakuEditorWindow|RefreshProfiles|RefreshManagement|RefreshPalette|ToolTip|MsgBox|InputBox|Gui)\b') {
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
$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$bindingSource = [IO.File]::ReadAllText("$fixture\src\shortcuts\shortcut_bindings.ahk").Replace('SetReactionHotkey(key, enabled := true) {', 'RegisterFixtureHotkey(key, enabled := true) {')
[IO.File]::WriteAllText("$fixture\src\shortcuts\shortcut_bindings.ahk", $bindingSource, [Text.UTF8Encoding]::new($true))
$shortcutSource = [IO.File]::ReadAllText("$fixture\src\shortcuts\shortcut_controller.ahk").Replace('WaitShortcutRelease(keys) {', 'WaitFixtureShortcutRelease(keys) {')
[IO.File]::WriteAllText("$fixture\src\shortcuts\shortcut_controller.ahk", $shortcutSource, [Text.UTF8Encoding]::new($true))
$reactionSource = [IO.File]::ReadAllText("$fixture\src\reactions\reaction_controller.ahk")
$reactionSource = $reactionSource.Replace('WinActive("ahk_id " job.Window)', 'FixtureReactionWindowActive(job.Window)').Replace('job.StartedAt := ReactionClockMs()', 'job.StartedAt := ReactionClockMs()' + "`r`n            FixtureStarts.Push(job.StartedAt)")
[IO.File]::WriteAllText("$fixture\src\reactions\reaction_controller.ahk", $reactionSource, [Text.UTF8Encoding]::new($true))
New-Item -ItemType Directory -Path "$fixture\data" -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\settings.ini') -Destination "$fixture\data\settings.ini" -Force
$worker = [IO.File]::ReadAllText("$release\src\browser\browser_worker.ps1")
$worker = $worker.Replace('function Invoke-WorkerRequest($Request) {', 'function Invoke-FixtureBaseRequest($Request) {')
$mock = @'
function Invoke-WorkerRequest($Request) {
    if ($Request.Mode -eq 'fixture_native') {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$Request.Element)
        $record = Get-ReactionRecord $element
        $valid = (Test-ElementWindow $element ([long]$Request.Parent)) -and !(Test-ElementWindow $element ([long]$Request.Other)) -and ($record.Enabled -eq ($Request.Enabled -eq '1'))
        return @{Seq=$Request.Seq;Window=$Request.Window;State=$(if($valid){'ok'}else{'failed'})}
    }
    if ($Request.FixtureExit -eq '1') { exit 1 }
    if ($Request.FixtureDelay) { Start-Sleep -Milliseconds ([int]$Request.FixtureDelay) }
    return Invoke-FixtureBaseRequest $Request
}
function Read-BrowserVideoId([long]$WindowHandle) { return 'abcdefghijk' }
function Get-BrowserProcessName([long]$WindowHandle) { return 'fixture' }
function Test-ReactionForeground([long]$WindowHandle) { return $true }
$script:fakeTarget = [pscustomobject]@{ Current=[pscustomobject]@{IsOffscreen=$false; IsEnabled=$true} }
$script:fakeInvoke = [pscustomobject]@{}
$script:fakeInvoke | Add-Member ScriptMethod Invoke { }
function Get-ReactionInvoker($Target) { return $script:fakeInvoke }
function Find-RegisteredReactions([long]$WindowHandle, $Saved) { return @{ Elements=@($script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget) } }
'@
$worker = $worker.Replace('if ($Library) { return }', $mock + "`n" + 'if ($Library) { return }')
[IO.File]::WriteAllText("$fixture\src\browser\browser_worker.ps1", $worker, [Text.UTF8Encoding]::new($true))
$source = [IO.File]::ReadAllText("$release\main.ahk").Replace("`r`n", "`n")
if ($source -notmatch '(?s)#HotIf IsBrowser\(WinExist\("A"\)\)\s+\^!1::HandleProfileDanmakuShortcut\(1\)\s+\^!2::HandleProfileDanmakuShortcut\(2\)\s+\^!3::HandleSharedDanmakuShortcut\(1\)\s+\^!4::HandleSharedDanmakuShortcut\(2\)\s+#HotIf\s+\^!q::ShowPalette\(\)') {
    throw 'Shortcut scope regression: text keys must be browser-only and panel key global'
}
$browserSource = [IO.File]::ReadAllText("$fixture\src\browser\browser_service.ahk")
$browserSource = [regex]::Replace($browserSource, '(?ms)^IsBrowser\(hwnd\) \{.*?^\}', "IsBrowser(hwnd) {`r`nreturn hwnd = 123`r`n}")
$browserSource = $browserSource.Replace('ResolveBrowserChannel(hwnd) {','ResolveFixtureBrowserChannel(hwnd) {').Replace('VerifyInputTarget(hwnd, expectedVideo) {','VerifyFixtureInputTarget(hwnd, expectedVideo) {')
[IO.File]::WriteAllText("$fixture\src\browser\browser_service.ahk", $browserSource, [Text.UTF8Encoding]::new($true))
$delivery = [IO.File]::ReadAllText("$fixture\src\input\text_input.ahk").Replace('WinActive("ahk_id " hwnd)','FixtureInputWindowActive(hwnd)').Replace('SendText(text)','CaptureFixtureInput(text)')
[IO.File]::WriteAllText("$fixture\src\input\text_input.ahk", $delivery, [Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global Checks := 0
try {
    Assert(!ManagementWindow,"management is lazy before first palette action")
    ShowPalette()
    PaletteSettingsStatus.GetPos(,&settingsY)
    PaletteStatusControl.GetPos(,&reactionY)
    Assert(settingsY!=reactionY,"first palette frame separates notification rows")
    WinActivate("ahk_id " PaletteWindow.Hwnd)
    Assert(WinWaitActive("ahk_id " PaletteWindow.Hwnd,,2),"palette active before first click")
    ControlClick(PaletteManageButton.Hwnd)
    deadline := A_TickCount+2000
    while !ManagementWindow && A_TickCount<deadline
        Sleep(10)
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
    EditScopeShared := true, EditProfileIndex := 0
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

    ; Changing captions must not change the identity of layout targets.
    renamedControls := [ManagementAddProfileButton,ManagementScopeHint,PaletteManageButton,PaletteReactionHeading,PaletteIntervalHint]
    for control in ManagementItemButtons
        renamedControls.Push(control)
    for key,control in ManagementSupportButtons
        renamedControls.Push(control)
    savedCaptions := []
    for control in renamedControls {
        savedCaptions.Push(control.Text)
        control.Text := "renamed caption"
    }
    LayoutManagement(ManagementWindow,0,460,620)
    LayoutPalette(PaletteWindow,0,460,620)
    ManagementAddProfileButton.GetPos(&x,&y,&w)
    Assert(x=28 && y=112 && w=198,"profile button layout independent of caption")
    ManagementSupportButtons["diagnostics"].GetPos(&x,&y,&w)
    Assert(x=40 && y=418 && w=380,"support button layout independent of caption")
    PaletteManageButton.GetPos(&x,&y,&w)
    Assert(x=234 && y=280 && w=210,"palette button layout independent of caption")
    for i,control in renamedControls
        control.Text := savedCaptions[i]
    LayoutManagement(ManagementWindow,0,760,660)
    LayoutPalette(PaletteWindow,0,560,660)
    for testWidth in [360,400,420,560] {
        LayoutPalette(PaletteWindow,0,testWidth,660)
        PaletteMode.GetPos(&mx,,&mw)
        PaletteProfile.GetPos(&px,,&pw)
        PaletteBind.GetPos(&bx,,&bw)
        Assert(mx+mw <= px && px+pw <= bx && bx+bw <= testWidth-16,"palette selectors do not overlap " testWidth)
    }
    LayoutManagement(ManagementWindow,0,360,520)
    KeyLabel.GetPos(,,&narrowWidth)
    LayoutManagement(ManagementWindow,0,760,660)
    KeyLabel.GetPos(,,&wideWidth)
    Assert(narrowWidth=292 && wideWidth=692,"management text expands again after narrowing")
    ManagementWindow.Show()
    TargetBrowserHwnd := 0
    PrepareReaction("reaction_check")
    Assert(DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd) && !ActiveReactionJob,"failed check retains management window")
    Assert(ManagementStatus.Text="通知：" ReactionExecutionStatus.Message && ManagementStatus.Text!="","failed check explains reason in management")
    PrepareReaction("reaction_capture")
    Assert(DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd) && !ActiveReactionJob,"failed registration retains management window")
    ManagementWindow.Hide()
    LayoutPalette(PaletteWindow,0,560,660)
    ; Link chooser uses the detected channel, and creation+binding is one undo step.
    FixtureInputMode := true, FixtureResolveCount := 0, FixtureCurrentVideo := "aaaaaaaaaaa"
    TargetBrowserHwnd := 123
    historyBeforeLink := LibraryHistory.Length
    profilesBeforeLink := Profiles.Length
    OpenChannelLinkDialog()
    linkDialog := ActiveEditorDialog.Window
    WinActivate("ahk_id " linkDialog.Hwnd)
    Assert(WinWaitActive("ahk_id " linkDialog.Hwnd,,2),"link chooser active")
    for control in linkDialog
        if control.Type="Button" && control.Text="連携する"
            linkSave := control
    ControlClick(linkSave.Hwnd)
    deadline := A_TickCount+2000
    while ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    Assert(!ActiveEditorDialog && Profiles.Length=profilesBeforeLink+1,"link dialog creates new profile")
    Assert(Profiles[-1].Channel="/channel/a" && LibraryHistory.Length=historyBeforeLink+1,"creation and linking commit once")
    Assert(FixtureResolveCount=2,"link rechecks channel before commit")
    UndoLibraryChange()
    Assert(Profiles.Length=profilesBeforeLink && !ChannelIndex.Has("/channel/a"),"one undo removes created linked profile")
    FixtureInputMode := false
    TargetBrowserHwnd := 0
    ManagementWindow.Hide()
    noticeControls := [PaletteHint,PaletteSettingsStatus,PaletteStatusControl]
    for label in PaletteOptionLabels
        noticeControls.Push(label)
    for size in [[360,620],[560,740]] {
        LayoutPalette(PaletteWindow,0,size[1],size[2])
        for control in noticeControls {
            control.GetPos(&x,&y,&w,&h)
            Assert(x>=0 && x+w<=size[1] && y>=0 && y+h<=size[2],"new notice and labels fit palette")
        }
    }
    PaletteInterval.Choose(1)
    RefreshPaletteIntervalHint()
    Assert(InStr(PaletteIntervalHint.Text,"前の操作"),"no wait explains serial execution")
    ResetPaletteSession()
    PaletteHint.Text := "input notification fixture"
    PaletteSettingsStatus.Text := "settings notification fixture"
    SetReactionStatus("reaction notification fixture",true)
    ShowReactionProgress()
    Assert(!ReactionOverlayStop.Visible && !ReactionOverlayStop.Enabled,"finished reaction has no stop action")
    Assert(PaletteHint.Text="input notification fixture" && PaletteSettingsStatus.Text="settings notification fixture","reaction result does not overwrite input or settings notices")
    ReactionOverlay.Hide()
    for testWidth in [360,460,760] {
        LayoutManagement(ManagementWindow,0,testWidth,660)
        for key,control in ManagementSupportButtons {
            control.GetPos(&x,&y,&w,&h)
            Assert(x>=40 && x+w<=testWidth-40 && h>=36,"support button within grouped content " key)
        }
        ManagementSupportButtons["register"].GetPos(&rx,&ry,&rw,&rh)
        ManagementSupportButtons["check"].GetPos(&cx,&cy,&cw,&ch)
        Assert(rx+rw+8<=cx && ry=cy,"setup steps remain separated")
    }
    LayoutManagement(ManagementWindow,0,760,660)
    EditScopeShared := true
    RefreshManagement()
    Assert(!ManagementProfileMenu.Enabled,"shared library has no profile settings action")
    ManagedList.Modify(0,"-Select")
    UpdateManagementActions()
    Assert(ManagementItemButtons[1].Enabled && !ManagementItemButtons[2].Enabled && !ManagementItemButtons[7].Enabled,"selection dependent actions are disabled")
    if ManagedList.GetCount() {
        SelectManagedRow(1)
        UpdateManagementActions()
        Assert(ManagementItemButtons[2].Enabled && !ManagementItemButtons[5].Enabled,"first row can edit but cannot move up")
    }
    layoutProbe := Gui(,"Layout probe")
    observedHidden := false
    ShowFittedWindow(layoutProbe,400,300,(view,state,w,h) => ObserveHiddenLayout(view,w,h))
    Assert(observedHidden,"layout is completed while window is hidden")
    layoutProbe.Destroy()
    anchor := Gui(,"Presentation test anchor")
    anchor.AddText(,"anchor")
    PresentWindow(anchor,"w240 h100")
    Assert(WinWaitActive("ahk_id " anchor.Hwnd,,2),"normal presentation activates")
    presentationProbe := Gui(,"Presentation test view")
    presentationProbe.AddText(,"prepared")
    global PresentationStates := []
    PresentWindow(presentationProbe,"w260 h120",ObservePresentation,false)
    Assert(!PresentationStates[1] && WinActive("ahk_id " anchor.Hwnd),"hidden layout completes without stealing focus")
    PresentWindow(presentationProbe,"w280 h140",ObservePresentation,false)
    Assert(PresentationStates[2] && WinActive("ahk_id " anchor.Hwnd),"visible update stays visible and does not steal focus")
    presentationProbe.Hide()
    PresentWindow(presentationProbe,"",ObservePresentation)
    Assert(!PresentationStates[3] && WinWaitActive("ahk_id " presentationProbe.Hwnd,,2),"reopening prepares while hidden and then activates")
    presentationProbe.Destroy()
    failedView := Gui(,"Failed layout test")
    failedView.AddText(,"must stay hidden")
    layoutFailed := false
    try PresentWindow(failedView,"",FailPresentation)
    catch
        layoutFailed := true
    Assert(layoutFailed && !DllCall("IsWindowVisible","Ptr",failedView.Hwnd),"failed preparation never exposes a partial window")
    failedView.Destroy()
    viewportView := Gui(,"Viewport preparation test")
    viewportView.AddText("x10 y10 w400 h24","scroll content")
    viewport := PanelViewport(viewportView,640,686)
    PresentWindow(viewportView,"w320 h240",(*) => PrepareViewportFixture(viewport),false)
    Assert(viewport.MaxX>0 && viewport.MaxY>0,"scroll ranges prepared before viewport is shown")
    viewportView.Hide()
    anchor.Destroy()

    originalIniPath := A_ScriptDir "\existing-format.ini"
    FileAppend("[General]`nSchema=3`nCount=0`nReactionDefault=4`nReactionCount=100`nReactionInterval=25`n",originalIniPath,"UTF-16")
    existing := ReadLegacySettings(originalIniPath)
    Assert(existing.DefaultReactionKind=4 && existing.DefaultReactionCount=100 && existing.DefaultReactionIntervalMs=25,"existing INI names keep settings")
    SetReactionStatus("reaction result fixture",true)
    PaletteStatusControl.Text := "unrelated input notice"
    ShowReactionProgress()
    Assert(InStr(ReactionOverlayText.Text,"reaction result fixture") && !InStr(ReactionOverlayText.Text,"unrelated input notice"),"overlay reads reaction state instead of generic palette notice")
    Assert(InStr(ReactionProgressHint(),"4秒"),"progress derives final state from controller")
    ReactionOverlay.Hide()
    ; Exercise the actual Save callback on this test application's own windows.
    ManagementWindow.Show()
    WinActivate("ahk_id " ManagementWindow.Hwnd)
    WinWaitActive("ahk_id " ManagementWindow.Hwnd,,2)
    EditScopeShared := true
    RefreshManagement()
    EditReactionKey()
    keyDialog := ActiveEditorDialog.Window
    otherWindow := Gui(,"Focus test")
    otherWindow.Show("w200 h100")
    WinActivate("ahk_id " otherWindow.Hwnd)
    ShowPalette()
    Assert(WinWaitActive("ahk_id " keyDialog.Hwnd,,2),"palette shortcut recalls key editor")
    WinClose("ahk_id " keyDialog.Hwnd)
    Sleep(50)
    Assert(!ActiveEditorDialog,"key editor closes normally after recall")
    otherWindow.Destroy()
    beforeFocusSave := SharedDanmakuItems.Length
    OpenDanmakuEditor(true)
    WinActivate("ahk_id " DanmakuEditorWindow.Hwnd)
    WinWaitActive("ahk_id " DanmakuEditorWindow.Hwnd,,2)
    Assert(WinActive("ahk_id " DanmakuEditorWindow.Hwnd),"editor activated before save")
    editNumber := 0
    for control in DanmakuEditorWindow {
        if control.Type = "Edit" {
            editNumber++
            control.Value := editNumber=1 ? "focus regression" : "fixture text"
        }
        if control.Type = "Button" && control.Text = "保存"
            saveButton := control
    }
    ControlClick(saveButton.Hwnd)
    deadline := A_TickCount+2000
    while DanmakuEditorWindow && A_TickCount < deadline
        Sleep(10)
    Assert(!DanmakuEditorWindow && SharedDanmakuItems.Length=beforeFocusSave+1,"save callback completes")
    Assert(WinActive("ahk_id " ManagementWindow.Hwnd),"save restores active management panel")
    Assert(DllCall("GetFocus","Ptr")=ManagedList.Hwnd && ManagedList.GetNext()=SharedDanmakuItems.Length,"saved row retains keyboard focus")
    TransferItem()
    moveDialog := ActiveEditorDialog.Window
    otherWindow := Gui(,"Focus test")
    otherWindow.Show("w200 h100")
    WinActivate("ahk_id " otherWindow.Hwnd)
    ShowPalette()
    Assert(WinWaitActive("ahk_id " moveDialog.Hwnd,,2),"palette shortcut recalls transfer editor")
    WinClose("ahk_id " moveDialog.Hwnd)
    Sleep(50)
    Assert(!ActiveEditorDialog,"transfer editor closes normally after recall")
    otherWindow.Destroy()
    UndoLibraryChange()
    OpenDanmakuEditor(true)
    WinActivate("ahk_id " DanmakuEditorWindow.Hwnd)
    WinWaitActive("ahk_id " DanmakuEditorWindow.Hwnd,,2)
    CloseDanmakuEditor()
    Assert(WinActive("ahk_id " ManagementWindow.Hwnd) && SharedDanmakuItems.Length=beforeFocusSave,"cancel restores panel without saving")
    ManagementWindow.Hide()
    Assert(Profiles.Length > 0, "existing profiles loaded")
    Assert(!Profiles[1].HasOwnProp("Reaction"), "profile reaction setting removed")
    Assert(ItemSlot(Profiles[1].Items[1]) = 1, "old first preset keeps shortcut")

    initial := CreateSettingsSnapshot()
    initial.Profiles.Push({Id:NewRecordId(),Name:"editing B",Channel:"/channel/b",Items:[]})
    CommitLibraryChange(initial,"test author")
    SaveInputProfileSelection(1)
    activeId := GetInputProfile().Id
    EditProfileIndex := Profiles.Length, EditScopeShared := false
    RefreshManagement()
    Assert(GetInputProfile().Id = activeId, "editing another profile preserves active input target")
    state := CreateSettingsSnapshot()
    state.Profiles[EditProfileIndex].Items := [{Name:"B",Text:"bbb",Slot:1}]
    CommitLibraryChange(state,"B item")
    Assert(GetInputProfile().Id = activeId && Profiles[EditProfileIndex].Items.Length = 1,"editing commits without changing active target")
    EditProfileIndex := 1
    originalText := Profiles[1].Items[1].Text
    state := CreateSettingsSnapshot()
    first := state.Profiles[1].Items.RemoveAt(1)
    state.Profiles[1].Items.Push(first)
    CommitLibraryChange(state,"reorder")
    Assert(ItemSlot(Profiles[1].Items[-1]) = 1 && Profiles[1].Items[-1].Text = originalText,"shortcut follows item after reorder")
    state := CreateSettingsSnapshot()
    AssignItemSlot(state.Profiles[1].Items,1,1)
    CommitLibraryChange(state,"assign")
    Assert(ItemSlot(Profiles[1].Items[1]) = 1 && ItemSlot(Profiles[1].Items[-1]) = 0,"assignment moves uniquely")
    state := CreateSettingsSnapshot()
    state.Profiles[1].Items.RemoveAt(1)
    CommitLibraryChange(state,"delete")
    for item in Profiles[1].Items
        Assert(ItemSlot(item) != 1,"deletion leaves shortcut unassigned")
    historySize := LibraryHistory.Length
    UndoLibraryChange()
    Assert(LibraryHistory.Length = historySize-1 && ItemSlot(Profiles[1].Items[1])=1,"undo restores deleted assignment")
    UndoLibraryChange()
    Assert(ItemSlot(Profiles[1].Items[-1])=1,"multi-step undo restores previous assignment")
    beforeCount := Profiles.Length
    state := CreateSettingsSnapshot()
    state.Profiles.RemoveAt(1)
    CommitLibraryChange(state,"remove active")
    Assert(InputProfileIndex=0,"deleting active author never silently targets next author")
    UndoLibraryChange()
    Assert(Profiles.Length=beforeCount && InputProfileIndex=0,"undo restores author without selecting a different target")
    SaveInputProfileSelection(1)
    EditScopeShared := true
    state := CreateSettingsSnapshot()
    state.SharedDanmakuItems := [{Name:"search target",Text:"unique body",Slot:1},{Name:"other",Text:"other",Slot:0}]
    CommitLibraryChange(state,"shared")
    PaletteSearch.Value := "unique body"
    RefreshPaletteItems()
    Assert(PaletteRows.Length=1 && PaletteRows[1].Shared,"search includes body and preserves scope")
    PaletteSearch.Value := ""
    SaveReactionDefaults(CreateReactionOptions(3,10,100,ReactionShortcut))
    ResetPaletteSession()
    PaletteCount.Choose(3)
    Assert(PaletteOptions().Count=100 && DefaultReactionCount=10,"session setting does not modify defaults")
    savedCount := DefaultReactionCount
    UndoLibraryChange()
    Assert(DefaultReactionCount=savedCount,"library undo never reverts reaction defaults")
    priorProfiles := Profiles, priorHistory := LibraryHistory.Length, path := SettingsDatabasePath
    SettingsDatabasePath := A_ScriptDir "\missing\cannot-save.ini"
    failed := false
    state := CreateSettingsSnapshot(), state.Profiles[1].Name := "not saved"
    try CommitLibraryChange(state,"failed")
    catch
        failed := true
    Assert(failed && Profiles=priorProfiles && LibraryHistory.Length=priorHistory,"failed save preserves live data and history")
    SettingsDatabasePath := path
    SaveInputProfileSelection(1)
    RefreshProfiles()
    PaletteWindow.Show("Hide w360 h620")
    LayoutPalette(PaletteWindow,0,360,620)
    for control in PaletteWindow {
        control.GetPos(&x,&y,&w,&h)
        Assert(x>=0 && x+w<=360 && y>=0 && y+h<=620,"palette fits narrow client: " control.Type)
    }
    ManagementWindow.Show("Hide w380 h520")
    LayoutManagement(ManagementWindow,0,380,520)
    for control in ManagementWindow {
        control.GetPos(&x,&y,&w,&h)
        Assert(x>=0 && x+w<=380 && y>=0 && y+h<=520,"management fits narrow client: " control.Type " " control.Text)
    }
    EditScopeShared := true
    RefreshManagement()
    OpenDanmakuEditor(true)
    Assert(!!DanmakuEditorWindow && !DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"editor locks input palette")
    CloseDanmakuEditor()
    Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"editor unlocks palette")
    priorKey := ReactionShortcut
    failed := false
    try SaveReactionDefaults(CreateReactionOptions(1,1,100,"^!q"))
    catch
        failed := true
    Assert(failed && ReactionShortcut=priorKey,"reserved key rejected transactionally")
    for interval in ReactionIntervals {
        SaveReactionDefaults(CreateReactionOptions(1,1,interval,priorKey))
        Assert(LoadSettings(SettingsDatabasePath).DefaultReactionIntervalMs=interval,"interval persisted " interval)
    }
    for count in ReactionCounts {
        job := {StartedAt:0,Total:count,Completed:count-1,Cancelled:false,Interval:100}
        ActiveReactionJob := job
        ApplyReactionResult(job,{State:"operated"})
        Assert(job.Completed=count && !ActiveReactionJob,"exact completion " count)
    }

    ; Commands are executable without controls or an editing selection.
    author := ExecuteProfileCommand("add","","service author")
    id := author.ProfileId
    oldInputId := GetInputProfile() ? GetInputProfile().Id : ""
    added := ExecuteDanmakuCommand("add",id,0,{Name:"first",Text:"aaa",Slot:1})
    ExecuteDanmakuCommand("add",id,0,{Name:"second",Text:"bbb",Slot:2})
    ExecuteDanmakuCommand("down",id,1)
    serviceItems := GetLibraryItems(CreateLibrarySnapshot(),id)
    Assert(serviceItems[2].Text="aaa" && ItemSlot(serviceItems[2])=1,"service reorder preserves assignment")
    ExecuteDanmakuCommand("edit",id,2,{Name:"edited",Text:"ccc",Slot:2})
    serviceItems := GetLibraryItems(CreateLibrarySnapshot(),id)
    Assert(ItemSlot(serviceItems[1])=0 && serviceItems[2].Text="ccc","service edit assigns slot uniquely")
    ExecuteDanmakuCommand("duplicate",id,2)
    Assert(ItemSlot(GetLibraryItems(CreateLibrarySnapshot(),id)[3])=0,"service duplicate is unassigned")
    sharedCount := SharedDanmakuItems.Length
    ExecuteDanmakuCommand("move",id,2,0,"")
    Assert(SharedDanmakuItems.Length=sharedCount+1 && ItemSlot(SharedDanmakuItems[-1])=0,"service move clears slot")
    UndoLibraryCommand()
    Assert(SharedDanmakuItems.Length=sharedCount && GetLibraryItems(CreateLibrarySnapshot(),id)[2].Text="ccc","service undo restores both scopes")
    ExecuteProfileCommand("bind",id,"/channel/service-only")
    conflict := ExecuteProfileCommand("add","","conflict")
    rejected := false
    try ExecuteProfileCommand("bind",conflict.ProfileId,"/channel/service-only")
    catch
        rejected := true
    Assert(rejected,"service enforces unique channel binding")
    ExecuteProfileCommand("rename",id,"renamed author")
    Assert(Profiles[FindProfileIndexById(Profiles,id)].Name="renamed author","service rename")
    ExecuteProfileCommand("unbind",id)
    Assert(!ChannelIndex.Has("/channel/service-only"),"service unbind refreshes index")
    Assert((GetInputProfile() ? GetInputProfile().Id : "")=oldInputId,"service commands preserve input identity")
    stale := CreateSettingsSnapshot()
    SaveReactionDefaults(CreateReactionOptions(4,10,50,ReactionShortcut))
    stale.DefaultReactionKind := 1
    CommitLibraryChange(stale,"stale caller")
    actualState := LoadSettings(SettingsDatabasePath)
    Assert(actualState.DefaultReactionKind=4 && DefaultReactionKind=4,"library commit cannot overwrite other preferences")
    beforeFailure := CreateLibrarySnapshot(), historySize := LibraryHistory.Length
    rejected := false
    try ExecuteDanmakuCommand("edit",id,1,{Name:"invalid",Text:"first`nsecond",Slot:1})
    catch
        rejected := true
    Assert(rejected && LibraryHistory.Length=historySize && GetLibraryItems(CreateLibrarySnapshot(),id)[1].Text=GetLibraryItems(beforeFailure,id)[1].Text,"failed command preserves data and history")
    rejected := false
    try ExecuteDanmakuCommand("add","missing-id",0,{Name:"x",Text:"y",Slot:0})
    catch
        rejected := true
    Assert(rejected,"commands reject missing profile IDs")
    ; Resolve an assignment once and pin the resulting video/text for delivery.
    savedLibrary := CreateLibrarySnapshot(), savedAuto := AutoMode
    savedInput := GetInputProfile() ? GetInputProfile().Id : ""
    fixtureLibrary := {Profiles:[
        {Id:"input-a",Name:"A",Channel:"/channel/a",Items:[{Name:"A2",Text:"A-two",Slot:2},{Name:"A1",Text:"A-one",Slot:1}]},
        {Id:"input-b",Name:"B",Channel:"/channel/b",Items:[{Name:"B1",Text:"B-one",Slot:1},{Name:"B2",Text:"B-two",Slot:2}]}],SharedDanmakuItems:[]}
    CommitLibraryChange(fixtureLibrary,"input fixture")
    global FixtureInputMode := true, FixtureResolveCount := 0, FixtureCurrentVideo := "aaaaaaaaaaa", FixtureSent := []
    AutoMode := true
    plan := ResolveDanmakuInput(false,1,123,true)
    Assert(FixtureResolveCount=1 && plan.Text="A-one" && plan.Video="aaaaaaaaaaa","shortcut resolves profile and slot exactly once")
    FixtureCurrentVideo := "bbbbbbbbbbb"
    Assert(!DeliverText(plan.Text,plan.Window,plan.Video) && FixtureSent.Length=0,"video change after resolving prevents any input")
    Assert(FixtureResolveCount=1,"delivery never re-resolves profile or list index")
    FixtureCurrentVideo := "aaaaaaaaaaa"
    Assert(DeliverText(plan.Text,plan.Window,plan.Video) && FixtureSent[1]="A-one","unchanged target delivers the frozen text")
    rejected := false
    try ResolveDanmakuInput(false,1,123,false,"input-b")
    catch
        rejected := true
    Assert(rejected,"palette selection refuses changed profile identity")
    FixtureInputMode := false, AutoMode := savedAuto
    CommitLibraryChange(savedLibrary,"restore fixture")
    if savedInput != ""
        SaveInputProfileSelection(FindProfileIndexById(Profiles,savedInput))
    RefreshProfiles()
    modal := Gui(,"key editing fixture")
    PaletteWindow.Opt("+Disabled")
    BeginEditorDialog(modal,"リアクションキーの編集")
    Assert(ActiveEditorDialog.Label="リアクションキーの編集" && ShortcutBlocked(),"blocking reason identifies actual dialog")
    EndEditorDialog()
    Assert(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"closing dialog preserves previously disabled window")
    PaletteWindow.Opt("-Disabled"), modal.Destroy()

    registrationTokens := "["
    Loop 5
        registrationTokens .= (A_Index>1 ? "," : "") '{"name":"reaction' A_Index '","id":"id' A_Index '","class":"button","type":50000}'
    registrationTokens .= "]"
    SaveReactionRegistration('{"browser":"fixture","tokens":' registrationTokens '}')
    context := RequestBrowserOperation(123, "browser_context")
    Assert(context.State = "ok" && context.Video = "abcdefghijk", "pipe reaction context")
    result := RequestBrowserOperation(123, "reaction_check", context.Video)
    Assert(result.State = "ready", "non-sending check through pipe")
    result := RequestBrowserOperation(123, "reaction_send", "ABCDEFGHIJK", "Reaction=1`n")
    Assert(result.State = "changed", "changed video rejected through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "mock operation through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "no implicit cooldown between operations")
    firstPID := WorkerProcessId
    sequenceBeforeCrash := WorkerRequestSequence
    ProcessClose(firstPID)
    ProcessWaitClose(firstPID, 2)
    recovered := RequestBrowserOperation(123, "browser_context")
    Assert(recovered.State = "ok" && WorkerProcessId != firstPID && WorkerRequestSequence = sequenceBeforeCrash + 1, "crashed worker restarts on next request without replay")
    firstPID := WorkerProcessId
    StopBrowserWorker()
    Assert(!ProcessExist(firstPID), "worker shuts down")
    context := RequestBrowserOperation(123, "browser_context")
    global StoppedWhileWaiting := false
    ActiveReactionJob := {Mode:"reaction_send", Cancelled:false, Completed:0, Total:1}
    waitingJob := ActiveReactionJob
    SetTimer(CancelDuringFixtureWait, -30)
    delayed := RequestBrowserOperation(123, "verify", context.Video, "FixtureDelay=250`n")
    Assert(delayed.State = "ok" && StoppedWhileWaiting && waitingJob.Cancelled, "notification wait pumps cancellation before response")
    CancelReaction()
    timedOut := SendWorkerRequest(123, "verify", context.Video, "FixtureDelay=3500`n")
    Assert(timedOut.State = "unavailable" && !WorkerProcessId && !WorkerPipeHandle && !WorkerSignalHandle, "timeout releases pipe and notification resources")
    context := RequestBrowserOperation(123, "browser_context")
    crashed := SendWorkerRequest(123, "reaction_send", context.Video, "FixtureExit=1`nReaction=1`n")
    Assert(crashed.State = "unknown" && !WorkerProcessId && !WorkerSignalHandle, "in-flight crash is unknown and never replayed")
    Assert(RequestBrowserOperation(123,"browser_context").State = "ok", "notification resources recover after in-flight crash")
    StopBrowserWorker()
    ActiveReactionJob := {Mode: "queued", Cancelled: false, Window: 0}
    SetReactionStatus("文言を変更した開始待ち", false, "queued")
    PaletteStatusControl.Text := "表示だけを書き換えた文言"
    QuickReaction()
    Assert(!ActiveReactionJob && ReactionExecutionStatus.Final && ReactionExecutionStatus.Phase = "finished", "early exit finalizes regardless of displayed wording")
    Assert(InStr(ReactionExecutionStatus.Message, "開始できません"), "early exit records controller outcome")
    ActiveReactionJob := {Mode: "queued", Cancelled: false, Window: 0}
    SetReactionStatus("開始待ち", false, "queued")
    CancelReaction()
    cancelledMessage := ReactionExecutionStatus.Message
    QuickReaction()
    Assert(ReactionExecutionStatus.Message = cancelledMessage, "queued cancellation result is retained")
    global ShortcutReleaseReplacement, ShortcutReleaseResult
    for released in [false, true] {
        replacementJob := {Mode:"queued", Cancelled:false, Window:0}
        ShortcutReleaseReplacement := replacementJob
        ShortcutReleaseResult := released
        ActiveReactionJob := {Mode:"queued", Cancelled:false, Window:0}
        SetReactionStatus("新しい開始待ち", false, "queued")
        QuickReaction()
        Assert(ActiveReactionJob = replacementJob && ReactionExecutionStatus.Phase = "queued", "old shortcut cleanup preserves replacement job")
    }
    ShortcutReleaseReplacement := 0
    CancelReaction()
    schemaPath := A_ScriptDir "\schema-check.db"
    schemaState := CreateSettingsSnapshot()
    schemaState.SharedDanmakuItems := [
        {Name:Chr(34) "quoted label" Chr(34), Text:"  👏👏  "},
        {Name:"quoted text", Text:Chr(34) "👏" Chr(34)},
        {Name:"single quotes", Text:"'👏'"}]
    SaveSettings(schemaState, schemaPath)
    roundTrip := LoadSettings(schemaPath)
    for i, expected in schemaState.SharedDanmakuItems {
        Assert(roundTrip.SharedDanmakuItems[i].Name == expected.Name, "database preserves label quotes")
        Assert(roundTrip.SharedDanmakuItems[i].Text == expected.Text, "database preserves literal text and spaces")
    }
    longText := ""
    Loop 35000
        longText .= "👏"
    for length in [32767, 65534, 70000] {
        expected := SubStr(longText, 1, length - Mod(length, 2))
        schemaState.SharedDanmakuItems := [{Name:"long",Text:expected}]
        schemaState.Profiles[1].Items := [{Name:"long",Text:expected}]
        SaveSettings(schemaState, schemaPath)
        actual := LoadSettings(schemaPath)
        Assert(actual.SharedDanmakuItems[1].Text == expected, "long shared text round-trip " length)
        Assert(actual.Profiles[1].Items[1].Text == expected, "long profile text round-trip " length)
    }
    legacyPath := A_ScriptDir "\legacy-reader.ini"
    legacyText := "; comment`r`n[general]`r`nCount=0`r`n[commondanmaku]`r`nCount=2`r`nLabel1=' legacy '`r`nText1=" Chr(34) "  a=b;👏  " Chr(34) "`r`nLabel2=plain`r`nText2=  unquoted  `r`n"
    for encoding in ["UTF-16", "UTF-8"] {
        if FileExist(legacyPath)
            FileDelete(legacyPath)
        FileAppend(legacyText, legacyPath, encoding)
        legacy := ReadLegacySettings(legacyPath)
        Assert(legacy.SharedDanmakuItems[1].Name == " legacy " && legacy.SharedDanmakuItems[1].Text == "  a=b;👏  ", "legacy quotes, case and BOM " encoding)
        Assert(legacy.SharedDanmakuItems[2].Text == "unquoted", "legacy unquoted whitespace " encoding)
    }
    LastReactionResult.Detail := "previous failure"
    completedJob := {StartedAt:0,Completed:0, Total:1, Cancelled:false}
    ActiveReactionJob := completedJob
    ApplyReactionResult(completedJob, {State:"operated"})
    Assert(LastReactionResult.Detail = "" && InStr(LastReactionResult.Message, "完了"), "success clears previous failure detail")
    savedRoundTrip := FileRead(schemaPath,"RAW")
    schemaState.SharedDanmakuItems[1].Text := "first`nsecond"
    rejected := false
    try SaveSettings(schemaState, schemaPath)
    catch
        rejected := true
    Assert(rejected && SameFileBytes(FileRead(schemaPath,"RAW"),savedRoundTrip) && !FileExist(schemaPath ".new"), "multiline text cannot corrupt persisted database")
    schemaState.SharedDanmakuItems[1].Text := "👏"
    bulkState := CreateSettingsSnapshot()
    bulkState.Profiles := []
    Loop 50 {
        bulkProfile := {Name:"配信者" A_Index,Channel:"/channel/fixture" A_Index,Id:NewRecordId(),Items:[]}
        Loop 10
            bulkProfile.Items.Push({Name:"弾幕" A_Index,Text:"  👏" Chr(34) "引用符" Chr(34) "👏  "})
        bulkState.Profiles.Push(bulkProfile)
    }
    SaveSettings(bulkState, schemaPath)
    bulkRead := LoadSettings(schemaPath)
    Assert(bulkRead.Profiles.Length = 50, "bulk save retains all sections")
    for i, profile in bulkRead.Profiles {
        Assert(profile.Name == bulkState.Profiles[i].Name && profile.Items.Length = 10, "bulk save retains author and count")
        for j, item in profile.Items
            Assert(item.Text == bulkState.Profiles[i].Items[j].Text, "bulk save preserves unicode quotes and spaces")
    }
    diskBeforeLock := LoadSettings(schemaPath)
    blocker := SqliteConnection(schemaPath)
    blocker.Exec("BEGIN IMMEDIATE")
    failed := false
    try SaveSettings(schemaState,schemaPath)
    catch
        failed := true
    finally {
        blocker.Exec("ROLLBACK"), blocker.Close()
    }
    Assert(failed && LoadSettings(schemaPath).Profiles.Length=diskBeforeLock.Profiles.Length,"competing writer preserves database")
    ReactionCounts.Push(7)
    ReactionIntervals.Push(75)
    try {
        schemaState.DefaultReactionCount := 7
        schemaState.DefaultReactionIntervalMs := 75
        SaveSettings(schemaState, schemaPath)
        schemaRead := LoadSettings(schemaPath)
        Assert(schemaRead.DefaultReactionCount = 7 && schemaRead.DefaultReactionIntervalMs = 75, "store accepts options from shared schema")
        Assert(SettingOptionLabels(ReactionCounts, "回")[-1] = "7回" && SettingOptionLabels(ReactionIntervals, " ms")[-1] = "75 ms", "UI labels follow shared schema")
    } finally {
        ReactionCounts.Pop()
        ReactionIntervals.Pop()
        CloseSettingsStore()
        FileDelete(schemaPath)
    }
    global FixtureStarts := []
    Assert(ReactionIntervalLabels()[1] = "待機なし", "待機なし is an explicit UI option")
    clockJob := {Interval:25, StartedAt:100}
    Assert(ReactionWaitRemaining(clockJob, 110) = 15, "processing time is included in interval")
    Assert(ReactionWaitRemaining(clockJob, 140) = 0, "overrun has no extra wait or catch-up debt")
    Assert(ReactionWaitRemaining({Interval:0, StartedAt:100}, 100) = 0, "待機なし never adds delay")
    for interval in [0, 25] {
        FixtureStarts := []
        job := {Mode:"reaction_send", Window:123, Video:"abcdefghijk", Choice:1, Total:4, Completed:0, Cancelled:false, Interval:interval}
        ActiveReactionJob := job
        ReactionSendNext()
        Assert(job.Completed = 4 && !ActiveReactionJob && FixtureStarts.Length = 4, "serial batch completes " interval " completed=" job.Completed " starts=" FixtureStarts.Length " detail=" LastReactionResult.Detail " result=" LastReactionResult.Message)
        if interval {
            Loop 3
                Assert(FixtureStarts[A_Index+1] - FixtureStarts[A_Index] >= interval - 0.1, "minimum start-to-start target respected")
        }
    }
    job := {Mode:"reaction_send", Window:123, Video:"abcdefghijk", Choice:1, Total:10000, Completed:0, Cancelled:false, Interval:0}
    ActiveReactionJob := job
    SetTimer(CancelReaction, -30)
    ReactionSendNext()
    Assert(job.Cancelled && !ActiveReactionJob && job.Completed < 10000, "待機なし pumps Esc cancellation")
    job := {Interval:1000, StartedAt:ReactionClockMs(), Cancelled:false}
    ActiveReactionJob := job
    SetTimer(CancelReaction, -30)
    Assert(!WaitReactionInterval(job) && !ActiveReactionJob, "long interval wait is cancellable")
    owner := Gui(, "ChatPalette test owner"), other := Gui(, "ChatPalette test other")
    target := owner.AddButton("w100", "Fixture")
    owner.Show("NoActivate"), other.Show("NoActivate w120 h80")
    for enabled in [1, 0] {
        target.Enabled := enabled
        reply := SendWorkerRequest(123, "fixture_native", "", "Element=" target.Hwnd "`nParent=" owner.Hwnd "`nOther=" other.Hwnd "`nEnabled=" enabled "`n")
        Assert(reply.State = "ok", "real UIA cache refresh and wrong-window rejection " enabled)
    }
    owner.Destroy(), other.Destroy()
    StopBrowserWorker()
    FileAppend("PASS: " Checks " application and named-pipe checks`n", "*")
    ExitApp(0)
} catch as testError {
    FileAppend("FAIL: " testError.Message " at line " testError.Line " " testError.File " " testError.Extra "`n" testError.Stack "`n", "*")
    ExitApp(1)
}
ResolveBrowserChannel(hwnd) {
    global FixtureResolveCount
    if IsSet(FixtureInputMode) && FixtureInputMode {
        FixtureResolveCount++
        return {State:"ok",Author:"A",Channel:"/channel/a",Video:"aaaaaaaaaaa"}
    }
    return ResolveFixtureBrowserChannel(hwnd)
}
VerifyInputTarget(hwnd, expectedVideo) {
    if IsSet(FixtureInputMode) && FixtureInputMode
        return expectedVideo == FixtureCurrentVideo
    return VerifyFixtureInputTarget(hwnd,expectedVideo)
}
FixtureInputWindowActive(hwnd) {
    return IsSet(FixtureInputMode) && FixtureInputMode && hwnd = 123
}
CaptureFixtureInput(text) {
    if !(IsSet(FixtureInputMode) && FixtureInputMode)
        throw Error("Unexpected input outside fixture")
    FixtureSent.Push(text)
}

FixtureReactionWindowActive(hwnd) {
    return hwnd = 123
}
ObserveHiddenLayout(view,w,h) {
    global observedHidden := !DllCall("IsWindowVisible","Ptr",view.Hwnd) && w>0 && h>0
}
ObservePresentation(view,state,w,h) {
    PresentationStates.Push(!!DllCall("IsWindowVisible","Ptr",view.Hwnd))
    Assert(w>0 && h>0,"presentation callback receives final client size")
}
FailPresentation(*) {
    throw Error("fixture layout failure")
}
PrepareViewportFixture(viewport) {
    Assert(!DllCall("IsWindowVisible","Ptr",viewport.Hwnd),"viewport layout runs before visibility")
    viewport.Resize()
}
SameFileBytes(left,right) {
    return left.Size=right.Size && (!left.Size || DllCall("msvcrt\memcmp","Ptr",left,"Ptr",right,"UPtr",left.Size,"CDecl Int")=0)
}
Assert(condition, label) {
    global Checks
    if !condition
        throw Error(label)
    Checks++
}
SetReactionHotkey(key, enabled := true) {
    RegisterFixtureHotkey(key, enabled)
    if IsSet(KeyCalls)
        KeyCalls.Push({Key:key, Enabled:enabled})
}
WaitShortcutRelease(keys) {
    global ActiveReactionJob
    if IsSet(ShortcutReleaseReplacement) && ShortcutReleaseReplacement {
        ; Model Esc followed by a new shortcut while the old KeyWait is suspended.
        ActiveReactionJob := ShortcutReleaseReplacement
        return ShortcutReleaseResult
    }
    return WaitFixtureShortcutRelease(keys)
}
CancelDuringFixtureWait() {
    global StoppedWhileWaiting := IsBrowserOperationBusy
    CancelReaction()
}
'@
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText("$fixture\test.ahk", $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut',('"' + "$fixture\test.ahk" + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput "$fixture\out.txt" -RedirectStandardError "$fixture\error.txt"
$null = $run.Handle
if (-not $run.WaitForExit(30000)) { $run.Kill(); throw 'Test timeout' }
Get-Content "$fixture\out.txt","$fixture\error.txt"
if ($run.ExitCode -ne 0) { throw 'Application test failed' }
