# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
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
$storage = New-TestRuntime
Invoke-AhkTest -Runtime $storage -Source @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
global SettingsDatabasePath := A_ScriptDir "\settings.db"
global ApplicationShortcutsInstalled := false, ShortcutKeys := DefaultShortcutKeys(), LibraryHistory := []
OnExit(CloseSettingsStore)
ReloadAppSettings()
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
FileAppend("PASS: " Checks " shortcut persistence and rollback checks; no application startup`n","*")
ExitApp()
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
