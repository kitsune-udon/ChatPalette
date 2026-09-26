# Test-Session: Headless
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
    RuntimePorts.ShortcutKey := (action,key,enabled) => KeyCalls.Push({Key:key,Enabled:enabled})
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
    for interval in ReactionIntervals {
        SaveReactionDefaults(CreateReactionOptions(1,1,interval))
        Assert(LoadSettings(SettingsDatabasePath).DefaultReactionIntervalMs=interval,"interval persisted " interval)
    }
    RuntimePorts.BrowserRequest := (*) => {State:"operated"}
    for count in ReactionCounts {
        job := CreateReactionJob({Window:123,Total:count,Completed:count-1,Interval:0})
        ActiveReactionJob := job
        RunReactionSendLoop(job)
        Assert(job.Completed=count && !ActiveReactionJob,"exact completion " count)
    }

    LastReactionResult.Detail := "previous failure"
    completedJob := CreateReactionJob({Window:123,Total:1})
    ActiveReactionJob := completedJob
    RunReactionSendLoop(completedJob)
    RuntimePorts.BrowserRequest := 0
    Assert(LastReactionResult.Detail = "" && InStr(LastReactionResult.Message, "完了"), "success clears previous failure detail")
'@
