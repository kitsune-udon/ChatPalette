# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    global BindingCalls := []
    RuntimePorts.ShortcutKey := (action,key,enabled) => BindingCalls.Push({Action:action,Key:key,Enabled:enabled})
    saved := CurrentShortcutMap()
    shared := ExecuteDanmakuCommand("add","","",{Name:"first",Text:"first",Slot:1})
    ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second",Slot:2})
    firstId := SharedDanmakuItems[shared.Index].Id, secondId := SharedDanmakuItems[-1].Id
    SaveShortcutItemAssignments("",secondId,firstId)
    Assert(SharedDanmakuItems[shared.Index].Slot=2 && SharedDanmakuItems[-1].Slot=1,"item slot swap retains identity")
    panel := ShowShortcutManager("chat_focus")
    Assert(panel.List.GetCount()=11 && ActiveEditorDialog,"one screen contains every action")
    Assert(!panel.SaveButton.Enabled && !panel.ItemsSaveButton.Enabled,"unchanged drafts disable both saves")
    priorCalls := BindingCalls.Length, priorFocusKey := GetShortcutKey("chat_focus")
    panel.Stage.Call("!^F")
    Assert(!panel.SaveButton.Enabled && panel.List.GetText(panel.List.GetNext(),4)="","equivalent modifier order and letter case remain unchanged in the editor")
    panel.Save.Call()
    Assert(BindingCalls.Length=priorCalls && GetShortcutKey("chat_focus")==priorFocusKey,"saving an equivalent draft neither registers nor publishes a different key spelling")
    panel.Stage.Call(""), panel.Save.Call()
    Assert(GetShortcutKey("chat_focus")="" && LoadSettings(SettingsDatabasePath).ShortcutKeys["chat_focus"]=""
        && BindingCalls.Length=priorCalls+1 && !BindingCalls[-1].Enabled,"clearing an optional key disables and saves exactly that binding")
    panel.Stage.Call(priorFocusKey), panel.Save.Call()
    Assert(GetShortcutKey("chat_focus")==priorFocusKey && BindingCalls.Length=priorCalls+2
        && BindingCalls[-1].Enabled && !panel.SaveButton.Enabled,"restoring an optional key registers once and clears the draft change")
    panel.First.Choose(1), panel.UpdateItems.Call()
    Assert(panel.ItemsSaveButton.Enabled,"item edit enables its save")
    panel.Key.Value := "^+f"
    SendMessage(0x111, (0x300 << 16) | GetDlgCtrlID(panel.Key.Hwnd), panel.Key.Hwnd,, "ahk_id " panel.Window.Hwnd)
    Sleep(30)
    Assert(panel.SaveButton.Enabled && panel.List.GetText(panel.List.GetNext(),4)="変更あり","native key change stages draft without apply button")
    panel.Save.Call()
    Assert(panel.First.Value=1 && panel.ItemsSaveButton.Enabled && !panel.SaveButton.Enabled,"key save preserves unsaved item choice and independent dirty state")
    Assert(CanonicalShortcutKey(GetShortcutKey("chat_focus"))="^+f" && InStr(panel.Status.Text,"保存し"),"screen saves selected action")
    panel.Stage.Call("^!q"), panel.Save.Call()
    Assert(CanonicalShortcutKey(GetShortcutKey("chat_focus"))="^+f" && InStr(panel.Status.Text,"重複"),"screen retains valid setting on conflict")
    Assert(!panel.SaveButton.Enabled && panel.List.GetText(1,4)="重複","conflicting rows are marked and save disabled")
    panel.SaveItems.Call()
    Assert(!panel.ItemsSaveButton.Enabled && InStr(panel.Status.Text,"重複"),"item save leaves key draft untouched")
    panel.Stage.Call("^+f")
    Assert(!panel.SaveButton.Enabled,"reverting key clears dirty state")
    panel.Stage.Call("^+j")
    savedPath := SettingsDatabasePath, SettingsDatabasePath := A_ScriptDir "\missing\draft.db"
    panel.Save.Call()
    SettingsDatabasePath := savedPath
    Assert(panel.SaveButton.Enabled && InStr(panel.Status.Text,"保存できません"),"failed save retains draft")
    global DiscardCalls := 0, AllowDiscard := false
    RuntimePorts.ConfirmDiscard := ConfirmDraftDiscard
    WinClose("ahk_id " panel.Window.Hwnd)
    deadline := A_TickCount+2000
    while DiscardCalls<1 && A_TickCount<deadline
        Sleep(10)
    Assert(ActiveEditorDialog && ActiveEditorDialog.Window=panel.Window && DiscardCalls=1 && DllCall("IsWindowVisible","Ptr",panel.Window.Hwnd)
        && panel.SaveButton.Enabled,"cancel native close keeps the editor visible with its draft")
    AllowDiscard := true
    Assert(SharedDanmakuItems[-1].Slot=0,"screen can unassign an item without deleting it")
    panel.Reset.Call(), panel.Close.Call()
    Assert(CanonicalShortcutKey(GetShortcutKey("chat_focus"))="^+f" && !ActiveEditorDialog,"closing unsaved defaults does not apply them")
    panel := ShowShortcutManager()
    panel.Close.Call()
    Assert(!ActiveEditorDialog && DiscardCalls=2,"unchanged editor closes without confirmation")
    panel := ShowShortcutManager()
    panel.First.Choose(1), panel.Second.Choose(1), panel.UpdateItems.Call()
    AllowDiscard := false
    WinClose("ahk_id " panel.Window.Hwnd)
    deadline := A_TickCount+2000
    while DiscardCalls<3 && A_TickCount<deadline
        Sleep(10)
    Assert(ActiveEditorDialog && ActiveEditorDialog.Window=panel.Window && DiscardCalls=3 && DllCall("IsWindowVisible","Ptr",panel.Window.Hwnd)
        && panel.First.Value=1 && panel.Second.Value=1,"item-only draft stays visible after cancelled native close")
    panel.Scope.Choose(2), panel.ChangeScope.Call()
    Assert(panel.Scope.Value=1 && panel.Second.Value=1,"cancel scope switch preserves draft")
    AllowDiscard := true, panel.Close.Call()
    RuntimePorts.ConfirmDiscard := 0
    SaveShortcutMap(saved)
'@ -Helpers @'
GetDlgCtrlID(hwnd) {
    return DllCall("GetDlgCtrlID","Ptr",hwnd,"Int")
}
ConfirmDraftDiscard(message) {
    global DiscardCalls
    DiscardCalls += 1
    return AllowDiscard
}
'@
