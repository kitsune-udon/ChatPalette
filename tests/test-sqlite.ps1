# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$repositoryAnchor = 'this.Db := SqliteConnection(path,create)'
Edit-TestSource $release 'src/settings/settings_repository.ahk' $repositoryAnchor ($repositoryAnchor + "`r`n        global ProbeRepositoryConnection := this.Db")
$tests = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
#Include %A_ScriptDir%\library-model.ahk
global SettingsDatabasePath := A_ScriptDir "\settings.db"
global ApplicationShortcutsInstalled := false, ShortcutKeys := DefaultShortcutKeys(), LibraryHistory := []
OnExit(CloseSettingsStore)
ReloadAppSettings()
reuse := SqliteConnection(A_ScriptDir "\statement-reuse.db",true)
try {
    reuse.Exec("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT)")
    reuse.Exec("INSERT INTO sample VALUES(4,'日本語👏'); INSERT INTO sample VALUES(5,'Ω')")
    Assert(reuse.Scalar("SELECT value FROM sample WHERE id=4")=="日本語👏"
        && reuse.Scalar("SELECT value FROM sample WHERE id=5")=="Ω","multi-statement execution preserves Unicode literals")
    reuse.Exec("CREATE TABLE `"日本語🎉`"(value TEXT); INSERT INTO `"日本語🎉`" VALUES('本文')")
    Assert(reuse.Scalar('SELECT value FROM "日本語🎉"')=="本文","direct execution and prepared queries share Unicode identifiers")
    insert := "INSERT INTO sample VALUES(?,?)"
    reuse.Run(insert,1,"first")
    failed := false
    try reuse.Run(insert,1,"duplicate")
    catch
        failed := true
    reuse.Run(insert,2)
    Assert(failed && reuse.Scalar("SELECT COUNT(*) FROM sample WHERE id=? AND value IS NULL",2)="1","step failure clears bindings before reuse")
    failed := false
    try reuse.Run(insert,3,"partial",99)
    catch
        failed := true
    reuse.Run(insert,3)
    Assert(failed && reuse.Scalar("SELECT COUNT(*) FROM sample WHERE id=? AND value IS NULL",3)="1","binding failure clears partial arguments before reuse")
    Assert(reuse.Scalar("SELECT value FROM sample WHERE id=?",1)="first" && reuse.Scalar("SELECT value FROM sample WHERE id=?")="","query reuse clears previous arguments")
} finally reuse.Close()
; Failed reads cannot publish a new comparison baseline before the transaction succeeds.
snapshotStore := SettingsRepository(A_ScriptDir "\snapshot-publication.db",true)
snapshotState := CreateDefaultSettings()
snapshotState.SharedDanmakuItems := [{Id:"snapshot-item",Name:"snapshot",Text:"before",Slot:0}]
global SnapshotFailurePoint := ""
try {
    initialBaseline := snapshotStore.Saved, failed := false
    snapshotStore.Db.Exec("CREATE TEMP TRIGGER reject_initial BEFORE INSERT ON preferences BEGIN SELECT RAISE(ABORT,'initial save failure'); END")
    try snapshotStore.SaveAll(snapshotState)
    catch
        failed := true
    snapshotStore.Db.Exec("DROP TRIGGER reject_initial")
    Assert(failed && snapshotStore.Saved=initialBaseline && !snapshotStore.Saved.Scopes.Count && !snapshotStore.Saved.Preferences,"first save failure retains the empty schema baseline")
    Assert(snapshotStore.Db.Scalar("SELECT COUNT(*) FROM scopes")="0" && snapshotStore.Db.Scalar("SELECT COUNT(*) FROM items")="0" && snapshotStore.Db.Scalar("SELECT COUNT(*) FROM preferences")="0","first save rolls back every data table")
    snapshotStore.SaveAll(snapshotState)
    Assert(snapshotStore.Saved!=initialBaseline && snapshotStore.Saved.Preferences && snapshotStore.Saved.Scopes.Has("@shared"),"retry publishes one complete baseline")
    for scenario in [{Loaded:true,Point:"version"},{Loaded:true,Point:"commit"},{Loaded:false,Point:"version"},{Loaded:false,Point:"commit"}] {
        if !scenario.Loaded {
            snapshotStore.Close()
            snapshotStore := SettingsRepository(A_ScriptDir "\snapshot-publication.db")
        }
        baselineBefore := snapshotStore.Saved
        SnapshotFailurePoint := scenario.Point, point := scenario.Point "/" (scenario.Loaded ? "loaded" : "unloaded"), failed := false
        snapshotStore.Db.DefineProp("Scalar",{Call:SnapshotScalar})
        snapshotStore.Db.DefineProp("Exec",{Call:SnapshotExec})
        try snapshotStore.Load()
        catch as failure
            failed := failure.Message="snapshot publication failure"
        finally {
            snapshotStore.Db.DeleteProp("Scalar")
            snapshotStore.Db.DeleteProp("Exec")
        }
        Assert(failed,"read failure reaches " point)
        Assert(snapshotStore.Saved=baselineBefore,"failed read retains the entire prior comparison baseline: " point)
        Assert(snapshotStore.Db.Scalar("SELECT body FROM items WHERE id='snapshot-item'")==snapshotState.SharedDanmakuItems[1].Text,"failed read never modifies stored data: " point)
        changedItem := snapshotState.SharedDanmakuItems[1].Clone(), changedItem.Text := point
        snapshotState.SharedDanmakuItems := [changedItem]
        snapshotStore.SaveAll(snapshotState)
        VerifySettingsRoundTrip(snapshotState,snapshotStore.Load())
        Assert(true,"save and reload succeed after a failed read: " point)
    }
} finally snapshotStore.Close()
; Mutating a caller-owned draft must not change the saved comparison values.
preferenceStore := SettingsRepository(A_ScriptDir "\preference-values.db",true)
preferenceState := CreateDefaultSettings()
preferenceState.Profiles := [{Id:"preference-profile",Name:"preferences",Channel:"",Items:[]}]
try {
    preferenceStore.SaveAll(preferenceState)
    for change in [{Property:"InputProfileId",Value:"preference-profile"},{Property:"AutoMode",Value:0},
        {Property:"DefaultReactionKind",Value:6},{Property:"DefaultReactionCount",Value:100},
        {Property:"DefaultReactionIntervalMs",Value:25}] {
        preferenceState.%change.Property% := change.Value
        before := Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))
        preferenceStore.SavePreferences(preferenceState)
        Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"one preference changes one stored row: " change.Property)
        preferenceStore.SavePreferences(preferenceState)
        Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"same preference value does not write again: " change.Property)
        VerifySettingsRoundTrip(preferenceState,preferenceStore.Load())
        Assert(true,"all values survive preference update and reload: " change.Property)
    }
    for index, definition in ShortcutDefinitions() {
        ; Reuse and mutate the same Map, including the key stored in preferences.
        preferenceState.ShortcutKeys[definition.Id] := "^+F" index
        before := Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))
        preferenceStore.SavePreferences(preferenceState)
        Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"one key changes one stored row: " definition.Id)
        preferenceStore.SavePreferences(preferenceState)
        Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"same key value does not write again: " definition.Id)
        VerifySettingsRoundTrip(preferenceState,preferenceStore.Load())
        Assert(true,"all values survive key update and reload: " definition.Id)
    }
    callerState := preferenceStore.Load()
    callerState.AutoMode := 1, callerState.ShortcutKeys["reaction"] := "^+r"
    callerState.SharedDanmakuItems := [{Id:"preference-item",Name:"item",Text:"body",Slot:0}]
    preferenceStore.SaveLibrary(callerState,"")
    preferenceState.SharedDanmakuItems := callerState.SharedDanmakuItems, preferenceState.InputProfileId := ""
    VerifySettingsRoundTrip(preferenceState,preferenceStore.Load())
    Assert(true,"library save changes selection and items while ignoring unsaved caller preference edits")
    callerState.InputProfileId := "preference-profile"
    before := Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))
    preferenceStore.SavePreferences(callerState)
    Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"saved baseline stays independent of the loaded preference object and key map")
    VerifySettingsRoundTrip(callerState,preferenceStore.Load())
    Assert(true,"explicit preference save persists the caller edits after library save")
} finally preferenceStore.Close()
store := OpenSettingsRepository(SettingsDatabasePath), db := store.Db
Assert(db.Scalar("PRAGMA journal_mode")="delete" && db.Scalar("PRAGMA synchronous")="3" && db.Scalar("PRAGMA foreign_keys")="1","durable DELETE settings")
a := ExecuteProfileCommand("add","","author A","/channel/A").ProfileId
b := ExecuteProfileCommand("add","","author B","/channel/B").ProfileId
state := CreateTestSettingsSnapshot()
Loop 1000
    state.SharedDanmakuItems.Push({Id:NewRecordId(),Name:"item" A_Index,Text:"  👏 '引用' " A_Index "  ",Slot:0})
OpenSettingsRepository(SettingsDatabasePath).SaveAll(state), ReloadAppSettings()
id := SharedDanmakuItems[1].Id
before := Integer(db.Scalar("SELECT total_changes()"))
ExecuteDanmakuCommand("edit","",SharedDanmakuItems[1].Id,{Name:"edited",Text:"  改訂👏 '引用'  ",Slot:0})
Assert(Integer(db.Scalar("SELECT total_changes()"))-before=1,"one edit updates one row")
Assert(SharedDanmakuItems[1].Id=id,"edit retains identity")
before := Integer(db.Scalar("SELECT total_changes()"))
ExecuteDanmakuCommand("down","",SharedDanmakuItems[1].Id)
Assert(Integer(db.Scalar("SELECT total_changes()"))-before=4,"swap updates two ranks through temporary ranks")
Assert(SharedDanmakuItems[2].Id=id,"swap retains identity")
before := Integer(db.Scalar("SELECT total_changes()"))
SaveAutoDetection(!AutoMode)
Assert(Integer(db.Scalar("SELECT total_changes()"))-before=1,"preference change updates one row")
before := Integer(db.Scalar("SELECT total_changes()"))
SaveSettingsPreferences(CreatePreferences(),SettingsDatabasePath)
Assert(Integer(db.Scalar("SELECT total_changes()"))=before,"unchanged preferences do not update any row")
originalKeys := CurrentShortcutMap(), swappedKeys := originalKeys.Clone()
swappedKeys["chat_focus"] := originalKeys["chat_clear"], swappedKeys["chat_clear"] := originalKeys["chat_focus"]
rejectedPreferences := CreatePreferences(), previousValues := store.Saved.Preferences, previousAuto := AutoMode
rejectedPreferences.AutoMode := !AutoMode, rejectedPreferences.ShortcutKeys := swappedKeys
db.Exec("CREATE TEMP TRIGGER reject_binding BEFORE UPDATE ON shortcut_bindings WHEN NEW.action='chat_clear' BEGIN SELECT RAISE(ABORT,'test failure'); END")
failed := false
try ApplyPreferences(rejectedPreferences)
catch
    failed := true
db.Exec("DROP TRIGGER reject_binding")
Assert(failed && AutoMode=previousAuto && ShortcutKeys["chat_focus"]==originalKeys["chat_focus"]
    && ShortcutKeys["chat_clear"]==originalKeys["chat_clear"] && store.Saved.Preferences=previousValues,"failed combined preference save preserves live values and repository snapshot")
Assert(Integer(db.Scalar("SELECT auto_mode FROM preferences WHERE id=1"))=previousAuto
    && db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_focus'")==originalKeys["chat_focus"]
    && db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_clear'")==originalKeys["chat_clear"],"failed binding update rolls back base preferences and every binding")
before := Integer(db.Scalar("SELECT total_changes()"))
SaveShortcutMap(swappedKeys)
Assert(Integer(db.Scalar("SELECT total_changes()"))-before=2,"shortcut swap updates only the two changed bindings")
Assert(db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_focus'")==swappedKeys["chat_focus"]
    && db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_clear'")==swappedKeys["chat_clear"],"shortcut swap persists both assignments")
SaveShortcutMap(originalKeys)
before := Integer(db.Scalar("SELECT total_changes()"))
ExecuteDanmakuCommand("duplicate","",SharedDanmakuItems[2].Id)
Assert(Integer(db.Scalar("SELECT total_changes()"))-before=1,"middle insertion preserves other ranks")
Assert(SharedDanmakuItems[3].Id!=id,"duplicate gets distinct identity")
ExecuteDanmakuCommand("move","",SharedDanmakuItems[2].Id,0,a)
Assert(Profiles[1].Items[1].Id=id && Profiles[1].Items[1].Slot=0,"cross-scope move retains identity and clears slot")
UndoLibraryCommand()
Assert(SharedDanmakuItems[2].Id=id && Profiles[1].Items.Length=0,"undo restores moved identity")
history := LibraryHistory.Length, prior := SharedDanmakuItems[1]
db.Exec("CREATE TEMP TRIGGER reject_edit BEFORE UPDATE ON items WHEN NEW.body='fail' BEGIN SELECT RAISE(ABORT,'test failure'); END")
failed := false
try ExecuteDanmakuCommand("edit","",SharedDanmakuItems[1].Id,{Name:"fail",Text:"fail",Slot:1})
catch
    failed := true
Assert(failed && SharedDanmakuItems[1]=prior && LibraryHistory.Length=history,"failed staged update preserves live state and history")
Assert(db.Scalar("SELECT position FROM items WHERE id=?",prior.Id)>0 && db.Scalar("SELECT body FROM items WHERE id=?",prior.Id)==prior.Text,"rollback restores staged rank and text")
db.Exec("DROP TRIGGER reject_edit")
db.Exec("PRAGMA query_only=ON")
failed := false
try SaveAutoDetection(!AutoMode)
catch
    failed := true
db.Exec("PRAGMA query_only=OFF")
Assert(failed,"read-only connection rejects saving")
pageLimit := db.Scalar("PRAGMA max_page_count"), pages := db.Scalar("PRAGMA page_count")
db.Exec("PRAGMA max_page_count=" pages)
large := ""
Loop 200000
    large .= "x"
failed := false
try ExecuteDanmakuCommand("edit","",SharedDanmakuItems[1].Id,{Name:"full",Text:large,Slot:0})
catch
    failed := true
db.Exec("PRAGMA max_page_count=" pageLimit)
Assert(failed && SharedDanmakuItems[1]=prior,"database capacity failure preserves live data")
beforeRanks := CreateTestSettingsSnapshot()
Loop 20
    ExecuteDanmakuCommand("duplicate","",SharedDanmakuItems[1].Id)
store.Db.CheckIntegrity()
Loop 20
    UndoLibraryCommand()
VerifySettingsRoundTrip(beforeRanks,LoadSettings(SettingsDatabasePath))
Assert(true,"rank exhaustion and repeated undo preserve logical order and IDs")
store.Db.CheckIntegrity()
backup := A_ScriptDir "\backup.db"
BackupSettingsDatabase(backup)
copy := SettingsRepository(backup)
VerifySettingsRoundTrip(CreateTestSettingsSnapshot(),copy.Load())
copy.Db.CheckIntegrity(), copy.Close()
Assert(true,"backup restores full logical state")
lockedBackup := A_ScriptDir "\locked-backup.db"
locker := SqliteConnection(SettingsDatabasePath)
try {
    locker.Exec("BEGIN EXCLUSIVE")
    failed := false
    try BackupSettingsDatabase(lockedBackup)
    catch
        failed := true
    Assert(failed && !FileExist(lockedBackup),"locked source cannot publish an incomplete backup")
    leftovers := 0
    Loop Files lockedBackup ".creating-*"
        leftovers++
    Assert(leftovers=0,"failed backup removes temporary database and journal")
} finally locker.Close()
BackupSettingsDatabase(lockedBackup)
copy := SettingsRepository(lockedBackup)
try {
    VerifySettingsRoundTrip(CreateTestSettingsSnapshot(),copy.Load())
    copy.Db.CheckIntegrity()
    Assert(true,"backup retries after source lock is released")
} finally copy.Close()
other := SqliteConnection(SettingsDatabasePath)
other.Exec("UPDATE preferences SET reaction_interval=250 WHERE id=1")
failed := false
try SaveAutoDetection(!AutoMode)
catch
    failed := true
Assert(failed,"external committed changes cannot be silently overwritten")
other.Close(), ReloadAppSettings()
Assert(DefaultReactionIntervalMs=250,"reload reads external committed state")
upgraded := SqliteConnection(backup)
upgraded.Exec("PRAGMA user_version=999"), upgraded.Close()
failed := false
try SettingsRepository(backup)
catch
    failed := true
Assert(failed && ProbeRepositoryConnection && !ProbeRepositoryConnection.Handle,"future schema rejection closes its connection before returning")
; Crash runner: raw process exit deliberately bypasses SQLite close/OnExit.
crashSource := '#Requires AutoHotkey v2.0`n#Include ' A_ScriptDir '\src\storage\sqlite_connection.ahk`n'
    . 'db := SqliteConnection(A_Args[1])`ndb.ConfigureStorage()`ndb.Exec("BEGIN IMMEDIATE; UPDATE preferences SET reaction_interval=500 WHERE id=1")`n'
    . 'if A_Args[2]="commit"`n    db.Exec("COMMIT")`nDllCall("ExitProcess","UInt",71)`n'
crashFile := A_ScriptDir "\crash.ahk"
FileAppend(crashSource,crashFile,"UTF-8")
CloseSettingsStore()
for phase in ["pending","commit"] {
    exitCode := RunWait('"' A_AhkPath '" /ErrorStdOut "' crashFile '" "' SettingsDatabasePath '" ' phase,,"Hide")
    Assert(exitCode=71,"crash child ended without clean close")
    ReloadAppSettings()
    Assert(DefaultReactionIntervalMs=(phase="pending" ? 250 : 500),"process crash respects transaction boundary " phase)
    CloseSettingsStore()
}
recoveryPath := A_ScriptDir "\load-recovery.db"
recoveryState := CreateTestSettingsSnapshot()
recovery := SettingsRepository(recoveryPath,true)
recovery.SaveAll(recoveryState)
recovery.Db.Backup(recoveryPath ".good")
recovery.Db.Run("DELETE FROM preferences")
recovery.Close()
failed := false
try LoadSettings(recoveryPath)
catch
    failed := true
Assert(failed && !ActiveSettingsRepository,"failed load releases active connection before repair")
FileMove(recoveryPath,recoveryPath ".bad",false)
FileMove(recoveryPath ".good",recoveryPath,false)
VerifySettingsRoundTrip(recoveryState,LoadSettings(recoveryPath))
Assert(true,"repaired database reloads in the same process")
CloseSettingsStore()
FileAppend("PASS: " Checks " SQLite storage, delta, failure and recovery checks; no application startup`n","*")
ExitApp()
SnapshotScalar(db,sql,values*) {
    if SnapshotFailurePoint="version" && sql="PRAGMA data_version"
        throw Error("snapshot publication failure")
    return SqliteConnection.Prototype.Scalar.Call(db,sql,values*)
}
SnapshotExec(db,sql) {
    if SnapshotFailurePoint="commit" && sql="COMMIT"
        throw Error("snapshot publication failure")
    return SqliteConnection.Prototype.Exec.Call(db,sql)
}
'@
Invoke-AhkTest -Runtime $release -Source $tests
