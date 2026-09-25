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
    if DanmakuEditorWindow {
        statusDetails := ""
        for control in DanmakuEditorWindow
            if control.Type="Text"
                statusDetails .= " | " control.Text
        FileAppend("Editor diagnostic: active=" (!!WinActive("ahk_id " DanmakuEditorWindow.Hwnd)) " enabled=" DllCall("IsWindowEnabled","Ptr",DanmakuEditorWindow.Hwnd) " items=" SharedDanmakuItems.Length " expected=" (beforeFocusSave+1) statusDetails "`n","*")
    }
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
    Assert(WinWaitActive("ahk_id " DanmakuEditorWindow.Hwnd,,2),"editor is active before cancellation")
    CloseDanmakuEditor()
    Assert(WinWaitActive("ahk_id " ManagementWindow.Hwnd,,2) && SharedDanmakuItems.Length=beforeFocusSave,"cancel restores panel without saving")
    global DiscardCount := 0, DiscardAllowed := false
    RuntimePorts.ConfirmDiscard := ConfirmEditorTest
    OpenDanmakuEditor(true)
    CloseDanmakuEditor()
    Assert(!DanmakuEditorWindow && DiscardCount=0,"unchanged editor closes without asking")
    OpenDanmakuEditor(true)
    for control in DanmakuEditorWindow
        if control.Type="Edit" {
            nameControl := control
            break
        }
    nameControl.Value := "draft"
    CloseDanmakuEditor()
    Assert(DanmakuEditorWindow && ActiveEditorDialog && DiscardCount=1 && nameControl.Value="draft","cancelled discard preserves input and modal owner")
    nameControl.Value := ""
    CloseDanmakuEditor()
    Assert(!DanmakuEditorWindow && DiscardCount=1,"reverted edit closes without asking")
    OpenDanmakuEditor(true)
    for control in DanmakuEditorWindow
        if control.Type="Edit"
            control.Value := "discarded"
    DiscardAllowed := true
    CloseDanmakuEditor()
    Assert(!DanmakuEditorWindow && !ActiveEditorDialog && DiscardCount=2 && SharedDanmakuItems.Length=beforeFocusSave,"confirmed discard saves nothing")
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
