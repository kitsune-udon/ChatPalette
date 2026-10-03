# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    ShowManagement(1)
    EditingProfileId := ""
    RefreshManagement()
    Assert(Profiles.Length > 0, "existing profiles loaded")
    Assert(!Profiles[1].HasOwnProp("Reaction"), "profile reaction setting removed")
    Assert(Profiles[1].Items[1].Slot = 1, "fixture first preset keeps shortcut")

    initial := CreateTestLibrarySnapshot()
    initial.Profiles.Push({Id:NewRecordId(),Name:"editing B",Channel:"/channel/b",Items:[]})
    CommitTestLibraryChange(initial,"test author")
    SaveInputProfileId(Profiles[1].Id)
    activeId := GetInputProfile().Id
    EditingProfileId := Profiles[-1].Id
    RefreshManagement()
    Assert(GetInputProfile().Id = activeId, "editing another profile preserves active input target")
    state := CreateTestLibrarySnapshot()
    FindProfileById(state.Profiles,EditingProfileId).Items := [{Id:"library-b",Name:"B",Text:"bbb",Slot:1}]
    CommitTestLibraryChange(state,"B item")
    Assert(GetInputProfile().Id = activeId && FindProfileById(Profiles,EditingProfileId).Items.Length = 1,"editing commits without changing active target")
    EditingProfileId := Profiles[1].Id
    originalText := Profiles[1].Items[1].Text
    state := CreateTestLibrarySnapshot()
    first := state.Profiles[1].Items.RemoveAt(1)
    state.Profiles[1].Items.Push(first)
    CommitTestLibraryChange(state,"reorder")
    Assert(Profiles[1].Items[-1].Slot = 1 && Profiles[1].Items[-1].Text = originalText,"shortcut follows item after reorder")
    state := CreateTestLibrarySnapshot()
    AssignItemSlot(state.Profiles[1].Items,1,1)
    CommitTestLibraryChange(state,"assign")
    Assert(Profiles[1].Items[1].Slot = 1 && Profiles[1].Items[-1].Slot = 0,"assignment moves uniquely")
    state := CreateTestLibrarySnapshot()
    state.Profiles[1].Items.RemoveAt(1)
    CommitTestLibraryChange(state,"delete")
    for item in Profiles[1].Items
        Assert(item.Slot != 1,"deletion leaves shortcut unassigned")
    historySize := LibraryHistory.Length
    UndoLibraryChange()
    Assert(LibraryHistory.Length = historySize-1 && Profiles[1].Items[1].Slot=1,"undo restores deleted assignment")
    UndoLibraryChange()
    Assert(Profiles[1].Items[-1].Slot=1,"multi-step undo restores previous assignment")
    beforeCount := Profiles.Length
    state := CreateTestLibrarySnapshot()
    state.Profiles.RemoveAt(1)
    CommitTestLibraryChange(state,"remove active")
    Assert(InputProfileId="","deleting active author never silently targets next author")
    UndoLibraryChange()
    Assert(Profiles.Length=beforeCount && InputProfileId="","undo restores author without selecting a different target")
    SaveInputProfileId(Profiles[1].Id)
    EditingProfileId := ""
    state := CreateTestLibrarySnapshot()
    state.SharedDanmakuItems := [{Id:"search-target",Name:"search target",Text:"unique body",Slot:1},{Id:"search-other",Name:"other",Text:"other",Slot:0}]
    CommitTestLibraryChange(state,"shared")
    PaletteSearch.Value := "unique body"
    RefreshPaletteItems()
    Assert(PaletteRows.Length=1 && PaletteRows[1].ProfileId="","search includes body and preserves scope")
    PaletteSearch.Value := ""
    SaveReactionDefaults(CreateReactionOptions(3,10,100))
    ResetPaletteSession()
    PaletteCount.Choose(3)
    Assert(PaletteOptions().Count=100 && DefaultReactionCount=10,"session setting does not modify defaults")
    savedCount := DefaultReactionCount
    UndoLibraryChange()
    Assert(DefaultReactionCount=savedCount,"library undo never reverts reaction defaults")
    priorProfiles := Profiles, priorHistory := LibraryHistory.Length, path := SettingsDatabasePath
    SettingsDatabasePath := A_ScriptDir "\missing\cannot-save.db"
    failed := false
    state := CreateTestLibrarySnapshot(), state.Profiles[1].Name := "not saved"
    try CommitTestLibraryChange(state,"failed")
    catch
        failed := true
    Assert(failed && Profiles=priorProfiles && LibraryHistory.Length=priorHistory,"failed save preserves live data and history")
    SettingsDatabasePath := path

'@

Invoke-AppFixture -Body @'
    CommitTestLibraryChange({Profiles:[
        {Id:"channel-a",Name:"same",Channel:"/channel/Case",Items:[]},
        {Id:"channel-b",Name:"same",Channel:"/channel/case",Items:[]},
        {Id:"unlinked",Name:"same",Channel:"",Items:[]}],SharedDanmakuItems:[]},"channel ownership fixture")
    global CurrentChannel := "/channel/Case"
    RuntimePorts.ResolveChannel := (*) => {State:"ok",Channel:CurrentChannel,Author:"fixture",Video:"abcdefghijk"}
    RuntimePorts.BrowserProcessName := (hwnd) => (hwnd=123) ? "chrome.exe" : ""
    TargetBrowserHwnd := 123, AutoMode := true
    Assert(SelectProfileFromBrowser(123) && InputProfileId == "channel-a" && GetPaletteInputProfile()=FindProfileById(Profiles,"channel-a"),"automatic selection matches the exact channel")
    CurrentChannel := "/channel/case"
    Assert(SelectProfileFromBrowser(123) && InputProfileId == "channel-b" && GetPaletteInputProfile()=FindProfileById(Profiles,"channel-b"),"channel case differences remain distinct")
    SaveInputProfileId("channel-a")
    Assert(!GetPaletteInputProfile(),"another linked profile is not a match for the detected channel")
    SelectProfileFromBrowser(123)
    ExecuteProfileCommand("unbind","channel-b")
    Assert(!GetPaletteInputProfile() && !SelectProfileFromBrowser(123),"unlink is visible immediately without selecting another profile")
    UndoLibraryCommand()
    Assert(GetPaletteInputProfile() && SelectProfileFromBrowser(123),"undo restores the channel match")
    ExecuteProfileCommand("bind","channel-b","/channel/new")
    Assert(!GetPaletteInputProfile(),"relink invalidates the previous detection")
    CurrentChannel := "/channel/new"
    Assert(SelectProfileFromBrowser(123) && InputProfileId == "channel-b","relink selects the new owner")
    UndoLibraryCommand()
    Assert(!GetPaletteInputProfile() && !SelectProfileFromBrowser(123),"undo removes the replaced channel binding")
    CurrentChannel := "/channel/case"
    SelectProfileFromBrowser(123)
    ExecuteProfileCommand("delete","channel-b")
    Assert(!GetPaletteInputProfile() && !SelectProfileFromBrowser(123),"deleted owner is not selected")
    UndoLibraryCommand()
    Assert(SelectProfileFromBrowser(123) && InputProfileId == "channel-b","undo makes the restored owner selectable")
    oldProfiles := Profiles, oldHistory := LibraryHistory.Length
    invalid := CreateTestLibrarySnapshot(), invalid.Profiles[1].Channel := "/channel/case"
    rejected := false
    try CommitTestLibraryChange(invalid,"duplicate channel")
    catch as failure
        rejected := InStr(failure.Message,"同じチャンネル")
    Assert(rejected && Profiles=oldProfiles && LibraryHistory.Length=oldHistory,"duplicate channels are rejected before state and history publication")
    saved := LoadSettings(SettingsDatabasePath)
    Assert(saved.Profiles[1].Channel == "/channel/Case" && saved.Profiles[2].Channel == "/channel/case","rejected duplicate preserves persisted bindings")
    ReloadAppSettings()
    Assert(SelectProfileFromBrowser(123) && InputProfileId == "channel-b" && GetPaletteInputProfile()=FindProfileById(Profiles,"channel-b"),"reload preserves selection from persisted channel data")
    for channel in ["","/channel/missing"] {
        CurrentChannel := channel
        Assert(!SelectProfileFromBrowser(123) && !GetPaletteInputProfile() && InputProfileId == "channel-b","empty or unknown channel never falls back to an unlinked profile")
    }
    SaveInputProfileId("unlinked"), CurrentChannel := ""
    Assert(!SelectProfileFromBrowser(123) && !GetPaletteInputProfile(),"an empty detected channel cannot match an unlinked input profile")
'@
