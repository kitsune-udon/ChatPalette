# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    ShowManagement(1)
    EditingProfileId := ""
    RefreshManagement()
    Assert(Profiles.Length > 0, "existing profiles loaded")
    Assert(!Profiles[1].HasOwnProp("Reaction"), "profile reaction setting removed")
    Assert(ItemSlot(Profiles[1].Items[1]) = 1, "old first preset keeps shortcut")

    initial := CreateSettingsSnapshot()
    initial.Profiles.Push({Id:NewRecordId(),Name:"editing B",Channel:"/channel/b",Items:[]})
    CommitLibraryChange(initial,"test author")
    SaveInputProfileSelection(1)
    activeId := GetInputProfile().Id
    EditingProfileId := Profiles[-1].Id
    RefreshManagement()
    Assert(GetInputProfile().Id = activeId, "editing another profile preserves active input target")
    state := CreateSettingsSnapshot()
    FindProfileById(state.Profiles,EditingProfileId).Items := [{Name:"B",Text:"bbb",Slot:1}]
    CommitLibraryChange(state,"B item")
    Assert(GetInputProfile().Id = activeId && FindProfileById(Profiles,EditingProfileId).Items.Length = 1,"editing commits without changing active target")
    EditingProfileId := Profiles[1].Id
    originalText := Profiles[1].Items[1].Text
    state := CreateSettingsSnapshot()
    first := state.Profiles[1].Items.RemoveAt(1)
    state.Profiles[1].Items.Push(first)
    CommitLibraryChange(state,"reorder")
    Assert(ItemSlot(Profiles[1].Items[-1]) = 1 && Profiles[1].Items[-1].Text = originalText,"shortcut follows item after reorder")
    state := CreateSettingsSnapshot()
    AssignItemSlot(state.Profiles[1].Items,1,1)
    CommitLibraryChange(state,"assign")
    Assert(ItemSlot(Profiles[1].Items[1]) = 1 && ItemSlot(Profiles[1].Items[-1]) = 0,"assignment moves uniquely")
    state := CreateSettingsSnapshot()
    state.Profiles[1].Items.RemoveAt(1)
    CommitLibraryChange(state,"delete")
    for item in Profiles[1].Items
        Assert(ItemSlot(item) != 1,"deletion leaves shortcut unassigned")
    historySize := LibraryHistory.Length
    UndoLibraryChange()
    Assert(LibraryHistory.Length = historySize-1 && ItemSlot(Profiles[1].Items[1])=1,"undo restores deleted assignment")
    UndoLibraryChange()
    Assert(ItemSlot(Profiles[1].Items[-1])=1,"multi-step undo restores previous assignment")
    beforeCount := Profiles.Length
    state := CreateSettingsSnapshot()
    state.Profiles.RemoveAt(1)
    CommitLibraryChange(state,"remove active")
    Assert(InputProfileId="","deleting active author never silently targets next author")
    UndoLibraryChange()
    Assert(Profiles.Length=beforeCount && InputProfileId="","undo restores author without selecting a different target")
    SaveInputProfileSelection(1)
    EditingProfileId := ""
    state := CreateSettingsSnapshot()
    state.SharedDanmakuItems := [{Name:"search target",Text:"unique body",Slot:1},{Name:"other",Text:"other",Slot:0}]
    CommitLibraryChange(state,"shared")
    PaletteSearch.Value := "unique body"
    RefreshPaletteItems()
    Assert(PaletteRows.Length=1 && PaletteRows[1].Shared,"search includes body and preserves scope")
    PaletteSearch.Value := ""
    SaveReactionDefaults(CreateReactionOptions(3,10,100,ReactionShortcut))
    ResetPaletteSession()
    PaletteCount.Choose(3)
    Assert(PaletteOptions().Count=100 && DefaultReactionCount=10,"session setting does not modify defaults")
    savedCount := DefaultReactionCount
    UndoLibraryChange()
    Assert(DefaultReactionCount=savedCount,"library undo never reverts reaction defaults")
    priorProfiles := Profiles, priorHistory := LibraryHistory.Length, path := SettingsDatabasePath
    SettingsDatabasePath := A_ScriptDir "\missing\cannot-save.ini"
    failed := false
    state := CreateSettingsSnapshot(), state.Profiles[1].Name := "not saved"
    try CommitLibraryChange(state,"failed")
    catch
        failed := true
    Assert(failed && Profiles=priorProfiles && LibraryHistory.Length=priorHistory,"failed save preserves live data and history")
    SettingsDatabasePath := path
    SaveInputProfileSelection(1)
    RefreshProfiles()
    ; Commands are executable without controls or an editing selection.
    author := ExecuteProfileCommand("add","","service author")
    id := author.ProfileId
    oldInputId := GetInputProfile() ? GetInputProfile().Id : ""
    added := ExecuteDanmakuCommand("add",id,0,{Name:"first",Text:"aaa",Slot:1})
    ExecuteDanmakuCommand("add",id,0,{Name:"second",Text:"bbb",Slot:2})
    ExecuteDanmakuCommand("down",id,1)
    serviceItems := GetLibraryItems(CreateLibrarySnapshot(),id)
    Assert(serviceItems[2].Text="aaa" && ItemSlot(serviceItems[2])=1,"service reorder preserves assignment")
    ExecuteDanmakuCommand("edit",id,2,{Name:"edited",Text:"ccc",Slot:2})
    serviceItems := GetLibraryItems(CreateLibrarySnapshot(),id)
    Assert(ItemSlot(serviceItems[1])=0 && serviceItems[2].Text="ccc","service edit assigns slot uniquely")
    ExecuteDanmakuCommand("duplicate",id,2)
    Assert(ItemSlot(GetLibraryItems(CreateLibrarySnapshot(),id)[3])=0,"service duplicate is unassigned")
    sharedCount := SharedDanmakuItems.Length
    ExecuteDanmakuCommand("move",id,2,0,"")
    Assert(SharedDanmakuItems.Length=sharedCount+1 && ItemSlot(SharedDanmakuItems[-1])=0,"service move clears slot")
    UndoLibraryCommand()
    Assert(SharedDanmakuItems.Length=sharedCount && GetLibraryItems(CreateLibrarySnapshot(),id)[2].Text="ccc","service undo restores both scopes")
    ExecuteProfileCommand("bind",id,"/channel/service-only")
    conflict := ExecuteProfileCommand("add","","conflict")
    rejected := false
    try ExecuteProfileCommand("bind",conflict.ProfileId,"/channel/service-only")
    catch
        rejected := true
    Assert(rejected,"service enforces unique channel binding")
    ExecuteProfileCommand("rename",id,"renamed author")
    Assert(Profiles[FindProfileIndexById(Profiles,id)].Name="renamed author","service rename")
    ExecuteProfileCommand("unbind",id)
    Assert(!ChannelIndex.Has("/channel/service-only"),"service unbind refreshes index")
    Assert((GetInputProfile() ? GetInputProfile().Id : "")=oldInputId,"service commands preserve input identity")
    stale := CreateSettingsSnapshot()
    SaveReactionDefaults(CreateReactionOptions(4,10,50,ReactionShortcut))
    stale.DefaultReactionKind := 1
    CommitLibraryChange(stale,"stale caller")
    actualState := LoadSettings(SettingsDatabasePath)
    Assert(actualState.DefaultReactionKind=4 && DefaultReactionKind=4,"library commit cannot overwrite other preferences")
    beforeFailure := CreateLibrarySnapshot(), historySize := LibraryHistory.Length
    rejected := false
    try ExecuteDanmakuCommand("edit",id,1,{Name:"invalid",Text:"first`nsecond",Slot:1})
    catch
        rejected := true
    Assert(rejected && LibraryHistory.Length=historySize && GetLibraryItems(CreateLibrarySnapshot(),id)[1].Text=GetLibraryItems(beforeFailure,id)[1].Text,"failed command preserves data and history")
    rejected := false
    try ExecuteDanmakuCommand("add","missing-id",0,{Name:"x",Text:"y",Slot:0})
    catch
        rejected := true
    Assert(rejected,"commands reject missing profile IDs")

'@
