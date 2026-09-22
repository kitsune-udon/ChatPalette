# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    preferences := CreatePreferences()
    Assert(!preferences.HasOwnProp("Profiles") && !preferences.HasOwnProp("SharedDanmakuItems"),"preferences carry no library payload")
    libraryBefore := Profiles, sharedBefore := SharedDanmakuItems, historyBefore := LibraryHistory.Length
    preferences.DefaultReactionCount := 10
    SaveSettingsPreferences(preferences,SettingsDatabasePath)
    Assert(LoadSettings(SettingsDatabasePath).DefaultReactionCount=10,"dedicated preference API persists without a library")
    Assert(Profiles=libraryBefore && SharedDanmakuItems=sharedBefore && LibraryHistory.Length=historyBefore,"preference persistence leaves library and history untouched")
    SaveSettingsPreferences(CreatePreferences(),SettingsDatabasePath)
    global KeyCalls := []
    oldPreferences := CreatePreferences(), savedPath := SettingsDatabasePath
    SettingsDatabasePath := A_ScriptDir "\missing\preferences.db"
    failed := false
    try SaveReactionDefaults(CreateReactionOptions(2,10,25,"^+r"))
    catch
        failed := true
    SettingsDatabasePath := savedPath
    Assert(failed && ReactionShortcut=oldPreferences.ReactionShortcut && DefaultReactionCount=oldPreferences.DefaultReactionCount,"failed preference save preserves live defaults")
    Assert(KeyCalls.Length=4 && KeyCalls[4].Key=oldPreferences.ReactionShortcut && KeyCalls[4].Enabled && KeyCalls[3].Key="^+r" && !KeyCalls[3].Enabled,"failed preference save restores old hotkey and removes new key")
    priorKey := ReactionShortcut
    failed := false
    try SaveReactionDefaults(CreateReactionOptions(1,1,100,"^!q"))
    catch
        failed := true
    Assert(failed && ReactionShortcut=priorKey,"reserved key rejected transactionally")
    for interval in ReactionIntervals {
        SaveReactionDefaults(CreateReactionOptions(1,1,interval,priorKey))
        Assert(LoadSettings(SettingsDatabasePath).DefaultReactionIntervalMs=interval,"interval persisted " interval)
    }
    for count in ReactionCounts {
        job := CreateReactionJob({StartedAt:0,Total:count,Completed:count-1,Cancelled:false,Interval:100})
        ActiveReactionJob := job
        ApplyReactionResult(job,{State:"operated"})
        Assert(job.Completed=count && !ActiveReactionJob,"exact completion " count)
    }

    schemaPath := A_ScriptDir "\schema-check.db"
    schemaState := CreateSettingsSnapshot()
    schemaState.SharedDanmakuItems := [
        {Name:Chr(34) "quoted label" Chr(34), Text:"  👏👏  "},
        {Name:"quoted text", Text:Chr(34) "👏" Chr(34)},
        {Name:"single quotes", Text:"'👏'"}]
    SaveSettings(schemaState, schemaPath)
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
        schemaState.SharedDanmakuItems := [{Name:"long",Text:expected}]
        schemaState.Profiles[1].Items := [{Name:"long",Text:expected}]
        SaveSettings(schemaState, schemaPath)
        actual := LoadSettings(schemaPath)
        Assert(actual.SharedDanmakuItems[1].Text == expected, "long shared text round-trip " length)
        Assert(actual.Profiles[1].Items[1].Text == expected, "long profile text round-trip " length)
    }
    legacyPath := A_ScriptDir "\legacy-reader.ini"
    legacyText := "; comment`r`n[general]`r`nCount=0`r`n[commondanmaku]`r`nCount=2`r`nLabel1=' legacy '`r`nText1=" Chr(34) "  a=b;👏  " Chr(34) "`r`nLabel2=plain`r`nText2=  unquoted  `r`n"
    for encoding in ["UTF-16", "UTF-8"] {
        if FileExist(legacyPath)
            FileDelete(legacyPath)
        FileAppend(legacyText, legacyPath, encoding)
        legacy := ReadLegacySettings(legacyPath)
        Assert(legacy.SharedDanmakuItems[1].Name == " legacy " && legacy.SharedDanmakuItems[1].Text == "  a=b;👏  ", "legacy quotes, case and BOM " encoding)
        Assert(legacy.SharedDanmakuItems[2].Text == "unquoted", "legacy unquoted whitespace " encoding)
    }
    LastReactionResult.Detail := "previous failure"
    completedJob := CreateReactionJob({StartedAt:0,Completed:0, Total:1, Cancelled:false})
    ActiveReactionJob := completedJob
    ApplyReactionResult(completedJob, {State:"operated"})
    Assert(LastReactionResult.Detail = "" && InStr(LastReactionResult.Message, "完了"), "success clears previous failure detail")
    savedRoundTrip := FileRead(schemaPath,"RAW")
    schemaState.SharedDanmakuItems[1].Text := "first`nsecond"
    rejected := false
    try SaveSettings(schemaState, schemaPath)
    catch
        rejected := true
    Assert(rejected && SameFileBytes(FileRead(schemaPath,"RAW"),savedRoundTrip) && !FileExist(schemaPath ".new"), "multiline text cannot corrupt persisted database")
    schemaState.SharedDanmakuItems[1].Text := "👏"
    bulkState := CreateSettingsSnapshot()
    bulkState.Profiles := [], bulkState.InputProfileId := ""
    Loop 50 {
        bulkProfile := {Name:"配信者" A_Index,Channel:"/channel/fixture" A_Index,Id:NewRecordId(),Items:[]}
        Loop 10
            bulkProfile.Items.Push({Name:"弾幕" A_Index,Text:"  👏" Chr(34) "引用符" Chr(34) "👏  "})
        bulkState.Profiles.Push(bulkProfile)
    }
    SaveSettings(bulkState, schemaPath)
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
    try SaveSettings(schemaState,schemaPath)
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
        SaveSettings(schemaState, schemaPath)
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
