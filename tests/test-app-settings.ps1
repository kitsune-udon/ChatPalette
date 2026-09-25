# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    preferences := CreatePreferences()
    Assert(!preferences.HasOwnProp("Profiles") && !preferences.HasOwnProp("SharedDanmakuItems"),"preferences carry no library payload")
    Assert(preferences.ShortcutKeys.Count=10 && !preferences.HasOwnProp("ReactionShortcut"),"all shortcuts have one state owner")
    modeBefore := AutoMode, modeChange := CreatePreferences()
    modeChange.AutoMode := !modeBefore
    ApplyPreferences(modeChange)
    Assert(AutoMode=modeChange.AutoMode && LoadSettings(SettingsDatabasePath).AutoMode=modeChange.AutoMode,"common preference commit publishes auto mode after saving")
    modeChange.AutoMode := modeBefore
    ApplyPreferences(modeChange)
    ; A captured reaction draft must not own or overwrite later key assignments.
    reactionDraft := PaletteOptions(), reactionDraft.Reaction := DefaultReactionKind=1 ? 2 : 1
    savedKeys := CurrentShortcutMap(), changedKeys := savedKeys.Clone(), changedKeys["reaction"] := "^+r"
    SaveShortcutMap(changedKeys)
    global KeyCalls := []
    SaveReactionDefaults(reactionDraft)
    persisted := LoadSettings(SettingsDatabasePath)
    Assert(GetShortcutKey("reaction")=="^+r" && persisted.ShortcutKeys["reaction"]=="^+r" && KeyCalls.Length=0,"reaction defaults preserve a subsequently changed key without registration")
    Assert(persisted.DefaultReactionKind=reactionDraft.Reaction && persisted.DefaultReactionCount=reactionDraft.Count
        && persisted.DefaultReactionIntervalMs=reactionDraft.Interval,"reaction draft still saves its kind, count and interval")
    SaveShortcutMap(savedKeys)
    SaveReactionDefaults(CreateReactionOptions(preferences.DefaultReactionKind,preferences.DefaultReactionCount,preferences.DefaultReactionIntervalMs))
    libraryBefore := Profiles, sharedBefore := SharedDanmakuItems, historyBefore := LibraryHistory.Length
    preferences.DefaultReactionCount := 10
    SaveSettingsPreferences(preferences,SettingsDatabasePath)
    Assert(LoadSettings(SettingsDatabasePath).DefaultReactionCount=10,"dedicated preference API persists without a library")
    Assert(Profiles=libraryBefore && SharedDanmakuItems=sharedBefore && LibraryHistory.Length=historyBefore,"preference persistence leaves library and history untouched")
    SaveSettingsPreferences(CreatePreferences(),SettingsDatabasePath)
    KeyCalls := []
    oldPreferences := CreatePreferences(), savedPath := SettingsDatabasePath
    SettingsDatabasePath := A_ScriptDir "\missing\preferences.db"
    failed := false
    combinedChange := CreatePreferences(), combinedChange.DefaultReactionKind := 2, combinedChange.DefaultReactionCount := 10
    combinedChange.DefaultReactionIntervalMs := 25, combinedChange.ShortcutKeys["reaction"] := "^+r"
    try ApplyPreferences(combinedChange)
    catch
        failed := true
    SettingsDatabasePath := savedPath
    Assert(failed && ShortcutKeys["reaction"]=oldPreferences.ShortcutKeys["reaction"] && DefaultReactionCount=oldPreferences.DefaultReactionCount,"failed preference save preserves live defaults")
    Assert(KeyCalls.Length=4 && KeyCalls[4].Key=oldPreferences.ShortcutKeys["reaction"] && KeyCalls[4].Enabled && KeyCalls[3].Key="^+r" && !KeyCalls[3].Enabled,"failed preference save restores old hotkey and removes new key")
    SettingsDatabasePath := A_ScriptDir "\missing\preferences.db"
    failed := false
    try SaveAutoDetection(!AutoMode)
    catch
        failed := true
    SettingsDatabasePath := savedPath
    Assert(failed && AutoMode=oldPreferences.AutoMode,"failed auto mode save leaves live state unchanged")
    reloaded := CreatePreferences()
    reloaded.DefaultReactionCount := 10, reloaded.ShortcutKeys["reaction"] := "^+r"
    SaveSettingsPreferences(reloaded,SettingsDatabasePath)
    KeyCalls := []
    ReloadAppSettings()
    Assert(DefaultReactionCount=10 && ShortcutKeys["reaction"]="^+r","reload publishes saved defaults and shortcut together")
    Assert(KeyCalls.Length=2 && !KeyCalls[1].Enabled && KeyCalls[2].Enabled,"reload changes each affected binding once")
    SaveSettingsPreferences(oldPreferences,SettingsDatabasePath)
    ReloadAppSettings()
    priorKey := ShortcutKeys["reaction"]
    failed := false
    conflictingKeys := CurrentShortcutMap(), conflictingKeys["reaction"] := "^!q"
    try SaveShortcutMap(conflictingKeys)
    catch
        failed := true
    Assert(failed && ShortcutKeys["reaction"]=priorKey,"duplicate key rejected transactionally")
    for interval in ReactionIntervals {
        SaveReactionDefaults(CreateReactionOptions(1,1,interval))
        Assert(LoadSettings(SettingsDatabasePath).DefaultReactionIntervalMs=interval,"interval persisted " interval)
    }
    for count in ReactionCounts {
        job := CreateReactionJob({StartedAt:0,Total:count,Completed:count-1,Cancelled:false,Interval:100})
        ActiveReactionJob := job
        ApplyReactionResult(job,{State:"operated"})
        Assert(job.Completed=count && !ActiveReactionJob,"exact completion " count)
    }

    schemaPath := A_ScriptDir "\schema-check.db"
    schemaState := CreateTestSettingsSnapshot()
    schemaState.SharedDanmakuItems := [
        {Id:"quotes-label",Name:Chr(34) "quoted label" Chr(34), Text:"  👏👏  ",Slot:0},
        {Id:"quotes-body",Name:"quoted text", Text:Chr(34) "👏" Chr(34),Slot:0},
        {Id:"single-quotes",Name:"single quotes", Text:"'👏'",Slot:0}]
    OpenSettingsRepository(schemaPath).SaveAll(schemaState)
    roundTrip := LoadSettings(schemaPath)
    for i, expected in schemaState.SharedDanmakuItems {
        Assert(roundTrip.SharedDanmakuItems[i].Name == expected.Name, "database preserves label quotes")
        Assert(roundTrip.SharedDanmakuItems[i].Text == expected.Text, "database preserves literal text and spaces")
    }
    longText := ""
    Loop 35000
        longText .= "👏"
    for length in [32767, 65534, 70000] {
        expected := SubStr(longText, 1, length - Mod(length, 2))
        schemaState.SharedDanmakuItems := [{Id:"long-shared",Name:"long",Text:expected,Slot:0}]
        schemaState.Profiles[1].Items := [{Id:"long-profile",Name:"long",Text:expected,Slot:0}]
        OpenSettingsRepository(schemaPath).SaveAll(schemaState)
        actual := LoadSettings(schemaPath)
        Assert(actual.SharedDanmakuItems[1].Text == expected, "long shared text round-trip " length)
        Assert(actual.Profiles[1].Items[1].Text == expected, "long profile text round-trip " length)
    }
    LastReactionResult.Detail := "previous failure"
    completedJob := CreateReactionJob({StartedAt:0,Completed:0, Total:1, Cancelled:false})
    ActiveReactionJob := completedJob
    ApplyReactionResult(completedJob, {State:"operated"})
    Assert(LastReactionResult.Detail = "" && InStr(LastReactionResult.Message, "完了"), "success clears previous failure detail")
    savedRoundTrip := FileRead(schemaPath,"RAW")
    schemaState.SharedDanmakuItems[1].Text := "first`nsecond"
    rejected := false
    try OpenSettingsRepository(schemaPath).SaveAll(schemaState)
    catch
        rejected := true
    Assert(rejected && SameFileBytes(FileRead(schemaPath,"RAW"),savedRoundTrip) && !FileExist(schemaPath ".new"), "multiline text cannot corrupt persisted database")
    schemaState.SharedDanmakuItems[1].Text := "👏"
    bulkState := CreateTestSettingsSnapshot()
    bulkState.Profiles := [], bulkState.InputProfileId := ""
    Loop 50 {
        bulkProfile := {Name:"配信者" A_Index,Channel:"/channel/fixture" A_Index,Id:NewRecordId(),Items:[]}
        Loop 10
            bulkProfile.Items.Push({Id:NewRecordId(),Name:"弾幕" A_Index,Text:"  👏" Chr(34) "引用符" Chr(34) "👏  ",Slot:0})
        bulkState.Profiles.Push(bulkProfile)
    }
    OpenSettingsRepository(schemaPath).SaveAll(bulkState)
    bulkRead := LoadSettings(schemaPath)
    Assert(bulkRead.Profiles.Length = 50, "bulk save retains all sections")
    for i, profile in bulkRead.Profiles {
        Assert(profile.Name == bulkState.Profiles[i].Name && profile.Items.Length = 10, "bulk save retains author and count")
        for j, item in profile.Items
            Assert(item.Text == bulkState.Profiles[i].Items[j].Text, "bulk save preserves unicode quotes and spaces")
    }
    diskBeforeLock := LoadSettings(schemaPath)
    blocker := SqliteConnection(schemaPath)
    blocker.Exec("BEGIN IMMEDIATE")
    failed := false
    try OpenSettingsRepository(schemaPath).SaveAll(schemaState)
    catch
        failed := true
    finally {
        blocker.Exec("ROLLBACK"), blocker.Close()
    }
    Assert(failed && LoadSettings(schemaPath).Profiles.Length=diskBeforeLock.Profiles.Length,"competing writer preserves database")
    ReactionCounts.Push(7)
    ReactionIntervals.Push(75)
    try {
        schemaState.DefaultReactionCount := 7
        schemaState.DefaultReactionIntervalMs := 75
        OpenSettingsRepository(schemaPath).SaveAll(schemaState)
        schemaRead := LoadSettings(schemaPath)
        Assert(schemaRead.DefaultReactionCount = 7 && schemaRead.DefaultReactionIntervalMs = 75, "store accepts options from shared schema")
        Assert(SettingOptionLabels(ReactionCounts, "回")[-1] = "7回" && SettingOptionLabels(ReactionIntervals, " ms")[-1] = "75 ms", "UI labels follow shared schema")
    } finally {
        ReactionCounts.Pop()
        ReactionIntervals.Pop()
        CloseSettingsStore()
        FileDelete(schemaPath)
    }

'@ -Helpers @'
SameFileBytes(left,right) {
    return left.Size=right.Size && (!left.Size || DllCall("msvcrt\memcmp","Ptr",left,"Ptr",right,"UPtr",left.Size,"CDecl Int")=0)
}

'@
