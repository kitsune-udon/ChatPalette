# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '            control.Delete(), control.Add(labels), control.Choose(choices[i])' ('            control.Delete(), control.Add(labels), control.Choose(choices[i])'+"`r`n            ProbeShortcutItems(i)")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '        viewport.Show()' ("        if IsSet(ProbeShortcutFailure) && ProbeShortcutFailure`r`n            throw Error(""fixture shortcut presentation failure"")`r`n        viewport.Show()")
Edit-TestSource $release 'src/ui/window_presenter.ahk' 'PresentWindow(view, options := "", layout := 0, activate := true) {' ('PresentWindow(view, options := "", layout := 0, activate := true) {' + "`r`n    if IsSet(ProbeEditorFailure) && ProbeEditorFailure && ActiveEditorDialog && ActiveEditorDialog.Window = view`r`n        throw Error(""fixture editor presentation failure"")")
Edit-TestSource $release 'src/ui/ui_runtime.ahk' 'RefreshOperationControls() {' ('RefreshOperationControls() {' + "`r`n    global ProbeEditorBeginFailure`r`n    if IsSet(ProbeEditorBeginFailure) && ProbeEditorBeginFailure && ActiveEditorDialog {`r`n        ProbeEditorBeginFailure := false`r`n        throw Error(""fixture editor begin failure"")`r`n    }")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '        view.SetFont("s10","Yu Gothic UI")' ('        view.SetFont("s10","Yu Gothic UI")' + "`r`n        if IsSet(ProbeEditorConstructionFailure) && ProbeEditorConstructionFailure {`r`n            global ProbeEditorConstructionHwnd := view.Hwnd`r`n            throw Error(""fixture editor construction failure"")`r`n        }")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    view.OnEvent("Close",Close), view.OnEvent("Escape",Close)' ('    view.OnEvent("Close",Close), view.OnEvent("Escape",Close)' + "`r`n    ProbeEditorBuild(view)")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    view.OnEvent("Close",Close),view.OnEvent("Escape",Close)' ('    view.OnEvent("Close",Close),view.OnEvent("Escape",Close)' + "`r`n    ProbeEditorBuild(view)")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '    viewport := PanelViewport(view,680,780)' ('    viewport := PanelViewport(view,680,780)' + "`r`n    ProbeEditorBuild(view,viewport)")
$tests=@'
AutoMode := false
ExecuteDanmakuCommand("add","","",{Name:"first",Text:"same",Slot:0})
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second",Slot:0})
BuildManagement()
global ProbeShortcutFailure := true
shortcutCritical := A_IsCritical
failed := false
try ShowShortcutManager()
catch as failure
    failed := failure.Message == "fixture shortcut presentation failure"
Assert(failed && !ActiveEditorDialog,"failed shortcut presentation releases editor ownership")
Assert(A_IsCritical=shortcutCritical,"failed shortcut presentation restores the original interrupt policy")
Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"failed shortcut presentation restores parent windows")
ProbeShortcutFailure := false
shortcutPanel := ShowShortcutManager()
Assert(IsObject(shortcutPanel) && ActiveEditorDialog,"shortcut presentation can be retried")
Assert(A_IsCritical=shortcutCritical,"item initialization does not overwrite the editor interrupt policy")
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
        Assert(failed && A_IsCritical=closeCritical,"editor cleanup preserves failure and interrupt policy")
        Assert(closingPanel.Viewport.Disposed && !ActiveEditorDialog,"viewport disposal failure still releases editor ownership")
        Assert(!DllCall("IsWindow","Ptr",closingHwnd),"viewport disposal failure still destroys editor window")
        Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)
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
Assert(A_IsCritical=shortcutCritical,"failed item refresh restores the original interrupt policy")
Assert(failed && !ProbeItemPanel.ItemsSaveButton.Enabled && !ProbeItemPanel.First.Enabled && !ProbeItemPanel.Second.Enabled,"partial item choices cannot be edited or saved")
ProbeItemPanel.UpdateItems.Call(), ProbeItemPanel.SaveItems.Call()
Assert(LibraryHistory.Length=ProbeItemHistory && !ProbeItemPanel.ItemsSaveButton.Enabled,"incomplete item snapshot remains unsaveable after callbacks")
saved := LoadSettings(SettingsDatabasePath)
Assert(GetLibraryItems(saved,itemProfile)[1].Slot=0 && GetLibraryItems(saved,itemProfile)[2].Slot=0,"failed item rendering preserves stored assignments")
ProbeItemFailure := false
ProbeItemPanel.RefreshItems.Call()
Assert(ProbeItemPanel.First.Enabled && ProbeItemPanel.Second.Enabled && !ProbeItemPanel.ItemsSaveButton.Enabled,"retry publishes both completed item choices")
ProbeItemPanel.First.Choose(2), ProbeItemPanel.Second.Choose(3), ProbeItemPanel.UpdateItems.Call(), ProbeItemPanel.SaveItems.Call()
saved := LoadSettings(SettingsDatabasePath)
Assert(GetLibraryItems(saved,itemProfile)[1].Slot=1 && GetLibraryItems(saved,itemProfile)[2].Slot=2,"retried item choices save the two displayed assignments")
ProbeItemPanel.Close.Call(), ProbeItemPanel := 0
ExecuteProfileCommand("delete",itemProfile)
global ProbeEditorConstructionFailure := true, ProbeEditorConstructionHwnd := 0
beforeCritical := A_IsCritical
failed := false
try OpenDanmakuEditor(true)
catch as failure
    failed := failure.Message == "fixture editor construction failure"
Assert(failed && ProbeEditorConstructionHwnd && !DllCall("IsWindow","Ptr",ProbeEditorConstructionHwnd),"failed editor construction destroys the unpublished native window")
Assert(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"failed editor construction leaves no owner and keeps parents enabled")
Assert(A_IsCritical=beforeCritical,"failed editor construction restores interrupt policy")
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
    Assert(failed && ProbeBuiltEditorHwnd && !DllCall("IsWindow","Ptr",ProbeBuiltEditorHwnd),"partial editor construction releases native window: " openEditor.Name)
    Assert(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"partial construction preserves parent state: " openEditor.Name)
    Assert(A_IsCritical=beforeCritical,"failed editor build restores interrupt policy: " openEditor.Name)
    if ProbeBuiltViewport
        Assert(ProbeBuiltViewport.Disposed,"failed shortcut construction disposes scrolling resources")
    ProbeEditorBuildFailure := false
    openEditor.Call()
    retryHwnd := ActiveEditorDialog.Window.Hwnd
    Assert(DllCall("IsWindowVisible","Ptr",retryHwnd),"editor can be retried after failed construction: " openEditor.Name)
    WinClose("ahk_id " retryHwnd)
    Assert(WinWaitClose("ahk_id " retryHwnd,,2) && !ActiveEditorDialog,"retried editor closes normally: " openEditor.Name)
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
    Assert(failed && !ActiveEditorDialog,"editor presentation failure releases ownership")
    Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"editor presentation failure restores parents")
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
    Assert(failed && !ActiveEditorDialog,"editor begin failure releases ownership and draft window")
    Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"editor begin failure restores parent windows")
}
RuntimePorts.BrowserIdentity := 0, RuntimePorts.ResolveChannel := 0, RuntimePorts.BrowserRequest := 0
TargetBrowserHwnd := 0
priorEditor := Gui(), currentEditor := Gui()
BeginEditorDialog(priorEditor,"prior fixture")
EndEditorDialog(priorEditor)
BeginEditorDialog(currentEditor,"current fixture")
EndEditorDialog(priorEditor)
Assert(ActiveEditorDialog && ActiveEditorDialog.Window=currentEditor,"stale editor cannot release current ownership")
Assert(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"stale close keeps current editor parents disabled")
EndEditorDialog(currentEditor)
Assert(!ActiveEditorDialog && DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"owning editor restores parents")
priorEditor.Destroy(), currentEditor.Destroy()
FileAppend("PASS: " Checks " editor lifecycle checks; no browser operations`n","*")
ExitApp()
FailEditorViewportDispose(viewport,*) {
    PanelViewport.Prototype.Dispose.Call(viewport)
    throw Error("fixture editor viewport disposal failure")
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
    Assert(LibraryHistory.Length=ProbeItemHistory && !ProbeItemPanel.ItemsSaveButton.Enabled,"item save is blocked before both dropdowns are complete")
    throw Error("fixture item choices failure")
}
'@
Invoke-AppTest -Runtime $release -Body $tests
