# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
$startup = New-TestRuntime
Invoke-AhkTest -Runtime $startup -Source @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
global ApplicationShortcutsInstalled := false, ShortcutKeys := DefaultShortcutKeys()
global StartupBindings := Map(), StartupCalls := [], StartupFailure := "shared1", CleanupFailure := ""
global PublishedDuringInstall := false
RuntimePorts.ShortcutKey := StartupBindingAdapter
ApplyPreferences(CreateDefaultSettings(),false)
Assert(!ApplicationShortcutsInstalled && StartupCalls.Length=0,"loading preferences before startup does not register hotkeys")
ShortcutKeys["chat_clear"] := "", ShortcutKeys["palette"] := "^+q"
beforeCritical := A_IsCritical, message := ""
try InstallApplicationShortcuts()
catch as failure
    message := failure.Message
Assert(InStr(message,"startup registration failure"),"initial registration reports its failure")
Assert(!ApplicationShortcutsInstalled,"failed initial registration is not published as installed")
Assert(!PublishedDuringInstall,"initial registration remains unpublished while bindings are being installed")
Assert(StartupBindings.Count=0,"failed initial registration removes every installed binding")
Assert(A_IsCritical=beforeCritical,"failed initial registration restores caller interruption state")
StartupFailure := ""
Critical(23)
InstallApplicationShortcuts()
Assert(A_IsCritical=23,"successful installation preserves caller interruption state")
Critical(beforeCritical)
Assert(ApplicationShortcutsInstalled && StartupBindings.Count=9,"retry installs all assigned keys")
for action,key in ShortcutKeys
    Assert(key="" ? !StartupBindings.Has(action) : StartupBindings[action]==key,"retry respects the configured assignment for " action)
callCount := StartupCalls.Length
InstallApplicationShortcuts()
Assert(StartupCalls.Length=callCount,"repeated installation does not register the same bindings again")
; Simulate a new startup whose rollback has one failure; other cleanup must continue.
ApplicationShortcutsInstalled := false, StartupBindings := Map(), StartupCalls := []
StartupFailure := "shared1", CleanupFailure := "palette", message := ""
try InstallApplicationShortcuts()
catch as failure
    message := failure.Message
Assert(InStr(message,"startup registration failure") && InStr(message,"startup cleanup failure")
    && InStr(message,"再起動"),"incomplete startup rollback reports original and cleanup failures")
Assert(!ApplicationShortcutsInstalled && StartupBindings.Count=1 && StartupBindings.Has("palette"),"failed cleanup does not prevent remaining bindings from being removed")
Assert(A_IsCritical=beforeCritical,"cleanup failure restores caller interruption state")
FileAppend("PASS: " Checks " shortcut installation checks`n","*")
ExitApp()
StartupBindingAdapter(action,key,enabled) {
    global PublishedDuringInstall
    PublishedDuringInstall := PublishedDuringInstall || ApplicationShortcutsInstalled
    StartupCalls.Push({Action:action,Key:key,Enabled:enabled})
    if enabled && action=StartupFailure
        throw Error("startup registration failure")
    if !enabled && action=CleanupFailure
        throw Error("startup cleanup failure")
    if enabled
        StartupBindings[action] := key
    else if StartupBindings.Has(action)
        StartupBindings.Delete(action)
}
'@
Invoke-AppFixture -Body @'
    global BindingCalls := [], FailBinding := "", FailCleanup := "", FailRestore := ""
    RuntimePorts.ShortcutKey := KeyAdapter
    InstallApplicationShortcuts()
    saved := CurrentShortcutMap()
    keys := saved.Clone()
    keys["palette"] := "^+q", keys["chat_focus"] := "^!q", keys["stop"] := "^+s"
    SaveShortcutMap(keys)
    persisted := LoadSettings(SettingsDatabasePath).ShortcutKeys.Clone()
    Assert(GetShortcutKey("palette")="^+q" && persisted["chat_focus"]="^!q" && persisted["stop"]="^+s","all action keys persist including formerly reserved keys and stop")
    keys["chat_clear"] := "!^Q"
    rejected := false
    try SaveShortcutMap(keys)
    catch
        rejected := true
    Assert(rejected && GetShortcutKey("chat_clear")=saved["chat_clear"],"canonical duplicate rejected without changing live keys")
    keys := CurrentShortcutMap(), left := keys["chat_focus"], keys["chat_focus"] := keys["chat_clear"], keys["chat_clear"] := left
    SaveShortcutMap(keys)
    Assert(GetShortcutKey("chat_clear")=left,"two existing keys can be swapped atomically")
    baseline := CurrentShortcutMap(), keys := baseline.Clone(), keys["chat_focus"] := "^+f"
    savedPath := SettingsDatabasePath, SettingsDatabasePath := A_ScriptDir "\missing\keys.db"
    rejected := false, persistenceFailure := ""
    try SaveShortcutMap(keys)
    catch as failure {
        rejected := true, persistenceFailure := failure.Message
    }
    SettingsDatabasePath := savedPath
    Assert(rejected && GetShortcutKey("chat_focus")=baseline["chat_focus"],"persistence failure restores active key")
    Assert(BindingCalls[-1].Key=baseline["chat_focus"] && BindingCalls[-1].Enabled,"previous binding restored after failure")
    FailBinding := "^+f", rejected := false
    try SaveShortcutMap(keys)
    catch
        rejected := true
    Assert(rejected && GetShortcutKey("chat_focus")=baseline["chat_focus"],"registration failure leaves preferences unchanged")
    FailBinding := ""
    keys := baseline.Clone(), keys["chat_focus"] := "^+f", keys["chat_clear"] := "^+d", keys["reactions_show"] := "^+e"
    FailCleanup := keys["chat_focus"], FailRestore := baseline["chat_focus"], BindingCalls := []
    SettingsDatabasePath := A_ScriptDir "\missing\keys.db", rollbackMessage := ""
    try SaveShortcutMap(keys)
    catch as failure
        rollbackMessage := failure.Message
    SettingsDatabasePath := savedPath
    cleanupAttempts := 0, restoreAttempts := 0
    for call in BindingCalls {
        if !call.Enabled && call.Key=keys[call.Action]
            cleanupAttempts++
        if call.Enabled && call.Key=baseline[call.Action]
            restoreAttempts++
    }
    Assert(cleanupAttempts=3 && restoreAttempts=3,"rollback attempts every removal and restoration despite two failures")
    Assert(InStr(rollbackMessage,persistenceFailure) && InStr(rollbackMessage,"synthetic cleanup failure")
        && InStr(rollbackMessage,"synthetic restore failure") && InStr(rollbackMessage,"再起動"),"incomplete rollback reports original cause and every recovery failure")
    persisted := LoadSettings(SettingsDatabasePath).ShortcutKeys
    Assert(persisted["chat_focus"]==baseline["chat_focus"] && GetShortcutKey("chat_focus")==baseline["chat_focus"],"incomplete native rollback does not publish or persist the rejected draft")
    FailCleanup := "", FailRestore := ""
    SaveShortcutMap(saved)
    shared := ExecuteDanmakuCommand("add","","",{Name:"first",Text:"first",Slot:1})
    ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second",Slot:2})
    firstId := SharedDanmakuItems[shared.Index].Id, secondId := SharedDanmakuItems[-1].Id
    SaveShortcutItemAssignments("",secondId,firstId)
    Assert(SharedDanmakuItems[shared.Index].Slot=2 && SharedDanmakuItems[-1].Slot=1,"item slot swap retains identity")
    panel := ShowShortcutManager("chat_focus")
    Assert(panel.List.GetCount()=10 && ActiveEditorDialog,"one screen contains every action")
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
    panel.Close.Call()
    Assert(ActiveEditorDialog && DiscardCalls=1,"cancel close retains editor and draft")
    AllowDiscard := true
    Assert(SharedDanmakuItems[-1].Slot=0,"screen can unassign an item without deleting it")
    panel.Reset.Call(), panel.Close.Call()
    Assert(CanonicalShortcutKey(GetShortcutKey("chat_focus"))="^+f" && !ActiveEditorDialog,"closing unsaved defaults does not apply them")
    panel := ShowShortcutManager()
    panel.Close.Call()
    Assert(!ActiveEditorDialog && DiscardCalls=2,"unchanged editor closes without confirmation")
    panel := ShowShortcutManager()
    panel.First.Choose(1), panel.Second.Choose(1), panel.UpdateItems.Call()
    AllowDiscard := false, panel.Close.Call()
    Assert(ActiveEditorDialog && DiscardCalls=3,"item-only dirty draft also blocks cancelled close")
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
KeyAdapter(action,key,enabled) {
    BindingCalls.Push({Action:action,Key:key,Enabled:enabled})
    if !enabled && key=FailCleanup
        throw Error("synthetic cleanup failure")
    if enabled && key=FailRestore
        throw Error("synthetic restore failure")
    if enabled && key=FailBinding
        throw Error("synthetic registration failure")
}
'@
