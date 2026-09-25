# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    ShowManagement(1)
    EditingProfileId := ""
    RefreshManagement()
    ; Exercise the actual Save callback on this test application's own windows.
    ManagementWindow.Show()
    WinActivate("ahk_id " ManagementWindow.Hwnd)
    WinWaitActive("ahk_id " ManagementWindow.Hwnd,,2)
    EditingProfileId := ""
    RefreshManagement()
    ShowShortcutManager()
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
    OpenDanmakuEditor(true)
    editor := ActiveEditorDialog.Window
    popup := Gui("+Owner" editor.Hwnd,"confirmation fixture")
    popup.AddButton("w180","fixture confirmation")
    editor.Opt("+Disabled")
    popup.Show("w220 h80")
    otherWindow := Gui(,"outside editor fixture")
    otherWindow.Show("w200 h100")
    WinActivate("ahk_id " otherWindow.Hwnd)
    Assert(WinWaitActive("ahk_id " otherWindow.Hwnd,,2),"another window is active before editor recall")
    ShowPalette()
    Assert(WinWaitActive("ahk_id " popup.Hwnd,,2),"palette shortcut recalls the editor's owned confirmation")
    popup.Destroy(), otherWindow.Destroy()
    editor.Opt("-Disabled")
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    beforeFocusSave := SharedDanmakuItems.Length
    OpenDanmakuEditor(true)
    WinActivate("ahk_id " ActiveEditorDialog.Window.Hwnd)
    WinWaitActive("ahk_id " ActiveEditorDialog.Window.Hwnd,,2)
    Assert(WinActive("ahk_id " ActiveEditorDialog.Window.Hwnd),"editor activated before save")
    editNumber := 0
    for control in ActiveEditorDialog.Window {
        if control.Type = "Edit" {
            editNumber++
            control.Value := editNumber=1 ? "focus regression" : "fixture text"
        }
        if control.Type = "Button" && control.Text = "保存"
            saveButton := control
    }
    SendMessage(0xF5,0,0,saveButton.Hwnd) ; BM_CLICK keeps native button dispatch independent of pointer movement.
    deadline := A_TickCount+2000
    while ActiveEditorDialog && A_TickCount < deadline
        Sleep(10)
    if ActiveEditorDialog {
        statusDetails := ""
        for control in ActiveEditorDialog.Window
            if control.Type="Text"
                statusDetails .= " | " control.Text
        FileAppend("Editor diagnostic: active=" (!!WinActive("ahk_id " ActiveEditorDialog.Window.Hwnd)) " enabled=" DllCall("IsWindowEnabled","Ptr",ActiveEditorDialog.Window.Hwnd) " items=" SharedDanmakuItems.Length " expected=" (beforeFocusSave+1) statusDetails "`n","*")
    }
    Assert(!ActiveEditorDialog && SharedDanmakuItems.Length=beforeFocusSave+1,"save callback completes")
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
    WinActivate("ahk_id " ActiveEditorDialog.Window.Hwnd)
    Assert(WinWaitActive("ahk_id " ActiveEditorDialog.Window.Hwnd,,2),"editor is active before cancellation")
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    Assert(WinWaitActive("ahk_id " ManagementWindow.Hwnd,,2) && SharedDanmakuItems.Length=beforeFocusSave,"cancel restores panel without saving")
    OpenDanmakuEditor(true)
    priorEditor := ActiveEditorDialog.Window
    CloseDanmakuEditor(priorEditor)
    OpenDanmakuEditor(true)
    replacementEditor := ActiveEditorDialog.Window
    CloseDanmakuEditor(priorEditor)
    FinishDanmakuEditor(priorEditor)
    Assert(ActiveEditorDialog.Window=replacementEditor && DllCall("IsWindow","Ptr",replacementEditor.Hwnd),"stale close cannot destroy the replacement editor")
    Assert(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"stale close preserves parent locks")
    OpenDanmakuEditor(true)
    Assert(ActiveEditorDialog.Window=replacementEditor,"repeated open recalls the existing editor")
    CloseDanmakuEditor(replacementEditor)
    global DiscardCount := 0, DiscardAllowed := false
    RuntimePorts.ConfirmDiscard := ConfirmEditorTest
    OpenDanmakuEditor(true)
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    Assert(!ActiveEditorDialog && DiscardCount=0,"unchanged editor closes without asking")
    OpenDanmakuEditor(true)
    for control in ActiveEditorDialog.Window
        if control.Type="Edit" {
            nameControl := control
            break
        }
    nameControl.Value := "draft"
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    Assert(ActiveEditorDialog && DiscardCount=1 && nameControl.Value="draft","cancelled discard preserves input and modal owner")
    nameControl.Value := ""
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    Assert(!ActiveEditorDialog && DiscardCount=1,"reverted edit closes without asking")
    OpenDanmakuEditor(true)
    for control in ActiveEditorDialog.Window
        if control.Type="Edit"
            control.Value := "discarded"
    DiscardAllowed := true
    CloseDanmakuEditor(ActiveEditorDialog.Window)
    Assert(!ActiveEditorDialog && DiscardCount=2 && SharedDanmakuItems.Length=beforeFocusSave,"confirmed discard saves nothing")
    RuntimePorts.ConfirmDiscard := 0
    ManagementWindow.Hide()
    modal := Gui(,"key editing fixture")
    PaletteWindow.Opt("+Disabled")
    BeginEditorDialog(modal,"リアクションキーの編集")
    Assert(ActiveEditorDialog.Label="リアクションキーの編集" && ShortcutBlocked(),"blocking reason identifies actual dialog")
    EndEditorDialog(modal)
    Assert(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd),"closing dialog preserves previously disabled window")
    PaletteWindow.Opt("-Disabled"), modal.Destroy()


'@ -Helpers @'
ConfirmEditorTest(message) {
    global DiscardCount
    DiscardCount++
    return DiscardAllowed
}
'@

Invoke-AppFixture -Body @'
    ShowManagement(1)
    for sourceId in ["","source"] {
        for action in ["edit","move"] {
            for change in ["reorder","deleted","owner-deleted"] {
                if sourceId = "" && change = "owner-deleted"
                    continue
                items := [{Id:"item-a",Name:"same",Text:"same",Slot:0},
                    {Id:"item-A",Name:"same",Text:"same",Slot:1},
                    {Id:"neighbor",Name:"same",Text:"same",Slot:2}]
                library := {Profiles:[{Id:"source",Name:"Source",Channel:"",Items:sourceId = "" ? [] : items},
                    {Id:"destination",Name:"Destination",Channel:"",Items:[]}],SharedDanmakuItems:sourceId = "" ? items : []}
                CommitTestLibraryChange(library,"dialog identity fixture")
                EditingProfileId := sourceId
                RefreshManagement(), ManagedList.Modify(2,"Select Focus")
                if action = "edit"
                    OpenDanmakuEditor(false)
                else
                    TransferItem()
                dialog := ActiveEditorDialog.Window
                for control in dialog {
                    if control.Type = "Edit"
                        control.Value := "changed"
                    if action = "move" && control.Type = "DDL"
                        control.Choose(sourceId = "" ? 2 : 1)
                    if control.Type = "Button" && control.Text = (action = "edit" ? "保存" : "移動")
                        submit := control
                }
                ; Model a library publication while the dialog retains its original selection.
                changed := CreateTestLibrarySnapshot(), changedItems := GetLibraryItems(changed,sourceId)
                if change = "owner-deleted"
                    changed.Profiles.RemoveAt(1)
                else if change = "deleted"
                    changedItems.RemoveAt(2)
                else {
                    moved := changedItems.RemoveAt(2)
                    changedItems.InsertAt(1,moved)
                }
                CommitTestLibraryChange(changed,"intervening publication")
                LibraryHistory := []
                before := EditorLibrarySignature(changed)
                window := dialog.Hwnd
                SendMessage(0xF5,0,0,submit.Hwnd)
                Sleep(50)
                label := sourceId "/" action "/" change
                if change = "reorder" {
                    Assert(!ActiveEditorDialog && !DllCall("IsWindow","Ptr",window),label ": successful submission closes")
                    saved := LoadSettings(SettingsDatabasePath)
                    actualSource := GetLibraryItems(saved,sourceId)
                    if action = "edit" {
                        Assert(actualSource[1].Id == "item-A" && actualSource[1].Name == "changed" && actualSource[1].Text == "changed",label ": edits the captured ID at its new position")
                        Assert(actualSource[2].Id == "item-a" && actualSource[2].Text == "same" && actualSource[3].Id == "neighbor" && actualSource[3].Text == "same",label ": preserves other same-text items")
                    } else {
                        destination := GetLibraryItems(saved,sourceId = "" ? "destination" : "")
                        Assert(destination.Length=1 && destination[1].Id == "item-A" && destination[1].Slot=0,label ": moves the captured ID and clears assignment")
                        Assert(actualSource.Length=2 && actualSource[1].Id == "item-a" && actualSource[2].Id == "neighbor",label ": preserves source neighbors")
                    }
                    Assert(LibraryHistory.Length=1,label ": records one command")
                    UndoLibraryCommand()
                    Assert(EditorLibrarySignature(LoadSettings(SettingsDatabasePath)) == before,label ": undo restores the state immediately before submission")
                } else {
                    Assert(ActiveEditorDialog && ActiveEditorDialog.Window=dialog,label ": missing target leaves dialog open")
                    Assert(LibraryHistory.Length=0 && EditorLibrarySignature(LoadSettings(SettingsDatabasePath)) == before,label ": rejected operation changes neither data nor history")
                    message := ""
                    for control in dialog
                        if control.Type = "Text"
                            message .= control.Text
                    Assert(InStr(message,"保存できませんでした。") && InStr(message,"選び直してください。"),label ": explains why saving was refused")
                    EndEditorDialog(dialog), dialog.Destroy()
                }
            }
        }
    }
'@ -Helpers @'
EditorLibrarySignature(library) {
    result := ""
    for item in library.SharedDanmakuItems
        result .= item.Id "|" item.Name "|" item.Text "|" item.Slot "`n"
    for profile in library.Profiles {
        result .= "scope:" profile.Id "`n"
        for item in profile.Items
            result .= item.Id "|" item.Name "|" item.Text "|" item.Slot "`n"
    }
    return result
}
'@

# Change the editing scope after row validation, before the caller can read it again.
$selectionRuntime = New-TestRuntime
$controllerPath = Join-Path $selectionRuntime 'src/ui/management/management_controller.ahk'
$controller = [IO.File]::ReadAllText($controllerPath)
$anchor = 'GetSelectedManagedTarget() {'
if (!$controller.Contains($anchor)) { throw 'Missing selected target boundary' }
[IO.File]::WriteAllText($controllerPath,$controller.Replace($anchor,'OriginalGetSelectedManagedTarget() {'),[Text.UTF8Encoding]::new($true))
Invoke-AppFixture -Runtime $selectionRuntime -Body @'
    ShowManagement(1)
    global SelectionSwitchArmed := false
    for action in ["duplicate","edit","move"] {
        CommitTestLibraryChange({Profiles:[
            {Id:"source-a",Name:"A",Channel:"",Items:[{Id:"item-a",Name:"A item",Text:"A body",Slot:1}]},
            {Id:"source-b",Name:"B",Channel:"",Items:[{Id:"item-b",Name:"B item",Text:"B body",Slot:2}]}],SharedDanmakuItems:[]},"selected target fixture")
        EditingProfileId := "source-a"
        RefreshManagement(), SelectManagedRow(1)
        LibraryHistory := [], SelectionSwitchArmed := true
        if action = "duplicate"
            HandleDanmakuCommand(action)
        else {
            if action = "edit"
                OpenDanmakuEditor(false)
            else
                TransferItem()
            dialog := ActiveEditorDialog.Window
            if action = "edit" {
                nameSeen := false, textSeen := false
                for control in dialog {
                    if control.Type = "Edit" {
                        nameSeen := nameSeen || control.Value == "A item"
                        textSeen := textSeen || control.Value == "A body"
                        control.Value := "changed A"
                    }
                }
                Assert(nameSeen && textSeen,"editor opens with the validated item")
            }
            for control in dialog
                if control.Type = "Button" && control.Text = (action = "edit" ? "保存" : "移動")
                    submit := control
            window := dialog.Hwnd
            SendMessage(0xF5,0,0,submit.Hwnd)
            Assert(WinWaitClose("ahk_id " window,,2),action ": save completes")
        }
        saved := LoadSettings(SettingsDatabasePath)
        a := GetLibraryItems(saved,"source-a"), b := GetLibraryItems(saved,"source-b")
        Assert(!SelectionSwitchArmed && b.Length=1 && b[1].Id == "item-b" && b[1].Name == "B item" && b[1].Text == "B body" && b[1].Slot=2,action ": a later scope selection cannot redirect the command")
        if action = "duplicate"
            Assert(a.Length=2 && a[1].Id == "item-a" && a[2].Id != a[1].Id && a[2].Text == "A body",action ": copies the captured source")
        else if action = "edit"
            Assert(a.Length=1 && a[1].Id == "item-a" && a[1].Text == "changed A",action ": edits the captured source")
        else
            Assert(a.Length=0 && saved.SharedDanmakuItems.Length=1 && saved.SharedDanmakuItems[1].Id == "item-a",action ": moves the captured source")
        Assert(LibraryHistory.Length=1 && EditingProfileId == "source-a",action ": publishes once and refreshes the saved scope")
    }
'@ -Helpers @'
GetSelectedManagedTarget() {
    global SelectionSwitchArmed, EditingProfileId
    selected := OriginalGetSelectedManagedTarget()
    if SelectionSwitchArmed {
        SelectionSwitchArmed := false
        EditingProfileId := "source-b"
    }
    return selected
}
'@

# Timers at the saved/display boundary must observe the completed editor result.
$commitRuntime = New-TestRuntime
$controllerPath = Join-Path $commitRuntime 'src\ui\management\management_controller.ahk'
$source = [IO.File]::ReadAllText($controllerPath)
$boundary = 'RefreshManagementAfterCommand(editId, message := "変更は保存済みです。", updateManagement := 0) {'
if (!$source.Contains($boundary)) { throw 'Missing saved presentation boundary' }
[IO.File]::WriteAllText($controllerPath,$source.Replace($boundary,$boundary+"`r`n    ProbeEditorCommit(editId)"),[Text.UTF8Encoding]::new($true))
$dialogsPath = Join-Path $commitRuntime 'src\ui\management\management_dialogs.ahk'
$source = [IO.File]::ReadAllText($dialogsPath)
foreach ($entry in @(
    @('view.AddButton("w120 Default","保存").OnEvent("Click",Save)','Save'),
    @('moveButton.OnEvent("Click",Move)','Move'),
    @('view.AddButton("w180 Default","連携する").OnEvent("Click",Save)','Save'))) {
    if (!$source.Contains($entry[0])) { throw 'Missing editor submit callback' }
    $source=$source.Replace($entry[0],$entry[0]+"`r`n        global SubmitCommitFixture := "+$entry[1])
}
[IO.File]::WriteAllText($dialogsPath,$source,[Text.UTF8Encoding]::new($true))
Invoke-AppFixture -Runtime $commitRuntime -Body @'
    global CommitProbeArmed := false, CommitExpectedRow := 0, CommitExpectedId := "", QueuedTargetId := "", QueuedEdits := 0
    global ExpectedResolveCritical := 0
    RuntimePorts.ResolveChannel := ResolveCommitFixtureChannel
    TargetBrowserHwnd := 123
    for action in ["add","edit","move","undo","link"] {
        for callerCritical in [0,23] {
            shared := [], own := [], SubmitCommitFixture := 0, ExpectedResolveCritical := 0
            Loop 3 {
                shared.Push({Id:"shared-" A_Index,Name:"shared" A_Index,Text:"body" A_Index,Slot:0})
                own.Push({Id:"own-" A_Index,Name:"own" A_Index,Text:"body" A_Index,Slot:0})
            }
            CommitTestLibraryChange({Profiles:[{Id:"commit-profile",Name:"fixture",Channel:"",Items:own}],SharedDanmakuItems:shared},"prepare editor commit")
            LibraryHistory := []
            scope := action="link" ? "commit-profile" : ""
            EditingProfileId := scope
            ShowManagement(1), SelectManagedRow(2)
            if action="undo" {
                ExecuteDanmakuCommand("add",scope,"",{Name:"undo item",Text:"undo body",Slot:0})
                RefreshManagement(), SelectManagedRow(4)
            } else if action="link"
                OpenChannelLinkDialog(scope)
            else if action="move"
                TransferItem()
            else {
                OpenDanmakuEditor(action="add")
                for control in ActiveEditorDialog.Window
                    if control.Type="Edit"
                        control.Value := "saved " action
            }
            if action!="undo"
                Assert(ActiveEditorDialog && IsObject(SubmitCommitFixture),action ": owns a current editor callback")
            CommitExpectedRow := action="add" ? 4 : (action="move" || action="undo" ? 1 : 2)
            CommitExpectedId := "", QueuedTargetId := "", QueuedEdits := 0, CommitProbeArmed := true
            try {
                ExpectedResolveCritical := callerCritical
                Critical(callerCritical)
                if action="undo"
                    UndoLibraryChange()
                else
                    SubmitCommitFixture.Call()
                Assert(A_IsCritical=callerCritical,action ": restores caller interruption policy")
                Critical("Off")
                deadline := A_TickCount+1000
                while !QueuedEdits && A_TickCount<deadline
                    Sleep(10)
                Assert(QueuedEdits=1 && QueuedTargetId==CommitExpectedId,action ": next edit sees the completed selection")
                Assert(!ActiveEditorDialog && InStr(ManagementStatus.Text,"削除"),action ": latest completed operation owns the notice")
                live := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},scope)
                saved := GetLibraryItems(LoadSettings(SettingsDatabasePath),scope)
                expectedCount := action="add" ? 3 : action="move" ? 1 : 2
                Assert(live.Length=expectedCount && saved.Length=expectedCount,action ": each operation is persisted once")
                for i,item in live
                    Assert(item.Id==saved[i].Id && item.Id!=CommitExpectedId,action ": memory and storage preserve the same remaining identities")
            } finally {
                Critical("Off")
                SetTimer(DeleteAfterEditorCommit,0)
                CommitProbeArmed := false
            }
        }
    }
'@ -Helpers @'
ResolveCommitFixtureChannel(hwnd) {
    Assert(A_IsCritical=ExpectedResolveCritical,"channel verification preserves caller interruption policy")
    return {State:"ok",Author:"fixture channel",Channel:"/channel/fixture",Video:"abcdefghijk"}
}
ProbeEditorCommit(scope) {
    global CommitProbeArmed, CommitExpectedId
    if !CommitProbeArmed
        return
    CommitProbeArmed := false
    items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},scope)
    CommitExpectedId := items[CommitExpectedRow].Id
    SetTimer(DeleteAfterEditorCommit,-1)
    Sleep(40)
}
DeleteAfterEditorCommit() {
    global QueuedTargetId, QueuedEdits
    selected := GetSelectedManagedTarget()
    QueuedTargetId := selected ? selected.Item.Id : ""
    HandleDanmakuCommand("delete")
    QueuedEdits++
}
'@
