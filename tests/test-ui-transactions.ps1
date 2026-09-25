# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
function Rewrite($relative,$before,$after) {
 $p=Join-Path $release $relative
 $s=[IO.File]::ReadAllText($p)
 if(!$s.Contains($before)){throw "Missing injection: $relative"}
 [IO.File]::WriteAllText($p,$s.Replace($before,$after),[Text.UTF8Encoding]::new($true))
}
Rewrite 'src/ui/reaction_feedback.ahk' '            text := view.AddText("w360 r6", "")' ('            text := view.AddText("w360 r6", "")'+"`r`n            ProbeOverlayConstruction()")
Rewrite 'src/ui/palette/palette_view.ahk' '            for row in rows' '            for row in rows {'
Rewrite 'src/ui/palette/palette_view.ahk' '                PaletteList.Add("",row.Shared ? "共通" : "配信者",row.Label,row.Key,row.ItemId)' ('                PaletteList.Add("",row.Shared ? "共通" : "配信者",row.Label,row.Key,row.ItemId)'+"`r`n                ProbeListUpdate()`r`n            }")
Rewrite 'src/ui/panel_viewport.ahk' '    ApplyOffset(x, y) {' ("    ApplyOffset(x, y) {`r`n        ProbeViewport(this)")
Rewrite 'src/input/input_controller.ahk' 'RequestDanmakuInput(request) {' 'OriginalRequestDanmakuInput(request) {'
Rewrite 'src/ui/management/management_view.ahk' '        for row in model.Rows' '        for row in model.Rows {'
Rewrite 'src/ui/management/management_view.ahk' '        ManagedList.ModifyCol(1,160)' ("            ProbeManagementUpdate()`r`n        }`r`n        ManagedList.ModifyCol(1,160)")
Rewrite 'src/ui/shortcut_manager.ahk' '        panel.Viewport.Show()' ("        if IsSet(ProbeShortcutFailure) && ProbeShortcutFailure`r`n            throw Error(""fixture shortcut presentation failure"")`r`n        panel.Viewport.Show()")
Rewrite 'src/ui/window_presenter.ahk' 'PresentWindow(view, options := "", layout := 0, activate := true) {' ('PresentWindow(view, options := "", layout := 0, activate := true) {' + "`r`n    if IsSet(ProbeEditorFailure) && ProbeEditorFailure && ActiveEditorDialog && ActiveEditorDialog.Window = view`r`n        throw Error(""fixture editor presentation failure"")")
Rewrite 'src/ui/management/management_dialogs.ahk' '    moveButton.OnEvent("Click",Move)' ('    moveButton.OnEvent("Click",Move)' + "`r`n    global ProbeCommitAction := Move")
Rewrite 'src/ui/management/management_dialogs.ahk' '    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)' ('    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)' + "`r`n    global ProbeCommitAction := Save")
Rewrite 'src/ui/management/management_controller.ahk' 'RefreshManagementAfterCommand(editId) {' ('RefreshManagementAfterCommand(editId) {' + "`r`n    if IsSet(ProbeAfterSaveFailure) && ProbeAfterSaveFailure`r`n        throw Error(""fixture post-save refresh failure"")")
Rewrite 'src/ui/palette/palette_view.ahk' 'RefreshPalette() {' ('RefreshPalette() {' + "`r`n    if IsSet(ProbeShortcutRefreshFailure) && ProbeShortcutRefreshFailure`r`n        throw Error(""fixture shortcut refresh failure"")")
Rewrite 'src/ui/ui_runtime.ahk' 'RefreshOperationControls() {' ('RefreshOperationControls() {' + "`r`n    global ProbeWaitFailure`r`n    if IsSet(ProbeWaitFailure) && ProbeWaitFailure && IsBrowserOperationBusy {`r`n        ProbeWaitFailure := false`r`n        throw Error(""fixture wait preparation failure"")`r`n    }")
Rewrite 'src/ui/ui_runtime.ahk' 'RefreshOperationControls() {' ('RefreshOperationControls() {' + "`r`n    global ProbeEditorBeginFailure`r`n    if IsSet(ProbeEditorBeginFailure) && ProbeEditorBeginFailure && ActiveEditorDialog {`r`n        ProbeEditorBeginFailure := false`r`n        throw Error(""fixture editor begin failure"")`r`n    }")
$tests=@'
OnExit(StopBrowserWorker)
global UiChecks := 0, ProbeListArmed := false, ProbeViewportArmed := false, InputCalls := 0
try {
    AutoMode := false
    ReactionExecutionStatus := {Phase:"finished",Message:"fixture",Final:true}
    global ProbeOverlayFailure := true
    failed := false
    try ShowReactionProgress()
    catch
        failed := true
    CheckUi(failed && !ReactionOverlay && !ReactionOverlayBuilding,"failed construction publishes nothing and unlocks retry")
    ShowReactionProgress()
    CheckUi(ReactionOverlay && IsObject(ReactionOverlayHint) && IsObject(ReactionOverlayStop),"overlay publishes completed controls")
    ReactionOverlay.Hide()
    ExecuteDanmakuCommand("add","",0,{Name:"first",Text:"same",Slot:0})
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
    ExecuteDanmakuCommand("add","",0,{Name:"second",Text:"second",Slot:0})
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
    failed := false
    try ShowShortcutManager()
    catch as failure
        failed := failure.Message == "fixture shortcut presentation failure"
    CheckUi(failed && !ActiveEditorDialog,"failed shortcut presentation releases editor ownership")
    CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"failed shortcut presentation restores parent windows")
    ProbeShortcutFailure := false
    shortcutPanel := ShowShortcutManager()
    CheckUi(IsObject(shortcutPanel) && ActiveEditorDialog,"shortcut presentation can be retried")
    shortcutPanel.Close.Call()
    global ProbeEditorFailure := true
    RuntimePorts.BrowserIdentity := (hwnd) => hwnd=ManagementWindow.Hwnd
    RuntimePorts.ResolveChannel := (hwnd) => {State:"ok",Author:"fixture",Channel:"/channel/fixture",Video:"abcdefghijk"}
    RuntimePorts.BrowserRequest := (hwnd,mode,video,extra) => {State:"not_registered"}
    TargetBrowserHwnd := ManagementWindow.Hwnd
    for openEditor in [() => OpenDanmakuEditor(true),TransferItem,OpenChannelLinkDialog] {
        ManagedList.Modify(1,"Select Focus")
        failed := false
        try openEditor.Call()
        catch as failure
            failed := failure.Message == "fixture editor presentation failure"
        CheckUi(failed && !ActiveEditorDialog && !DanmakuEditorWindow,"editor presentation failure releases ownership")
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
        CheckUi(failed && !ActiveEditorDialog && !DanmakuEditorWindow,"editor begin failure releases ownership and draft window")
        CheckUi(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"editor begin failure restores parent windows")
    }
    RuntimePorts.BrowserIdentity := 0, RuntimePorts.ResolveChannel := 0, RuntimePorts.BrowserRequest := 0
    TargetBrowserHwnd := 0
    global ProbeManagementArmed := true
    RefreshManagement()
    CheckUi(!ProbeManagementArmed && !ManagementRefresh.Active && !DanmakuEditorWindow,"management defers nested refresh and blocks editing")
    CheckUi(SharedDanmakuItems.Length=2 && ManagedList.GetCount()=2,"management refresh cannot delete or undo data")
    PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
    ProbeViewportArmed := true
    PaletteViewport.SetOffset(0,0)
    CheckUi(!ProbeViewportArmed && PaletteViewport.PendingResize && IsObject(PaletteViewport.PendingOffset),"nested updates are queued")
    PaletteViewport.FlushUpdates()
    CheckUi(!PaletteViewport.Updating && !PaletteViewport.PendingResize && !PaletteViewport.PendingOffset,"queued updates drain")
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
        failed := false
        try ProbeCommitAction.Call()
        catch as failure
            failed := failure.Message == "fixture post-save refresh failure"
        CheckUi(failed && !ActiveEditorDialog,"move closes committed editor before failed refresh: " action)
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
        CheckUi(!ActiveEditorDialog && !DanmakuEditorWindow,"stale selection cannot open an editor for another item: " action)
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
    failed := false
    try ProbeCommitAction.Call()
    catch as failure
        failed := failure.Message == "fixture post-save refresh failure"
    CheckUi(failed && !ActiveEditorDialog,"channel link closes committed editor before failed refresh")
    saved := LoadSettings(SettingsDatabasePath)
    CheckUi(saved.Profiles.Length=beforeProfiles+1 && saved.Profiles[-1].Channel="/channel/new","channel link remains saved after refresh failure")
    ProbeAfterSaveFailure := false
    RuntimePorts.ShortcutKey := (action,key,enabled) => 0
    panel := ShowShortcutManager("chat_focus")
    panel.Stage.Call("^+j")
    global ProbeShortcutRefreshFailure := true
    panel.Save.Call()
    CheckUi(!panel.SaveButton.Enabled && InStr(panel.Status.Text,"保存済み"),"key save remains committed when external refresh fails")
    CheckUi(LoadSettings(SettingsDatabasePath).ShortcutKeys["chat_focus"]="^+j","key persisted despite refresh failure")
    panel.First.Choose(2), panel.UpdateItems.Call()
    panel.SaveItems.Call()
    CheckUi(!panel.ItemsSaveButton.Enabled && InStr(panel.ItemStatus.Text,"保存済み"),"item save baseline advances before external refresh")
    CheckUi(ItemSlot(LoadSettings(SettingsDatabasePath).SharedDanmakuItems[1])=1,"item assignment persisted despite refresh failure")
    RuntimePorts.ConfirmDiscard := (*) => false
    panel.Close.Call()
    CheckUi(!ActiveEditorDialog,"committed drafts close without discard confirmation")
    ProbeShortcutRefreshFailure := false
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
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","*")
    ExitApp(1)
}
CheckUi(value,label) {
    global UiChecks
    if !value
        throw Error(label)
    UiChecks++
}
ProbeOverlayConstruction() {
    global ProbeOverlayFailure
    if IsSet(ProbeOverlayFailure) && ProbeOverlayFailure {
        ProbeOverlayFailure := false
        throw Error("fixture construction failure")
    }
    CheckUi(!ReactionOverlay && !ReactionOverlayText,"incomplete overlay not published")
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
