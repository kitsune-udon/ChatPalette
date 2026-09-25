# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
Edit-TestSource $release 'src/ui/reaction_feedback.ahk' '            text := view.AddText("w360 r6", "")' ('            text := view.AddText("w360 r6", "")'+"`r`n            ProbeOverlayConstruction(view)")
Edit-TestSource $release 'src/ui/palette/palette_view.ahk' '            for row in rows' '            for row in rows {'
Edit-TestSource $release 'src/ui/palette/palette_view.ahk' '                PaletteList.Add("",row.ProfileId = "" ? "共通" : "配信者",row.Name "　" row.Text,row.Key,row.ItemId)' ('                PaletteList.Add("",row.ProfileId = "" ? "共通" : "配信者",row.Name "　" row.Text,row.Key,row.ItemId)'+"`r`n                ProbeListUpdate()`r`n            }")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '            control.Delete(), control.Add(labels), control.Choose(choices[i])' ('            control.Delete(), control.Add(labels), control.Choose(choices[i])'+"`r`n            ProbeShortcutItems(i)")
Edit-TestSource $release 'src/ui/panel_viewport.ahk' '    ApplyOffset(x, y) {' ("    ApplyOffset(x, y) {`r`n        ProbeViewport(this)")
Edit-TestSource $release 'src/input/input_controller.ahk' 'RequestDanmakuInput(request) {' 'OriginalRequestDanmakuInput(request) {'
Edit-TestSource $release 'src/ui/management/management_view.ahk' '        for row in model.Rows' '        for row in model.Rows {'
Edit-TestSource $release 'src/ui/management/management_view.ahk' '        ManagedList.ModifyCol(1,160)' ("            ProbeManagementUpdate()`r`n        }`r`n        ManagedList.ModifyCol(1,160)")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '        viewport.Show()' ("        if IsSet(ProbeShortcutFailure) && ProbeShortcutFailure`r`n            throw Error(""fixture shortcut presentation failure"")`r`n        viewport.Show()")
Edit-TestSource $release 'src/ui/window_presenter.ahk' 'PresentWindow(view, options := "", layout := 0, activate := true) {' ('PresentWindow(view, options := "", layout := 0, activate := true) {' + "`r`n    if IsSet(ProbeEditorFailure) && ProbeEditorFailure && ActiveEditorDialog && ActiveEditorDialog.Window = view`r`n        throw Error(""fixture editor presentation failure"")")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    moveButton.OnEvent("Click",Move)' ('    moveButton.OnEvent("Click",Move)' + "`r`n    global ProbeCommitAction := Move")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)' ('    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)' + "`r`n    global ProbeCommitAction := Save")
Edit-TestSource $release 'src/ui/management/management_view.ahk' 'RefreshManagement(render := 0) {' ('RefreshManagement(render := 0) {' + "`r`n    if IsSet(ProbeAfterSaveFailure) && ProbeAfterSaveFailure`r`n        throw Error(""fixture post-save refresh failure"")")
Edit-TestSource $release 'src/ui/palette/palette_view.ahk' 'RefreshPalette() {' ('RefreshPalette() {' + "`r`n    if IsSet(ProbeShortcutRefreshFailure) && ProbeShortcutRefreshFailure`r`n        throw Error(""fixture shortcut refresh failure"")")
Edit-TestSource $release 'src/ui/ui_runtime.ahk' 'RefreshOperationControls() {' ('RefreshOperationControls() {' + "`r`n    global ProbeWaitFailure`r`n    if IsSet(ProbeWaitFailure) && ProbeWaitFailure && IsBrowserOperationBusy {`r`n        ProbeWaitFailure := false`r`n        throw Error(""fixture wait preparation failure"")`r`n    }")
Edit-TestSource $release 'src/ui/ui_runtime.ahk' 'RefreshOperationControls() {' ('RefreshOperationControls() {' + "`r`n    global ProbeEditorBeginFailure`r`n    if IsSet(ProbeEditorBeginFailure) && ProbeEditorBeginFailure && ActiveEditorDialog {`r`n        ProbeEditorBeginFailure := false`r`n        throw Error(""fixture editor begin failure"")`r`n    }")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '        view.SetFont("s10","Yu Gothic UI")' ('        view.SetFont("s10","Yu Gothic UI")' + "`r`n        if IsSet(ProbeEditorConstructionFailure) && ProbeEditorConstructionFailure {`r`n            global ProbeEditorConstructionHwnd := view.Hwnd`r`n            throw Error(""fixture editor construction failure"")`r`n        }")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    view.OnEvent("Close",Close), view.OnEvent("Escape",Close)' ('    view.OnEvent("Close",Close), view.OnEvent("Escape",Close)' + "`r`n    ProbeEditorBuild(view)")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    view.OnEvent("Close",Close),view.OnEvent("Escape",Close)' ('    view.OnEvent("Close",Close),view.OnEvent("Escape",Close)' + "`r`n    ProbeEditorBuild(view)")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '    viewport := PanelViewport(view,680,780)' ('    viewport := PanelViewport(view,680,780)' + "`r`n    ProbeEditorBuild(view,viewport)")
Edit-TestSource $release 'src/ui/panel_viewport.ahk' '            OnMessage(0x115,this.ScrollHandler)' ('            OnMessage(0x115,this.ScrollHandler)' + "`r`n            ProbeViewportRegistration(this)")
Edit-TestSource $release 'src/ui/help_view.ahk' '        topics.Choose(ManagementTabs.Value = 1 ? 2 : 3)' ('        topics.Choose(ManagementTabs.Value = 1 ? 2 : 3)' + "`r`n    ProbeInfoDialogBuild(view)")
Edit-TestSource $release 'src/ui/reaction_feedback.ahk' '    details.AddButton("x12 y324 w180","結果と詳細をコピー").OnEvent("Click", (*) => A_Clipboard := content)' ('    details.AddButton("x12 y324 w180","結果と詳細をコピー").OnEvent("Click", (*) => A_Clipboard := content)' + "`r`n    ProbeInfoDialogBuild(details)")
Edit-TestSource $release 'src/ui/window_presenter.ahk' 'PresentWindow(view, options := "", layout := 0, activate := true) {' ('PresentWindow(view, options := "", layout := 0, activate := true) {' + "`r`n    if IsSet(ProbeInfoFailure) && ProbeInfoFailure = ""show"" && view.Hwnd = ProbeInfoHwnd`r`n        throw Error(""fixture info show failure"")")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '        try SaveShortcutMap(draft)' ("        try {`r`n            SaveShortcutMap(draft)`r`n            ProbeShortcutSaved(""keys"")`r`n        }")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '            SaveShortcutItemAssignments(itemState.ProfileId,itemState.Ids[first.Value],itemState.Ids[second.Value])' ('            SaveShortcutItemAssignments(itemState.ProfileId,itemState.Ids[first.Value],itemState.Ids[second.Value])' + "`r`n            ProbeShortcutSaved(""items"")")
$tests=@'
OnExit(StopBrowserWorker)
global UiChecks := 0, ProbeListArmed := false, ProbeViewportArmed := false, InputCalls := 0
global ProbeViewportRegistrationFailure := true, ProbeRegisteredViewport := 0, DeletedRegisteredViewports := 0
registrationView := Gui(,"viewport registration fixture")
failed := false
try RegisteredViewportProbe(registrationView,160,120)
catch as failure {
    failed := failure.Message == "fixture viewport registration failure"
    if !failed
        throw failure
}
CheckUi(failed && ProbeRegisteredViewport.Disposed,"partial viewport registration is disposed before publication")
ProbeRegisteredViewport := 0
CheckUi(DeletedRegisteredViewports=1,"failed viewport releases registered GUI and message callbacks")
CheckUi(DllCall("IsWindow","Ptr",registrationView.Hwnd),"failed viewport registration leaves the host window owned by its caller")
ProbeViewportRegistrationFailure := false
registered := RegisteredViewportProbe(registrationView,160,120)
registered.Dispose(), registered := 0
CheckUi(DeletedRegisteredViewports=2,"viewport registration can be retried on the same window and released")
registrationView.Destroy()
global ProbeInfoFailure := "", ProbeInfoHwnd := 0
for open in [Help,ShowReactionDetails] {
    for point in ["build","show"] {
        ProbeInfoFailure := point, ProbeInfoHwnd := 0, failed := false
        try open.Call()
        catch as failure
            failed := failure.Message == "fixture info " point " failure"
        CheckUi(failed,"informational dialog preserves the failure: " open.Name "/" point)
        CheckUi(ProbeInfoHwnd && !DllCall("IsWindow","Ptr",ProbeInfoHwnd),"failed informational dialog is destroyed: " open.Name "/" point)
        ProbeInfoFailure := ""
        open.Call()
        shown := WinExist("A")
        CheckUi(IsAppWindow(shown) && shown != PaletteWindow.Hwnd,"informational dialog can be retried: " open.Name "/" point)
        WinClose("ahk_id " shown)
        CheckUi(WinWaitClose("ahk_id " shown,,2),"informational dialog close releases its window: " open.Name "/" point)
    }
}
AutoMode := false
ReactionExecutionStatus := {Phase:"finished",Message:"fixture"}
global ProbeOverlayFailure := true, ProbeOverlayHwnd := 0
failed := false
try ShowReactionProgress()
catch
    failed := true
CheckUi(failed && !ReactionOverlay,"failed construction publishes nothing")
CheckUi(!DllCall("IsWindow","Ptr",ProbeOverlayHwnd),"failed construction destroys its unpublished window")
ShowReactionProgress()
CheckUi(ReactionOverlay && IsObject(ReactionOverlay.Text) && IsObject(ReactionOverlay.Hint) && IsObject(ReactionOverlay.Stop),"retry publishes completed controls")
ReactionOverlay.Window.Hide()
ExecuteDanmakuCommand("add","","",{Name:"first",Text:"same",Slot:0})
RefreshPaletteItems()
global ProbeListFailure := true
failed := false
try RefreshPaletteItems()
catch
    failed := true
CheckUi(failed && !PaletteRefresh.Active && PaletteRows.Length=0 && PaletteList.GetCount()=0,"failed native update clears incomplete view and unlocks retry")
RefreshPaletteItems()
CheckUi(PaletteRows.Length=1,"list rebuild recovers after failure")
oldRows := PaletteRows
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second",Slot:0})
ProbeListArmed := true
RefreshPaletteItems()
CheckUi(!ProbeListArmed && PaletteRows.Length=2 && PaletteList.GetCount()=2,"list publishes complete snapshot")
CheckUi(!PaletteRefresh.Active && InputCalls=0,"update restores interaction without sending")
old := SharedDanmakuItems[1]
SharedDanmakuItems[1] := old.Clone()
SharedDanmakuItems[1].Id := NewRecordId()
PaletteList.Modify(1,"Select Focus")
InsertPaletteItem()
CheckUi(InputCalls=0 && PaletteRows[1].ItemId=SharedDanmakuItems[1].Id,"same text with changed identity is refreshed rather than sent")
PaletteRows := []
InsertPaletteItem()
CheckUi(InputCalls=0,"stale index is rejected")
SharedDanmakuItems[1] := old
RefreshPaletteItems()
BuildManagement()
global ProbeShortcutFailure := true
shortcutCritical := A_IsCritical
failed := false
try ShowShortcutManager()
catch as failure
    failed := failure.Message == "fixture shortcut presentation failure"
CheckUi(failed && !ActiveEditorDialog,"failed shortcut presentation releases editor ownership")
CheckUi(A_IsCritical=shortcutCritical,"failed shortcut presentation restores the original interrupt policy")
CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"failed shortcut presentation restores parent windows")
ProbeShortcutFailure := false
shortcutPanel := ShowShortcutManager()
CheckUi(IsObject(shortcutPanel) && ActiveEditorDialog,"shortcut presentation can be retried")
CheckUi(A_IsCritical=shortcutCritical,"item initialization does not overwrite the editor interrupt policy")
shortcutPanel.Close.Call()
for managerEnabled in [true,false] {
    ManagementWindow.Opt(managerEnabled ? "-Disabled" : "+Disabled")
    closingPanel := ShowShortcutManager()
    closingHwnd := closingPanel.Window.Hwnd
    closingPanel.Viewport.DefineProp("Dispose",{Call:FailEditorViewportDispose})
    failed := false, closeCritical := A_IsCritical
    try {
        try closingPanel.Close.Call()
        catch as failure
            failed := failure.Message == "fixture editor viewport disposal failure"
        CheckUi(failed && A_IsCritical=closeCritical,"editor cleanup preserves failure and interrupt policy")
        CheckUi(closingPanel.Viewport.Disposed && !ActiveEditorDialog,"viewport disposal failure still releases editor ownership")
        CheckUi(!DllCall("IsWindow","Ptr",closingHwnd),"viewport disposal failure still destroys editor window")
        CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)
            && !!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=managerEnabled,"failed editor cleanup restores only its own parent locks")
    } finally {
        closingPanel.Viewport.DeleteProp("Dispose")
        if ActiveEditorDialog && ActiveEditorDialog.Window=closingPanel.Window
            closingPanel.Close.Call()
        ManagementWindow.Opt("-Disabled")
    }
}
itemProfile := ExecuteProfileCommand("add","","item publication fixture").ProfileId
ExecuteDanmakuCommand("add",itemProfile,"",{Name:"first",Text:"profile first",Slot:0})
ExecuteDanmakuCommand("add",itemProfile,"",{Name:"second",Text:"profile second",Slot:0})
global ProbeItemPanel := ShowShortcutManager(), ProbeItemFailure := true, ProbeItemHistory := LibraryHistory.Length
ProbeItemPanel.Scope.Choose(2)
ProbeItemPanel.ChangeScope.Call()
failed := InStr(ProbeItemPanel.ItemStatus.Text,"fixture item choices failure")
CheckUi(A_IsCritical=shortcutCritical,"failed item refresh restores the original interrupt policy")
CheckUi(failed && !ProbeItemPanel.ItemsSaveButton.Enabled && !ProbeItemPanel.First.Enabled && !ProbeItemPanel.Second.Enabled,"partial item choices cannot be edited or saved")
ProbeItemPanel.UpdateItems.Call(), ProbeItemPanel.SaveItems.Call()
CheckUi(LibraryHistory.Length=ProbeItemHistory && !ProbeItemPanel.ItemsSaveButton.Enabled,"incomplete item snapshot remains unsaveable after callbacks")
saved := LoadSettings(SettingsDatabasePath)
CheckUi(GetLibraryItems(saved,itemProfile)[1].Slot=0 && GetLibraryItems(saved,itemProfile)[2].Slot=0,"failed item rendering preserves stored assignments")
ProbeItemFailure := false
ProbeItemPanel.RefreshItems.Call()
CheckUi(ProbeItemPanel.First.Enabled && ProbeItemPanel.Second.Enabled && !ProbeItemPanel.ItemsSaveButton.Enabled,"retry publishes both completed item choices")
ProbeItemPanel.First.Choose(2), ProbeItemPanel.Second.Choose(3), ProbeItemPanel.UpdateItems.Call(), ProbeItemPanel.SaveItems.Call()
saved := LoadSettings(SettingsDatabasePath)
CheckUi(GetLibraryItems(saved,itemProfile)[1].Slot=1 && GetLibraryItems(saved,itemProfile)[2].Slot=2,"retried item choices save the two displayed assignments")
ProbeItemPanel.Close.Call(), ProbeItemPanel := 0
ExecuteProfileCommand("delete",itemProfile)
global ProbeEditorConstructionFailure := true, ProbeEditorConstructionHwnd := 0
beforeCritical := A_IsCritical
failed := false
try OpenDanmakuEditor(true)
catch as failure
    failed := failure.Message == "fixture editor construction failure"
CheckUi(failed && ProbeEditorConstructionHwnd && !DllCall("IsWindow","Ptr",ProbeEditorConstructionHwnd),"failed editor construction destroys the unpublished native window")
CheckUi(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"failed editor construction leaves no owner and keeps parents enabled")
CheckUi(A_IsCritical=beforeCritical,"failed editor construction restores interrupt policy")
ProbeEditorConstructionFailure := false
global ProbeEditorFailure := true
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=ManagementWindow.Hwnd
RuntimePorts.ResolveChannel := (hwnd) => {State:"ok",Author:"fixture",Channel:"/channel/fixture",Video:"abcdefghijk"}
RuntimePorts.BrowserRequest := (hwnd,mode,video,extra) => {State:"not_registered"}
TargetBrowserHwnd := ManagementWindow.Hwnd
ProbeEditorFailure := false
global ProbeEditorBuildFailure := false, ProbeBuiltEditorHwnd := 0, ProbeBuiltViewport := 0
for openEditor in [TransferItem,OpenChannelLinkDialog,ShowShortcutManager] {
    ManagedList.Modify(1,"Select Focus")
    ProbeEditorBuildFailure := true, ProbeBuiltEditorHwnd := 0, ProbeBuiltViewport := 0
    beforeCritical := A_IsCritical
    failed := false
    try openEditor.Call()
    catch as failure {
        failed := failure.Message == "fixture editor build failure"
        if !failed
            throw failure
    }
    CheckUi(failed && ProbeBuiltEditorHwnd && !DllCall("IsWindow","Ptr",ProbeBuiltEditorHwnd),"partial editor construction releases native window: " openEditor.Name)
    CheckUi(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"partial construction preserves parent state: " openEditor.Name)
    CheckUi(A_IsCritical=beforeCritical,"failed editor build restores interrupt policy: " openEditor.Name)
    if ProbeBuiltViewport
        CheckUi(ProbeBuiltViewport.Disposed,"failed shortcut construction disposes scrolling resources")
    ProbeEditorBuildFailure := false
    openEditor.Call()
    retryHwnd := ActiveEditorDialog.Window.Hwnd
    CheckUi(DllCall("IsWindowVisible","Ptr",retryHwnd),"editor can be retried after failed construction: " openEditor.Name)
    WinClose("ahk_id " retryHwnd)
    CheckUi(WinWaitClose("ahk_id " retryHwnd,,2) && !ActiveEditorDialog,"retried editor closes normally: " openEditor.Name)
}
ProbeEditorFailure := true
for openEditor in [() => OpenDanmakuEditor(true),TransferItem,OpenChannelLinkDialog] {
    ManagedList.Modify(1,"Select Focus")
    failed := false
    try openEditor.Call()
    catch as failure {
        failed := failure.Message == "fixture editor presentation failure"
        if !failed
            throw failure
    }
    CheckUi(failed && !ActiveEditorDialog,"editor presentation failure releases ownership")
    CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"editor presentation failure restores parents")
}
ProbeEditorFailure := false
global ProbeEditorBeginFailure := false
for openEditor in [() => OpenDanmakuEditor(true),TransferItem,OpenChannelLinkDialog,ShowShortcutManager,() => ManageProfile("unbind")] {
    ManagedList.Modify(1,"Select Focus")
    ProbeEditorBeginFailure := true
    failed := false
    try openEditor.Call()
    catch as failure
        failed := failure.Message == "fixture editor begin failure"
    CheckUi(failed && !ActiveEditorDialog,"editor begin failure releases ownership and draft window")
    CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"editor begin failure restores parent windows")
}
RuntimePorts.BrowserIdentity := 0, RuntimePorts.ResolveChannel := 0, RuntimePorts.BrowserRequest := 0
TargetBrowserHwnd := 0
global ProbeManagementArmed := true
RefreshManagement()
CheckUi(!ProbeManagementArmed && !ManagementRefresh.Active && !ActiveEditorDialog,"management defers nested refresh and blocks editing")
CheckUi(SharedDanmakuItems.Length=2 && ManagedList.GetCount()=2,"management refresh cannot delete or undo data")
PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
ProbeViewportArmed := true
PaletteViewport.SetOffset(0,0)
CheckUi(!ProbeViewportArmed && PaletteViewport.PendingResize && IsObject(PaletteViewport.PendingOffset),"nested updates are queued")
PaletteViewport.FlushUpdates()
CheckUi(!PaletteViewport.Updating && !PaletteViewport.PendingResize && !PaletteViewport.PendingOffset,"queued updates drain")
previousCritical := A_IsCritical
Critical("On")
try {
    ProbeViewportArmed := true
    PaletteViewport.SetOffset(0,0)
    PaletteViewport.SetOffset(30,40)
    PaletteViewport.FlushUpdates()
    CheckUi(PaletteViewport.X=30 && PaletteViewport.Y=40,"new scrolling supersedes an older queued position")
    PaletteViewport.Updating := true
    PaletteViewport.Resize()
    PaletteViewport.SetOffset(30,40)
    PaletteViewport.Updating := false
    ProbeViewportArmed := true
    PaletteViewport.FlushUpdates()
    CheckUi(PaletteViewport.X=10 && PaletteViewport.Y=20,"scrolling requested during layout supersedes the earlier queued position")
    PaletteViewport.FlushUpdates()
    CheckUi(!PaletteViewport.PendingResize && !PaletteViewport.PendingOffset,"reentrant layout requests finish without replaying old positions")
} finally Critical(previousCritical)
PaletteViewport.Updating := true
PaletteViewport.SetOffset(10,20)
PaletteViewport.SetOffset(20,30)
CheckUi(PaletteViewport.PendingOffset.X=20 && PaletteViewport.PendingOffset.Y=30,"latest pending offset wins")
PaletteViewport.Updating := false
PaletteViewport.Dispose()
PaletteViewport.FlushUpdates()
CheckUi(!PaletteViewport.PendingOffset && !PaletteViewport.PendingResize,"disposed viewport drops pending work")
destination := ExecuteProfileCommand("add","","destination").ProfileId
EditingProfileId := ""
RefreshManagement()
for action in ["duplicate","up","down","edit","transfer","delete"] {
    selected := action="up" ? 2 : 1
    ManagedList.Modify(0,"-Select")
    ManagedList.Modify(selected,"Select Focus")
    movedId := SharedDanmakuItems[selected].Id
    TransferItem()
    global ProbeAfterSaveFailure := true
    ProbeCommitAction.Call()
    CheckUi(!ActiveEditorDialog && InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"管理画面：fixture post-save refresh failure"),"move closes committed editor and reports failed refresh: " action)
    CheckUi(PaletteRows.Length=1 && PaletteRows[1].ItemId=SharedDanmakuItems[1].Id,"management refresh failure does not prevent palette update: " action)
    saved := LoadSettings(SettingsDatabasePath)
    CheckUi(GetLibraryItems(saved,destination).Length=1 && GetLibraryItems(saved,destination)[1].Id=movedId,"move remains saved after refresh failure: " action)
    ProbeAfterSaveFailure := false
    remainingId := SharedDanmakuItems[1].Id, historyBefore := LibraryHistory.Length
    CheckUi(ManagedList.GetText(selected,4)=movedId,"failed refresh leaves the moved item displayed: " action)
    if action="edit"
        OpenDanmakuEditor(false)
    else if action="transfer"
        TransferItem()
    else
        HandleDanmakuCommand(action)
    CheckUi(!ActiveEditorDialog,"stale selection cannot open an editor for another item: " action)
    CheckUi(SharedDanmakuItems.Length=1 && SharedDanmakuItems[1].Id=remainingId && LibraryHistory.Length=historyBefore,"stale selection preserves library and history: " action)
    saved := LoadSettings(SettingsDatabasePath)
    CheckUi(saved.SharedDanmakuItems.Length=1 && saved.SharedDanmakuItems[1].Id=remainingId && GetLibraryItems(saved,destination).Length=1 && GetLibraryItems(saved,destination)[1].Id=movedId,"stale selection cannot change saved items: " action)
    CheckUi(ManagedList.GetCount()=1 && ManagedList.GetText(1,4)=remainingId && !ManagedList.GetNext() && InStr(ManagementStatus.Text,"選び直してください"),"stale selection refreshes the view and requires a new selection: " action)
    HandleDanmakuCommand("delete")
    CheckUi(SharedDanmakuItems.Length=1 && LibraryHistory.Length=historyBefore,"repeated action without selection cannot delete an item: " action)
    if action!="delete"
        UndoLibraryCommand()
    RefreshManagement()
}
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=ManagementWindow.Hwnd
RuntimePorts.ResolveChannel := (hwnd) => {State:"ok",Author:"new channel",Channel:"/channel/new",Video:"abcdefghijk"}
RuntimePorts.BrowserRequest := (hwnd,mode,video,extra) => {State:"not_registered"}
TargetBrowserHwnd := ManagementWindow.Hwnd
beforeProfiles := Profiles.Length
OpenChannelLinkDialog()
ProbeAfterSaveFailure := true
ProbeCommitAction.Call()
CheckUi(!ActiveEditorDialog && InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"管理画面：fixture post-save refresh failure"),"channel link closes committed editor and reports failed refresh")
saved := LoadSettings(SettingsDatabasePath)
CheckUi(saved.Profiles.Length=beforeProfiles+1 && saved.Profiles[-1].Channel="/channel/new","channel link remains saved after refresh failure")
ProbeAfterSaveFailure := false
RuntimePorts.ShortcutKey := (action,key,enabled) => 0
EditingProfileId := ""
RefreshManagement()
PaletteWindow.Show("NA")
panel := ShowShortcutManager("chat_focus")
panel.Stage.Call("^+j")
global ProbeShortcutRefreshFailure := true
panel.Save.Call()
CheckUi(!panel.SaveButton.Enabled && InStr(panel.Status.Text,"保存済み"),"key save remains committed when external refresh fails")
CheckUi(LoadSettings(SettingsDatabasePath).ShortcutKeys["chat_focus"]="^+j","key persisted despite refresh failure")
panel.First.Choose(2), panel.UpdateItems.Call()
panel.SaveItems.Call()
CheckUi(!panel.ItemsSaveButton.Enabled && InStr(panel.ItemStatus.Text,"保存済み"),"item save baseline advances before external refresh")
CheckUi(LoadSettings(SettingsDatabasePath).SharedDanmakuItems[1].Slot=1,"item assignment persisted despite refresh failure")
CheckUi(ManagedList.GetText(1,3)=StrReplace(ShortcutKeyLabel(GetShortcutKey("shared1")),"＋","+"),"palette refresh failure does not prevent management from showing the saved assignment")
RuntimePorts.ConfirmDiscard := (*) => false
panel.Close.Call()
CheckUi(!ActiveEditorDialog,"committed drafts close without discard confirmation")
ManagedList.Modify(1,"Select Focus")
historyBefore := LibraryHistory.Length
HandleDanmakuCommand("duplicate")
CheckUi(SharedDanmakuItems.Length=2 && LibraryHistory.Length=historyBefore+1 && LoadSettings(SettingsDatabasePath).SharedDanmakuItems.Length=2,"duplicate commits once despite palette failure")
CheckUi(ManagedList.GetCount()=2 && ManagedList.GetText(ManagedList.GetNext(),4)=SharedDanmakuItems[2].Id,"saved duplicate is selected despite palette failure")
CheckUi(InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"パレット：fixture shortcut refresh failure"),"management reports saved duplicate and failed palette update")
ProbeAfterSaveFailure := true
UndoLibraryChange()
CheckUi(SharedDanmakuItems.Length=1 && LibraryHistory.Length=historyBefore && LoadSettings(SettingsDatabasePath).SharedDanmakuItems.Length=1,"undo remains committed when both views fail")
CheckUi(InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"パレット：fixture shortcut refresh failure") && InStr(ManagementStatus.Text,"管理画面：fixture post-save refresh failure"),"both view failures remain available in saved notice")
ProbeAfterSaveFailure := false, ProbeShortcutRefreshFailure := false
RefreshLibraryViews()
CheckUi(ManagedList.GetCount()=1 && PaletteRows.Length=1,"views recover from committed state without replaying the command")
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
global ProbeWaitFailure := false
for managerEnabled in [true,false] {
    ManagementWindow.Opt(managerEnabled ? "-Disabled" : "+Disabled")
    ProbeWaitFailure := true
    failed := false
    try NativeRequestBrowserOperation(123,"browser_context")
    catch as failure
        failed := failure.Message == "fixture wait preparation failure"
    CheckUi(failed && !IsBrowserOperationBusy,"failed wait preparation releases operation ownership")
    CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=managerEnabled,"failed wait preparation restores prior parent enabled state")
}
ManagementWindow.Opt("-Disabled")
; A later edit cannot become the comparison baseline for an earlier save.
global ProbeSavedPanel := 0, ProbeSavedMode := "", ProbeSavedArmed := false, ProbeLateEditRuns := 0
for mode in ["items","keys"] {
    SaveShortcutItemAssignments("",SharedDanmakuItems[1].Id,"")
    ProbeSavedPanel := ShowShortcutManager("chat_focus")
    ProbeSavedMode := mode, ProbeSavedArmed := true, ProbeLateEditRuns := 0
    savedCritical := A_IsCritical, savedDiscard := RuntimePorts.ConfirmDiscard
    try {
        if mode="items" {
            ProbeSavedPanel.First.Choose(1), ProbeSavedPanel.UpdateItems.Call()
            ProbeSavedPanel.SaveItems.Call()
        } else {
            ProbeSavedPanel.Stage.Call("^+F11")
            ProbeSavedPanel.Save.Call()
        }
        CheckUi(A_IsCritical=savedCritical,"shortcut save restores caller interrupt setting: " mode)
        deadline := A_TickCount+1000
        while !ProbeLateEditRuns && A_TickCount<deadline
            Sleep(10)
        CheckUi(!ProbeSavedArmed && ProbeLateEditRuns=1,"later shortcut edit actually reaches the save boundary: " mode)
        persisted := LoadSettings(SettingsDatabasePath)
        if mode="items" {
            CheckUi(persisted.SharedDanmakuItems[1].Slot=0,"item save persists the submitted choice only")
            CheckUi(ProbeSavedPanel.First.Value=2 && ProbeSavedPanel.ItemsSaveButton.Enabled,
                "later item choice remains visible and unsaved")
        } else {
            CheckUi(persisted.ShortcutKeys["chat_focus"]=="^+F11","key save persists the submitted key only")
            CheckUi(ProbeSavedPanel.SaveButton.Enabled && ProbeSavedPanel.List.GetText(ProbeSavedPanel.List.GetNext(),2)=ShortcutKeyLabel("^+F12"),
                "later key draft remains visible and unsaved")
        }
    } finally {
        ProbeSavedArmed := false
        SetTimer(ProbeShortcutLateEdit,0)
        RuntimePorts.ConfirmDiscard := (*) => true
        try ProbeSavedPanel.Close.Call()
        finally RuntimePorts.ConfirmDiscard := savedDiscard
    }
}
priorEditor := Gui(), currentEditor := Gui()
BeginEditorDialog(priorEditor,"prior fixture")
EndEditorDialog(priorEditor)
BeginEditorDialog(currentEditor,"current fixture")
EndEditorDialog(priorEditor)
CheckUi(ActiveEditorDialog && ActiveEditorDialog.Window=currentEditor,"stale editor cannot release current ownership")
CheckUi(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"stale close keeps current editor parents disabled")
EndEditorDialog(currentEditor)
CheckUi(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"owning editor restores parents")
priorEditor.Destroy(), currentEditor.Destroy()
FileAppend("PASS: " UiChecks " UI publication and reentry checks; no browser operations`n","*")
ExitApp()
CheckUi(value,label) {
    global UiChecks
    if !value
        throw Error(label)
    UiChecks++
}
FailEditorViewportDispose(viewport,*) {
    PanelViewport.Prototype.Dispose.Call(viewport)
    throw Error("fixture editor viewport disposal failure")
}
class RegisteredViewportProbe extends PanelViewport {
    __Delete() {
        global DeletedRegisteredViewports
        DeletedRegisteredViewports++
    }
}
ProbeInfoDialogBuild(view) {
    global ProbeInfoHwnd
    if !IsSet(ProbeInfoFailure) || ProbeInfoFailure = ""
        return
    ProbeInfoHwnd := view.Hwnd
    if ProbeInfoFailure = "build"
        throw Error("fixture info build failure")
}
ProbeViewportRegistration(viewport) {
    global ProbeRegisteredViewport
    if IsSet(ProbeViewportRegistrationFailure) && ProbeViewportRegistrationFailure {
        ProbeRegisteredViewport := viewport
        throw Error("fixture viewport registration failure")
    }
}
ProbeShortcutSaved(mode) {
    global ProbeSavedArmed
    if !IsSet(ProbeSavedArmed) || !ProbeSavedArmed || mode!=ProbeSavedMode
        return
    ProbeSavedArmed := false
    SetTimer(ProbeShortcutLateEdit,-1)
    Sleep(40)
}
ProbeShortcutLateEdit(*) {
    global ProbeLateEditRuns
    ProbeLateEditRuns++
    if ProbeSavedMode="items" {
        ProbeSavedPanel.First.Choose(2)
        ProbeSavedPanel.UpdateItems.Call()
    } else
        ProbeSavedPanel.Stage.Call("^+F12")
}
ProbeEditorBuild(view, viewport := 0) {
    global ProbeBuiltEditorHwnd, ProbeBuiltViewport
    if IsSet(ProbeEditorBuildFailure) && ProbeEditorBuildFailure {
        ProbeBuiltEditorHwnd := view.Hwnd, ProbeBuiltViewport := viewport
        throw Error("fixture editor build failure")
    }
}
ProbeShortcutItems(index) {
    if !IsSet(ProbeItemFailure) || !ProbeItemFailure || index != 1
        return
    ProbeItemPanel.First.Choose(2)
    ProbeItemPanel.UpdateItems.Call(), ProbeItemPanel.SaveItems.Call()
    CheckUi(LibraryHistory.Length=ProbeItemHistory && !ProbeItemPanel.ItemsSaveButton.Enabled,"item save is blocked before both dropdowns are complete")
    throw Error("fixture item choices failure")
}
ProbeOverlayConstruction(view) {
    global ProbeOverlayFailure, ProbeOverlayHwnd
    ProbeOverlayHwnd := view.Hwnd
    if IsSet(ProbeOverlayFailure) && ProbeOverlayFailure {
        ProbeOverlayFailure := false
        throw Error("fixture construction failure")
    }
    CheckUi(!ReactionOverlay,"incomplete overlay not published")
    RenderReactionStatus()
    ShowReactionProgress()
    CheckUi(!ReactionOverlay,"nested show cannot publish incomplete overlay")
}
ProbeListUpdate() {
    global ProbeListFailure
    if IsSet(ProbeListFailure) && ProbeListFailure {
        ProbeListFailure := false
        throw Error("fixture list update failure")
    }
    global ProbeListArmed
    if !IsSet(ProbeListArmed) || !ProbeListArmed
        return
    ProbeListArmed := false
    CheckUi(PaletteRefresh.Active,"list updating state precedes native mutation")
    PaletteList.Modify(1,"Select Focus")
    InsertPaletteItem()
    OpenPaletteLibrary()
    PreviewPaletteItem()
    RefreshPaletteItems()
    CheckUi(PaletteRows.Length=1 && PaletteRefresh.Pending,"old snapshot retained until publish; nested refresh deferred")
}
ProbeManagementUpdate() {
    global ProbeManagementArmed
    if !IsSet(ProbeManagementArmed) || !ProbeManagementArmed
        return
    ProbeManagementArmed := false
    CheckUi(ManagementRefresh.Active,"management owns update guard")
    SelectManagedRow(1)
    HandleDanmakuCommand("delete")
    OpenDanmakuEditor(true)
    UndoLibraryChange()
    RefreshManagement()
    CheckUi(ManagementRefresh.Pending,"nested management refresh coalesces")
}
ProbeViewport(viewport) {
    global ProbeViewportArmed
    if !IsSet(ProbeViewportArmed) || !ProbeViewportArmed
        return
    ProbeViewportArmed := false
    CheckUi(viewport.Updating,"scrolling owns update guard")
    viewport.Resize()
    viewport.SetOffset(10,20)
}
RequestDanmakuInput(*) {
    global InputCalls
    InputCalls++
}
'@
Invoke-AppTest -Runtime $release -Body $tests

# Parent-window restoration is shared by browser waits and modal editing.
$windowRuntime=New-TestRuntime
$windowTests=@'
BuildManagement()
global WindowChecks := 0, WindowFaults := Map(), WindowReplacement := 0
global WindowInterleaveArmed := false, WindowInterleaveRuns := 0, WindowInterleaveEditor := 0
PaletteWindow.DefineProp("Opt",{Call:WindowOpt})
ManagementWindow.DefineProp("Opt",{Call:WindowOpt})
for flow in ["wait","editor"] {
    for failedWindow in ["palette","manager","both"] {
        WindowFaults := Map()
        if failedWindow!="manager"
            WindowFaults[PaletteWindow] := "palette restore failure"
        if failedWindow!="palette"
            WindowFaults[ManagementWindow] := "manager restore failure"
        errorMessage := "", priorInterrupt := A_IsCritical
        try ExerciseWindowSuspension(flow)
        catch as failure
            errorMessage := failure.Message
        label := flow "/" failedWindow
        CheckWindows(A_IsCritical=priorInterrupt,"failed parent restoration keeps caller interrupt setting: " label)
        for window, detail in WindowFaults
            CheckWindows(InStr(errorMessage,detail),"restore failure remains visible: " label "/" detail)
        CheckWindows(!IsBrowserOperationBusy && !ActiveEditorDialog,"failed restore releases the operation: " label)
        CheckWindows(!!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)=(failedWindow="manager"),"palette restoration is attempted independently: " label)
        CheckWindows(!!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=(failedWindow="palette"),"management restoration is attempted independently: " label)
        CheckWindows(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"operation controls refresh despite parent restore failure: " label)
        WindowFaults.Clear()
        PaletteWindow.Opt("-Disabled"), ManagementWindow.Opt("-Disabled")
    }
    for paletteEnabled in [true,false] {
        for managerEnabled in [true,false] {
            PaletteWindow.Opt(paletteEnabled ? "-Disabled" : "+Disabled")
            ManagementWindow.Opt(managerEnabled ? "-Disabled" : "+Disabled")
            ExerciseWindowSuspension(flow)
            CheckWindows(!!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)=paletteEnabled
                && !!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=managerEnabled,"original enabled states survive: " flow "/" paletteEnabled "/" managerEnabled)
        }
    }
    PaletteWindow.Opt("-Disabled"), ManagementWindow.Opt("-Disabled")
    originalManager := ManagementWindow
    WindowReplacement := Gui(), WindowReplacement.Opt("+Disabled")
    try {
        ExerciseWindowSuspension(flow)
        CheckWindows(DllCall("IsWindowEnabled","Ptr",originalManager.Hwnd),"restore belongs to the originally suspended window: " flow)
        CheckWindows(!DllCall("IsWindowEnabled","Ptr",WindowReplacement.Hwnd),"replacement window keeps its own disabled state: " flow)
    } finally {
        ManagementWindow := originalManager
        WindowReplacement.Destroy(), WindowReplacement := 0
        originalManager.Opt("-Disabled")
    }
}
editor := Gui()
try {
    BeginEditorDialog(editor,"nested wait fixture")
    NativeRequestBrowserOperation(123,"browser_context")
    CheckWindows(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"browser wait preserves the editor's parent locks")
} finally {
    EndEditorDialog(editor)
    editor.Destroy()
}
CheckWindows(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"outer editor restores both parents after the nested wait")
; A queued editor must see both restored parents, never the first half of cleanup.
for flow in ["wait","editor"] {
    for callerCritical in [0,23] {
        WindowInterleaveArmed := true, WindowInterleaveRuns := 0
        label := flow "/" callerCritical
        try {
            Critical(callerCritical)
            ExerciseWindowSuspension(flow)
            CheckWindows(A_IsCritical=callerCritical,"parent cleanup restores caller interrupt setting: " label)
            Critical("Off")
            deadline := A_TickCount+1000
            while !WindowInterleaveRuns && A_TickCount<deadline
                Sleep(10)
            CheckWindows(!WindowInterleaveArmed && WindowInterleaveRuns=1 && WindowInterleaveEditor && ActiveEditorDialog,
                "queued editor enters exactly once after parent cleanup: " label)
            CheckWindows(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),
                "parent cleanup cannot enable a new editor's parents: " label)
        } finally {
            Critical("Off")
            WindowInterleaveArmed := false
            SetTimer(OpenWindowInterleaveEditor,0)
            if WindowInterleaveEditor {
                try EndEditorDialog(WindowInterleaveEditor)
                finally WindowInterleaveEditor.Destroy(), WindowInterleaveEditor := 0
            }
        }
        CheckWindows(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),
            "new editor captures and restores both parents after parent cleanup: " label)
    }
}
PaletteWindow.DeleteProp("Opt"), ManagementWindow.DeleteProp("Opt")
FileAppend("PASS: " WindowChecks " parent-window suspension checks; no real browser operations`n","*")
ExitApp()
CheckWindows(value,label) {
    global WindowChecks
    if !value
        throw Error(label)
    WindowChecks++
}
WindowOpt(window,options) {
    global WindowInterleaveArmed
    if options="-Disabled" && WindowFaults.Has(window)
        throw Error(WindowFaults[window])
    result := Gui.Prototype.Opt.Call(window,options)
    if options="-Disabled" && WindowInterleaveArmed {
        WindowInterleaveArmed := false
        SetTimer(OpenWindowInterleaveEditor,-1)
        Sleep(40)
    }
    return result
}
OpenWindowInterleaveEditor(*) {
    global WindowInterleaveRuns, WindowInterleaveEditor
    WindowInterleaveRuns++
    if !OperationAllowed("edit")
        return
    WindowInterleaveEditor := Gui()
    BeginEditorDialog(WindowInterleaveEditor,"queued editor fixture")
}
ExerciseWindowSuspension(flow) {
    if flow="wait"
        NativeRequestBrowserOperation(123,"browser_context")
    else {
        editor := Gui()
        try {
            BeginEditorDialog(editor,"window suspension fixture")
            ReplaceSuspendedWindow()
        } finally {
            try EndEditorDialog(editor)
            finally editor.Destroy()
        }
    }
}
ReplaceSuspendedWindow() {
    global ManagementWindow
    if WindowReplacement
        ManagementWindow := WindowReplacement
}
WindowRequest(hwnd,mode,video,extra) {
    ReplaceSuspendedWindow()
    return {State:"ok",Video:"abcdefghijk"}
}
'@
Invoke-AppTest -Runtime $windowRuntime -Body $windowTests -Setup @'
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.WorkerRequest := WindowRequest
'@
