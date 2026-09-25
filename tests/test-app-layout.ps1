# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    ShowManagement(1)
    EditingProfileId := ""
    RefreshManagement()
    Assert(!ManagementStatus.Visible && ManagementStatus.Text="","empty notification is hidden")
    ManagementWindow.Hide()
    SetManagementNotice("保存できませんでした。詳細")
    ShowManagement(1)
    Assert(ManagementStatus.Visible && InStr(ManagementStatus.Text,"通知：保存できませんでした"),"failure notification is visible and labelled")
    SetManagementNotice("")
    Assert(!ManagementStatus.Visible,"cleared notification is hidden")
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
    PaletteWindow.Show()
    WinActivate("ahk_id " PaletteWindow.Hwnd)
    Assert(WinWaitActive("ahk_id " PaletteWindow.Hwnd,,2),"palette is foreground before link click")
    RefreshOperationControls()
    SendMessage(0xF5,0,0,PaletteBind.Hwnd)
    deadline := A_TickCount+2000
    while !ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    Assert(ActiveEditorDialog,"palette button opens shared link editor")
    linkDialog := ActiveEditorDialog.Window
    WinActivate("ahk_id " linkDialog.Hwnd)
    Assert(WinWaitActive("ahk_id " linkDialog.Hwnd,,2),"link chooser active")
    for control in linkDialog
        if control.Type="Button" && control.Text="連携する"
            linkSave := control
    WinActivate("ahk_id " linkDialog.Hwnd)
    Assert(WinWaitActive("ahk_id " linkDialog.Hwnd,,2),"link editor is foreground before save")
    SendMessage(0xF5,0,0,linkSave.Hwnd)
    deadline := A_TickCount+2000
    while ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    Assert(!ActiveEditorDialog && Profiles.Length=profilesBeforeLink+1,"link dialog creates new profile")
    Assert(Profiles[-1].Channel="/channel/a" && LibraryHistory.Length=historyBeforeLink+1,"creation and linking commit once")
    Assert(FixtureResolveCount=2,"link rechecks channel before commit")
    UndoLibraryChange()
    Assert(Profiles.Length=profilesBeforeLink && !FindProfileByChannel(Profiles,"/channel/a"),"one undo removes created linked profile")
    targetProfile := ExecuteProfileCommand("add","","managed target").ProfileId
    EditingProfileId := targetProfile
    countBeforeBind := Profiles.Length
    ManageProfile("bind")
    linkDialog := ActiveEditorDialog.Window
    linkChoice := 0
    for control in linkDialog {
        if control.Type="DDL"
            linkChoice := control
        if control.Type="Button" && control.Text="連携する"
            linkSave := control
    }
    Assert(linkChoice && linkChoice.Text="managed target","management link opens shared chooser with managed profile selected")
    WinActivate("ahk_id " linkDialog.Hwnd)
    Assert(WinWaitActive("ahk_id " linkDialog.Hwnd,,2),"link editor is foreground before save")
    SendMessage(0xF5,0,0,linkSave.Hwnd)
    deadline := A_TickCount+2000
    while ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    Assert(!ActiveEditorDialog && Profiles.Length=countBeforeBind && FindProfileById(Profiles,targetProfile).Channel="/channel/a","management link updates existing profile through shared editor")
    OpenChannelLinkDialog()
    linkDialog := ActiveEditorDialog.Window
    linkChoice := 0
    for control in linkDialog
        if control.Type="DDL"
            linkChoice := control
    Assert(linkChoice && linkChoice.Text="managed target","palette chooser still defaults to current channel owner")
    for control in linkDialog
        if control.Type="Button" && control.Text="連携する"
            linkSave := control
    beforeMismatchHistory := LibraryHistory.Length
    global MismatchResolveCalls := 0
    RuntimePorts.ResolveChannel := ResolveMismatchedChannel
    WinActivate("ahk_id " linkDialog.Hwnd)
    Assert(WinWaitActive("ahk_id " linkDialog.Hwnd,,2),"link editor is foreground before save")
    SendMessage(0xF5,0,0,linkSave.Hwnd)
    deadline := A_TickCount+2000, rejectedMessage := false
    while ActiveEditorDialog && !rejectedMessage && A_TickCount<deadline {
        for control in linkDialog
            if InStr(control.Text,"連携できませんでした。")
                rejectedMessage := true
        Sleep(10)
    }
    Assert(MismatchResolveCalls=1,"link save invokes fresh channel verification exactly once")
    Assert(ActiveEditorDialog && rejectedMessage,"case-only channel change is rejected while retaining editor")
    Assert(LibraryHistory.Length=beforeMismatchHistory && FindProfileById(Profiles,targetProfile).Channel=="/channel/a","rejected channel change leaves saved binding and history untouched")
    RuntimePorts.ResolveChannel := FixtureResolveChannel
    WinClose("ahk_id " linkDialog.Hwnd)
    deadline := A_TickCount+2000
    while ActiveEditorDialog && A_TickCount<deadline
        Sleep(10)
    Assert(!ActiveEditorDialog,"shared link editor closes normally")
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
    Assert(!ReactionOverlay.Stop.Visible && !ReactionOverlay.Stop.Enabled,"finished reaction has no stop action")
    Assert(PaletteHint.Text="input notification fixture" && PaletteSettingsStatus.Text="settings notification fixture","reaction result does not overwrite input or settings notices")
    ReactionOverlay.Window.Hide()
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
    EditingProfileId := ""
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
    activated := WinWaitActive("ahk_id " anchor.Hwnd,,2)
    if !activated {
        foreground := DllCall("GetForegroundWindow","Ptr"), foregroundPid := 0
        DllCall("GetWindowThreadProcessId","Ptr",foreground,"UInt*",&foregroundPid)
        FileAppend("Presentation diagnostic: visible=" DllCall("IsWindowVisible","Ptr",anchor.Hwnd)
            . " enabled=" DllCall("IsWindowEnabled","Ptr",anchor.Hwnd)
            . " foreground_owned=" (foregroundPid=DllCall("GetCurrentProcessId")) "`n","*")
    }
    Assert(activated,"normal presentation activates")
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

    SetReactionStatus("reaction result fixture",true)
    PaletteStatusControl.Text := "unrelated input notice"
    ShowReactionProgress()
    Assert(InStr(ReactionOverlay.Text.Text,"reaction result fixture") && !InStr(ReactionOverlay.Text.Text,"unrelated input notice"),"overlay reads reaction state instead of generic palette notice")
    Assert(InStr(ReactionProgressHint(ReactionExecutionStatus),"4秒"),"progress uses the supplied final state")
    ReactionOverlay.Window.Hide()
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
    EditingProfileId := ""
    RefreshManagement()
    OpenDanmakuEditor(true)
    Assert(!!ActiveEditorDialog && !DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"editor locks input palette")
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"editor unlocks palette")

'@ -Helpers @'
ResolveMismatchedChannel(hwnd) {
    global MismatchResolveCalls
    MismatchResolveCalls++
    return {State:"ok",Author:"other",Channel:"/channel/A",Video:"bbbbbbbbbbb"}
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

'@

# Dialog commands keep the displayed identity even if state changes during a wait.
Invoke-AppFixture -Body @'
    CommitTestLibraryChange({Profiles:[
        {Id:"link-a",Name:"same",Channel:"",Items:[]},
        {Id:"link-A",Name:"same",Channel:"",Items:[]}],
        SharedDanmakuItems:[{Id:"move-item",Name:"move",Text:"move text",Slot:1}]},"dialog identity fixture")
    global LinkWaitChange := "", LinkChoice := 0, LinkName := 0, LinkChannel := "/channel/first"
    RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
    RuntimePorts.ResolveChannel := ChangeSelectionDuringVerification
    TargetBrowserHwnd := 123
    OpenChannelLinkDialog("link-a")
    LinkChoice := FindDialogControl("DDL")
    LinkWaitChange := "profile"
    SubmitDialog("連携する")
    Assert(FindProfileById(Profiles,"link-a").Channel==LinkChannel && FindProfileById(Profiles,"link-A").Channel="","channel recheck cannot redirect the submitted binding to another same-name profile")
    LinkChannel := "/channel/new"
    OpenChannelLinkDialog()
    LinkName := FindDialogControl("Edit"), LinkName.Value := "submitted name"
    LinkWaitChange := "name"
    SubmitDialog("連携する")
    Assert(Profiles[-1].Name=="submitted name" && Profiles[-1].Channel==LinkChannel,"new-profile submission freezes its name before browser verification")
    EditingProfileId := ""
    RefreshManagement(), ManagedList.Modify(1,"Select Focus")
    TransferItem()
    destination := FindDialogControl("DDL")
    destination.Choose(2)
    ExecuteProfileCommand("delete","link-a")
    SubmitDialog("移動")
    moved := FindProfileById(Profiles,"link-A").Items
    Assert(SharedDanmakuItems.Length=0 && moved.Length=1 && moved[1].Id=="move-item" && moved[1].Slot=0,"move uses the displayed destination ID after an earlier same-name profile is deleted")
    EditingProfileId := "link-A"
    RefreshManagement(), ManagedList.Modify(1,"Select Focus")
    TransferItem()
    Assert(FindDialogControl("DDL").Text="共通の弾幕","profile-to-shared move exposes its explicit shared destination")
    SubmitDialog("移動")
    Assert(SharedDanmakuItems.Length=1 && SharedDanmakuItems[1].Id=="move-item" && !FindProfileById(Profiles,"link-A").Items.Length,"shared destination preserves the moved item identity")
'@ -Helpers @'
ChangeSelectionDuringVerification(hwnd) {
    global LinkWaitChange
    change := LinkWaitChange, LinkWaitChange := ""
    if change="profile"
        LinkChoice.Choose(3)
    else if change="name"
        LinkName.Value := "changed during verification"
    return {State:"ok",Author:"fixture",Channel:LinkChannel,Video:"abcdefghijk"}
}
FindDialogControl(kind,label := "") {
    for control in ActiveEditorDialog.Window
        if control.Type=kind && (label="" || control.Text==label)
            return control
    throw Error("Dialog control not found: " kind " " label)
}
SubmitDialog(label) {
    hwnd := ActiveEditorDialog.Window.Hwnd, button := FindDialogControl("Button",label)
    WinActivate("ahk_id " hwnd)
    Assert(WinWaitActive("ahk_id " hwnd,,2),"dialog is foreground before " label)
    SendMessage(0xF5,0,0,button.Hwnd)
    Assert(WinWaitClose("ahk_id " hwnd,,2) && !ActiveEditorDialog,"submitted dialog finishes " label)
}
'@
