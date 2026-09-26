# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime = New-TestRuntime
$source = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
#Include %A_ScriptDir%\library-model.ahk
global SettingsDatabasePath := A_ScriptDir "\settings.db", ApplicationShortcutsInstalled := false, LibraryHistory := []
OnExit(CloseSettingsStore)
state := CreateDefaultSettings()
state.Profiles := [{Id:"service-input",Name:"Input",Channel:"/channel/input",Items:[]}]
state.InputProfileId := "service-input"
OpenSettingsRepository(SettingsDatabasePath).SaveAll(state)
ReloadAppSettings()
; Commands are executable without controls or an editing selection.
author := ExecuteProfileCommand("add","","service author")
id := author.ProfileId
added := ExecuteDanmakuCommand("add",id,"",{Name:"first",Text:"aaa",Slot:1})
firstId := FindProfileById(Profiles,id).Items[added.Index].Id
ExecuteDanmakuCommand("add",id,"",{Name:"second",Text:"bbb",Slot:2})
ExecuteDanmakuCommand("down",id,firstId)
serviceItems := GetLibraryItems(CreateTestLibrarySnapshot(),id)
Assert(serviceItems[2].Text="aaa" && serviceItems[2].Slot=1,"service reorder preserves assignment")
ExecuteDanmakuCommand("edit",id,firstId,{Name:"edited",Text:"ccc",Slot:2})
serviceItems := GetLibraryItems(CreateTestLibrarySnapshot(),id)
Assert(serviceItems[1].Slot=0 && serviceItems[2].Text="ccc","service edit assigns slot uniquely")
noOpItem := serviceItems[2], noOpHistory := LibraryHistory.Length, noOpProfiles := Profiles
Loop 35 {
    ExecuteDanmakuCommand("edit",id,firstId,{Name:"  " noOpItem.Name "  ",Text:noOpItem.Text,Slot:noOpItem.Slot})
    SaveShortcutItemAssignments(id,noOpItem.Slot=1 ? noOpItem.Id : "",noOpItem.Slot=2 ? noOpItem.Id : "")
}
Assert(LibraryHistory.Length=noOpHistory && Profiles=noOpProfiles,"unchanged item edits and assignments preserve real history and live objects")
ExecuteDanmakuCommand("duplicate",id,firstId)
Assert(GetLibraryItems(CreateTestLibrarySnapshot(),id)[3].Slot=0,"service duplicate is unassigned")
sharedCount := SharedDanmakuItems.Length
ExecuteDanmakuCommand("move",id,firstId,0,"")
Assert(SharedDanmakuItems.Length=sharedCount+1 && SharedDanmakuItems[-1].Slot=0,"service move clears slot")
UndoLibraryCommand()
Assert(SharedDanmakuItems.Length=sharedCount && GetLibraryItems(CreateTestLibrarySnapshot(),id)[2].Text="ccc","service undo restores both scopes")
ExecuteProfileCommand("bind",id,"/channel/service-only")
conflict := ExecuteProfileCommand("add","","conflict")
rejected := false
try ExecuteProfileCommand("bind",conflict.ProfileId,"/channel/service-only")
catch
    rejected := true
Assert(rejected,"service enforces unique channel binding")
beforeProfiles := Profiles.Length, beforeHistory := LibraryHistory.Length
rejected := false
try ExecuteProfileCommand("add",id,"duplicate channel","/channel/service-only")
catch
    rejected := true
Assert(rejected && Profiles.Length=beforeProfiles && LibraryHistory.Length=beforeHistory,"adding rejects another channel owner even with an existing ID argument")
beforeNoOpProfiles := Profiles
ExecuteProfileCommand("bind",id,"/channel/service-only")
Assert(LibraryHistory.Length=beforeHistory && Profiles=beforeNoOpProfiles,"unchanged binding preserves history and published library")
Assert(FindProfileByChannel(Profiles,"/channel/service-only").Id==id,"binding the same channel to its owner remains valid")
ExecuteProfileCommand("rename",id,"renamed author")
Assert(Profiles[FindProfileIndexById(Profiles,id)].Name="renamed author","service rename")
ExecuteProfileCommand("unbind",id)
Assert(!FindProfileByChannel(Profiles,"/channel/service-only"),"service unbind removes channel match")
beforeNoOpHistory := LibraryHistory.Length, lastRealChange := LibraryHistory[-1], beforeNoOpProfiles := Profiles
Loop 35 {
    ExecuteProfileCommand("rename",id,"  renamed author  ")
    ExecuteProfileCommand("unbind",id)
}
Assert(LibraryHistory.Length=beforeNoOpHistory && LibraryHistory[-1]=lastRealChange && Profiles=beforeNoOpProfiles,"repeated unchanged edits cannot evict real undo history")
Assert(GetInputProfile().Id=="service-input","service commands preserve input identity")
stale := CreateTestSettingsSnapshot()
SaveReactionDefaults(CreateReactionOptions(4,10,50))
stale.DefaultReactionKind := 1
CommitTestLibraryChange(stale,"stale caller")
actualState := LoadSettings(SettingsDatabasePath)
Assert(actualState.DefaultReactionKind=4 && DefaultReactionKind=4,"library commit cannot overwrite other preferences")
beforeFailure := CreateTestLibrarySnapshot(), historySize := LibraryHistory.Length
rejected := false
try ExecuteDanmakuCommand("edit",id,FindProfileById(Profiles,id).Items[1].Id,{Name:"invalid",Text:"first`nsecond",Slot:1})
catch
    rejected := true
Assert(rejected && LibraryHistory.Length=historySize && GetLibraryItems(CreateTestLibrarySnapshot(),id)[1].Text=GetLibraryItems(beforeFailure,id)[1].Text,"failed command preserves data and history")
rejected := false
try ExecuteDanmakuCommand("add","missing-id","",{Name:"x",Text:"y",Slot:0})
catch
    rejected := true
Assert(rejected,"commands reject missing profile IDs")
optional := ExecuteDanmakuCommand("add","","",{Name:"optional slot",Text:"optional body"})
optionalId := SharedDanmakuItems[optional.Index].Id
Assert(SharedDanmakuItems[optional.Index].Slot=0 && LoadSettings(SettingsDatabasePath).SharedDanmakuItems[optional.Index].Slot=0,"omitted command assignment is normalized once before publication and persistence")
SaveShortcutItemAssignments("",optionalId,"")
ExecuteDanmakuCommand("edit","",optionalId,{Name:"optional slot",Text:"edited optional body"})
Assert(SharedDanmakuItems[optional.Index].Slot=0,"omitted edit assignment keeps the existing unassignment behavior")
UndoLibraryCommand()
Assert(SharedDanmakuItems[optional.Index].Slot=1,"undo restores the explicit assignment")
Assert(!IsSet(PaletteWindow) && !IsSet(EditingProfileId) && !ApplicationShortcutsInstalled && !WorkerState.ProcessHandle,
    "library services require no application windows, editing selection, registered keys or worker")
FileAppend("PASS: " Checks " library service checks; no application initialization`n","*")
ExitApp()
'@
Invoke-AhkTest -Runtime $runtime -Source $source
