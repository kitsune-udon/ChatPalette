# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    moveButton.OnEvent("Click",Move)' ('    moveButton.OnEvent("Click",Move)' + "`r`n    global ProbeCommitAction := Move")
Edit-TestSource $release 'src/ui/management/management_dialogs.ahk' '    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)' ('    view.AddButton("w180 Default","連携する").OnEvent("Click",Save)' + "`r`n    global ProbeCommitAction := Save")
Edit-TestSource $release 'src/ui/management/management_view.ahk' 'RefreshManagement(render := 0) {' ('RefreshManagement(render := 0) {' + "`r`n    if IsSet(ProbeAfterSaveFailure) && ProbeAfterSaveFailure`r`n        throw Error(""fixture post-save refresh failure"")")
Edit-TestSource $release 'src/ui/palette/palette_view.ahk' 'RefreshPalette() {' ('RefreshPalette() {' + "`r`n    if IsSet(ProbeShortcutRefreshFailure) && ProbeShortcutRefreshFailure`r`n        throw Error(""fixture shortcut refresh failure"")")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '        try SaveShortcutMap(draft)' ("        try {`r`n            SaveShortcutMap(draft)`r`n            ProbeShortcutSaved(""keys"")`r`n        }")
Edit-TestSource $release 'src/ui/shortcut_manager.ahk' '            SaveShortcutItemAssignments(itemState.ProfileId,itemState.Ids[first.Value],itemState.Ids[second.Value])' ('            SaveShortcutItemAssignments(itemState.ProfileId,itemState.Ids[first.Value],itemState.Ids[second.Value])' + "`r`n            ProbeShortcutSaved(""items"")")
$tests=@'
AutoMode := false
ExecuteDanmakuCommand("add","","",{Name:"first",Text:"same",Slot:0})
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second",Slot:0})
BuildManagement()
RefreshPalette()
PresentWindow(PaletteWindow,"w560 h740",ResizePalette,false)
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
    Assert(!ActiveEditorDialog && InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"管理画面：fixture post-save refresh failure"),"move closes committed editor and reports failed refresh: " action)
    Assert(PaletteRows.Length=1 && PaletteRows[1].ItemId=SharedDanmakuItems[1].Id,"management refresh failure does not prevent palette update: " action)
    saved := LoadSettings(SettingsDatabasePath)
    Assert(GetLibraryItems(saved,destination).Length=1 && GetLibraryItems(saved,destination)[1].Id=movedId,"move remains saved after refresh failure: " action)
    ProbeAfterSaveFailure := false
    remainingId := SharedDanmakuItems[1].Id, historyBefore := LibraryHistory.Length
    Assert(ManagedList.GetText(selected,4)=movedId,"failed refresh leaves the moved item displayed: " action)
    if action="edit"
        OpenDanmakuEditor(false)
    else if action="transfer"
        TransferItem()
    else
        HandleDanmakuCommand(action)
    Assert(!ActiveEditorDialog,"stale selection cannot open an editor for another item: " action)
    Assert(SharedDanmakuItems.Length=1 && SharedDanmakuItems[1].Id=remainingId && LibraryHistory.Length=historyBefore,"stale selection preserves library and history: " action)
    saved := LoadSettings(SettingsDatabasePath)
    Assert(saved.SharedDanmakuItems.Length=1 && saved.SharedDanmakuItems[1].Id=remainingId && GetLibraryItems(saved,destination).Length=1 && GetLibraryItems(saved,destination)[1].Id=movedId,"stale selection cannot change saved items: " action)
    Assert(ManagedList.GetCount()=1 && ManagedList.GetText(1,4)=remainingId && !ManagedList.GetNext() && InStr(ManagementStatus.Text,"選び直してください"),"stale selection refreshes the view and requires a new selection: " action)
    HandleDanmakuCommand("delete")
    Assert(SharedDanmakuItems.Length=1 && LibraryHistory.Length=historyBefore,"repeated action without selection cannot delete an item: " action)
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
Assert(!ActiveEditorDialog && InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"管理画面：fixture post-save refresh failure"),"channel link closes committed editor and reports failed refresh")
saved := LoadSettings(SettingsDatabasePath)
Assert(saved.Profiles.Length=beforeProfiles+1 && saved.Profiles[-1].Channel="/channel/new","channel link remains saved after refresh failure")
ProbeAfterSaveFailure := false
RuntimePorts.ShortcutKey := (action,key,enabled) => 0
EditingProfileId := ""
RefreshManagement()
PaletteWindow.Show("NA")
panel := ShowShortcutManager("chat_focus")
panel.Stage.Call("^+j")
global ProbeShortcutRefreshFailure := true
panel.Save.Call()
Assert(!panel.SaveButton.Enabled && InStr(panel.Status.Text,"保存済み"),"key save remains committed when external refresh fails")
Assert(LoadSettings(SettingsDatabasePath).ShortcutKeys["chat_focus"]="^+j","key persisted despite refresh failure")
panel.First.Choose(2), panel.UpdateItems.Call()
panel.SaveItems.Call()
Assert(!panel.ItemsSaveButton.Enabled && InStr(panel.ItemStatus.Text,"保存済み"),"item save baseline advances before external refresh")
Assert(LoadSettings(SettingsDatabasePath).SharedDanmakuItems[1].Slot=1,"item assignment persisted despite refresh failure")
Assert(ManagedList.GetText(1,3)=StrReplace(ShortcutKeyLabel(GetShortcutKey("shared1")),"＋","+"),"palette refresh failure does not prevent management from showing the saved assignment")
RuntimePorts.ConfirmDiscard := (*) => false
panel.Close.Call()
Assert(!ActiveEditorDialog,"committed drafts close without discard confirmation")
ManagedList.Modify(1,"Select Focus")
historyBefore := LibraryHistory.Length
HandleDanmakuCommand("duplicate")
Assert(SharedDanmakuItems.Length=2 && LibraryHistory.Length=historyBefore+1 && LoadSettings(SettingsDatabasePath).SharedDanmakuItems.Length=2,"duplicate commits once despite palette failure")
Assert(ManagedList.GetCount()=2 && ManagedList.GetText(ManagedList.GetNext(),4)=SharedDanmakuItems[2].Id,"saved duplicate is selected despite palette failure")
Assert(InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"パレット：fixture shortcut refresh failure"),"management reports saved duplicate and failed palette update")
ProbeAfterSaveFailure := true
UndoLibraryChange()
Assert(SharedDanmakuItems.Length=1 && LibraryHistory.Length=historyBefore && LoadSettings(SettingsDatabasePath).SharedDanmakuItems.Length=1,"undo remains committed when both views fail")
Assert(InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"パレット：fixture shortcut refresh failure") && InStr(ManagementStatus.Text,"管理画面：fixture post-save refresh failure"),"both view failures remain available in saved notice")
ProbeAfterSaveFailure := false, ProbeShortcutRefreshFailure := false
RefreshLibraryViews()
Assert(ManagedList.GetCount()=1 && PaletteRows.Length=1,"views recover from committed state without replaying the command")
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
        Assert(A_IsCritical=savedCritical,"shortcut save restores caller interrupt setting: " mode)
        deadline := A_TickCount+1000
        while !ProbeLateEditRuns && A_TickCount<deadline
            Sleep(10)
        Assert(!ProbeSavedArmed && ProbeLateEditRuns=1,"later shortcut edit actually reaches the save boundary: " mode)
        persisted := LoadSettings(SettingsDatabasePath)
        if mode="items" {
            Assert(persisted.SharedDanmakuItems[1].Slot=0,"item save persists the submitted choice only")
            Assert(ProbeSavedPanel.First.Value=2 && ProbeSavedPanel.ItemsSaveButton.Enabled,
                "later item choice remains visible and unsaved")
        } else {
            Assert(persisted.ShortcutKeys["chat_focus"]=="^+F11","key save persists the submitted key only")
            Assert(ProbeSavedPanel.SaveButton.Enabled && ProbeSavedPanel.List.GetText(ProbeSavedPanel.List.GetNext(),2)=ShortcutKeyLabel("^+F12"),
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
FileAppend("PASS: " Checks " editor commit checks; no browser operations`n","*")
ExitApp()
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
'@
Invoke-AppTest -Runtime $release -Body $tests
