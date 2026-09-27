# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$repositoryAnchor = 'this.Db := SqliteConnection(path,create,readOnly)'
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
    for integerValue in [0,-1,2147483648,9007199254740993,9223372036854775807,-9223372036854775807-1] {
        storedNumber := reuse.Scalar("SELECT ?",integerValue)
        Assert(storedNumber is Integer && storedNumber=integerValue,"SQLite preserves integer type and exact signed 64-bit value: " integerValue)
    }
    mixedTypes := reuse.Rows("SELECT 7,'0007',NULL,1.5")[1]
    Assert(mixedTypes[1] is Integer && mixedTypes[1]=7 && Type(mixedTypes[2])="String" && mixedTypes[2]=="0007",
        "SQLite keeps numeric text distinct from stored integers")
    Assert(mixedTypes[3]=="" && Type(mixedTypes[4])="String" && mixedTypes[4]=="1.5",
        "SQLite retains existing NULL and non-integer representations without truncation")
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
    reuse.Exec("INSERT INTO sample VALUES(6,'prefix'||char(0)||'suffix')")
    failed := false
    try reuse.Rows("SELECT value FROM sample WHERE id IN (?,?) ORDER BY id",4,6)
    catch
        failed := true
    Assert(failed,"a NUL in a later row rejects the whole query instead of returning truncated text")
    rows := reuse.Rows("SELECT value FROM sample WHERE id IN (?,?) ORDER BY id",5)
    Assert(rows.Length=1 && rows[1][1]=="Ω","failed decoding resets the statement and clears every binding before reuse")
    Assert(reuse.Scalar("SELECT hex(value) FROM sample WHERE id=6")=="70726566697800737566666978","read rejection preserves all stored bytes")
} finally reuse.Close()
; The native connection constructor must preserve initialization and close failures.
for closeFails in [false,true] {
    OpeningCloseFails := closeFails, caught := 0
    try {
        try FailedOpeningConnection(A_ScriptDir "\statement-reuse.db")
        catch as failure
            caught := failure
        Assert(caught=OpeningFailure && caught is ValueError && InStr(caught.Message,"opening setup probe failure"),
            "connection initialization retains the original exception")
        Assert(!!InStr(caught.Message,"opening close probe failure")=closeFails,
            "connection initialization records any cleanup failure")
        Assert(OpeningConnection.CloseCalls=1 && !!OpeningConnection.Handle=closeFails,
            "connection initialization closes once and retains unconfirmed ownership")
    } finally SqliteConnection.Prototype.Close.Call(OpeningConnection)
}
; Cleanup failures must not replace or hide the original transaction error.
for cleanup in ["normal","rollback","rollback-close"] {
    transactionPath := A_ScriptDir "\transaction-" cleanup ".db"
    connection := SqliteConnection(transactionPath,true)
    connection.Exec("CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES('before')")
    original := ValueError("transaction write failure",-1,"original detail"), originalStack := original.Stack
    connection.Probe := {Cleanup:cleanup,Failure:original,Rollbacks:0,Closes:0}
    connection.DefineProp("Exec",{Call:TransactionFailureExec})
    connection.DefineProp("Close",{Call:TransactionFailureClose})
    caught := 0
    try {
        try connection.Transaction(TransactionFailureAction.Bind(connection))
        catch as failure
            caught := failure
        Assert(caught=original && caught is ValueError && caught.Stack=originalStack && caught.Extra="original detail",
            cleanup ": transaction preserves its original error object, type and location")
        Assert(InStr(caught.Message,"transaction write failure"),cleanup ": original write error is reported")
        Assert(!!InStr(caught.Message,"rollback probe failure")=(cleanup!="normal"),cleanup ": rollback failure is reported only when observed")
        Assert(!!InStr(caught.Message,"close probe failure")=(cleanup="rollback-close"),cleanup ": close failure is reported only when observed")
        Assert(connection.Probe.Rollbacks=1 && connection.Probe.Closes=(cleanup!="normal"),cleanup ": cleanup does not retry implicitly")
        Assert(!!connection.Handle=(cleanup!="rollback"),cleanup ": unclosed connection ownership is retained")
    } finally {
        connection.DeleteProp("Exec"), connection.DeleteProp("Close")
        connection.Close()
    }
    recovered := SqliteConnection(transactionPath)
    try {
        Assert(recovered.Scalar("SELECT value FROM sample")=="before",cleanup ": failed transaction never publishes its write")
        recovered.Transaction((*) => recovered.Exec("UPDATE sample SET value='retry'"))
        Assert(recovered.Scalar("SELECT value FROM sample")=="retry",cleanup ": a fresh connection can commit after cleanup")
    } finally recovered.Close()
}
; Reordering must keep distinct 64-bit ranks distinct without a floating-point sort.
rankStore := SettingsRepository(A_ScriptDir "\exact-ranks.db",true)
try {
    rankState := CreateDefaultSettings()
    rankState.SharedDanmakuItems := [{Id:"rank-left",Name:"left",Text:"left",Slot:0},{Id:"rank-right",Name:"right",Text:"right",Slot:0}]
    rankStore.SaveAll(rankState)
    rankStore.Db.Exec("UPDATE items SET position=9007199254740992 WHERE id='rank-left'; UPDATE items SET position=9007199254740993 WHERE id='rank-right'")
    original := rankStore.Load()
    reordered := original.Clone(), reordered.SharedDanmakuItems := [original.SharedDanmakuItems[2],original.SharedDanmakuItems[1]]
    rankStore.SaveAll(reordered)
    VerifySettingsRoundTrip(reordered,rankStore.Load())
    Assert(true,"reordering neighboring ranks above float precision survives reload")
    rankStore.SaveAll(original)
    VerifySettingsRoundTrip(original,rankStore.Load())
    Assert(true,"restoring the prior item order also preserves exact ranks")
    rankStore.SaveLibrary(reordered,"")
    VerifySettingsRoundTrip(reordered,rankStore.Load())
    Assert(true,"incremental save preserves the same exact-rank reorder")
    ; Insert at the front, so map insertion order differs from the saved item sequence.
    inserted := reordered.Clone(), inserted.SharedDanmakuItems := reordered.SharedDanmakuItems.Clone()
    inserted.SharedDanmakuItems.InsertAt(1,{Id:"rank-new",Name:"new",Text:"new",Slot:0})
    rankStore.SaveLibrary(inserted,"")
    mixed := inserted.Clone(), mixed.SharedDanmakuItems := [inserted.SharedDanmakuItems[3],inserted.SharedDanmakuItems[2],inserted.SharedDanmakuItems[1]]
    rankStore.SaveLibrary(mixed,"")
    VerifySettingsRoundTrip(mixed,rankStore.Load())
    Assert(true,"reorder after insertion uses saved logical order instead of map insertion order")
    mixed.SharedDanmakuItems := [mixed.SharedDanmakuItems[3],mixed.SharedDanmakuItems[1]]
    rankStore.SaveLibrary(mixed,"")
    VerifySettingsRoundTrip(mixed,rankStore.Load())
    Assert(true,"reorder with deletion uses only surviving ranks")
} finally rankStore.Close()
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
; Forced validation may reuse rows only when the caller's current values still match.
itemStore := SettingsRepository(A_ScriptDir "\item-values.db",true)
itemState := CreateDefaultSettings(), mutableItem := {Id:"mutable",Name:"original",Text:"before",Slot:0}
itemState.SharedDanmakuItems := [mutableItem]
try {
    itemStore.SaveAll(itemState)
    for change in [{Property:"Name",Column:"name",Value:"Original 日本語"},
        {Property:"Text",Column:"body",Value:"changed👏"},{Property:"Slot",Column:"slot",Value:1}] {
        oldRow := itemStore.Saved.Scopes["@shared"].Rows["mutable"], oldValue := oldRow.%change.Property%
        mutableItem.%change.Property% := change.Value
        itemStore.SaveAll(itemState)
        Assert(oldRow.%change.Property%==oldValue,"forced validation preserves the prior stored scalar: " change.Property)
        Assert(itemStore.Db.Scalar("SELECT " change.Column " FROM items WHERE id='mutable'")==change.Value,"same-object mutation reaches the database: " change.Property)
        before := Integer(itemStore.Db.Scalar("SELECT total_changes()"))
        itemStore.SaveAll(itemState)
        Assert(Integer(itemStore.Db.Scalar("SELECT total_changes()"))=before,"revalidating the same values performs no write: " change.Property)
    }
    for change in [{Property:"Name",Value:" "},{Property:"Text",Value:"invalid`nbody"}] {
        baselineBefore := itemStore.Saved, oldValue := mutableItem.%change.Property%, failed := false
        mutableItem.%change.Property% := change.Value
        try itemStore.SaveAll(itemState)
        catch
            failed := true
        Assert(failed && itemStore.Saved=baselineBefore,"same-object reuse never bypasses forced validation: " change.Property)
        Assert(Integer(itemStore.Db.Scalar("SELECT total_changes()"))=before,"rejected mutation never writes: " change.Property)
        mutableItem.%change.Property% := oldValue
    }
    VerifySettingsRoundTrip(itemState,itemStore.Load())
} finally itemStore.Close()
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
        ; Every operation uses the same binding table and mutable draft Map.
        preferenceState.ShortcutKeys[definition.Id] := "^+F" index
        before := Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))
        preferenceStore.SavePreferences(preferenceState)
        Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"one key changes one stored row: " definition.Id)
        preferenceStore.SavePreferences(preferenceState)
        Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=1,"same key value does not write again: " definition.Id)
        VerifySettingsRoundTrip(preferenceState,preferenceStore.Load())
        Assert(true,"all values survive key update and reload: " definition.Id)
    }
    for storedKey in ["!^f1","+^f12"] {
        preferenceState.ShortcutKeys["chat_focus"] := storedKey
        preferenceStore.SavePreferences(preferenceState)
        VerifySettingsRoundTrip(preferenceState,preferenceStore.Load())
        Assert(true,"lowercase function keys preserve their spelling through save and reload: " storedKey)
    }
    collisionState := preferenceState.Clone(), collisionState.ShortcutKeys := preferenceState.ShortcutKeys.Clone()
    collisionState.ShortcutKeys["chat_clear"] := "^+F12"
    before := preferenceStore.Db.Scalar("SELECT total_changes()"), rejected := false
    try preferenceStore.SavePreferences(collisionState)
    catch
        rejected := true
    Assert(rejected && preferenceStore.Db.Scalar("SELECT total_changes()")=before,"case and modifier-order variants cannot save the same function key twice")
    VerifySettingsRoundTrip(preferenceState,preferenceStore.Load())
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
    Assert(Integer(preferenceStore.Db.Scalar("SELECT total_changes()"))-before=2,"preference and key changes update their own rows from an independent saved baseline")
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
backup := A_ScriptDir "\backup.json"
ExportUserData(backup)
VerifySettingsRoundTrip(CreateTestSettingsSnapshot(),ReadUserData(backup).State)
Assert(true,"JSON backup restores full logical state")
lockedBackup := A_ScriptDir "\locked-backup.json"
locker := SqliteConnection(SettingsDatabasePath)
try {
    locker.Exec("BEGIN EXCLUSIVE")
    failed := false
    try ExportUserData(lockedBackup)
    catch
        failed := true
    Assert(failed && !FileExist(lockedBackup),"locked source cannot publish an incomplete backup")
    leftovers := 0
    Loop Files lockedBackup ".creating-*"
        leftovers++
    Assert(leftovers=0,"failed JSON backup leaves no temporary export")
} finally locker.Close()
ExportUserData(lockedBackup)
VerifySettingsRoundTrip(CreateTestSettingsSnapshot(),ReadUserData(lockedBackup).State)
Assert(true,"JSON backup retries after source lock is released")
other := SqliteConnection(SettingsDatabasePath)
other.Exec("UPDATE preferences SET reaction_interval=250 WHERE id=1")
failed := false
try SaveAutoDetection(!AutoMode)
catch
    failed := true
Assert(failed,"external committed changes cannot be silently overwritten")
other.Close(), ReloadAppSettings()
Assert(DefaultReactionIntervalMs=250,"reload reads external committed state")
futurePath := A_ScriptDir "\future-schema.db"
upgraded := SettingsRepository(futurePath,true)
upgraded.SaveAll(CreateTestSettingsSnapshot())
upgraded.Db.Exec("PRAGMA user_version=999"), upgraded.Close()
closeMethod := SqliteConnection.Prototype.GetOwnPropDesc("Close")
for closeFails in [false,true] {
    caught := 0
    if closeFails
        SqliteConnection.Prototype.DefineProp("Close",{Call:RejectSettingsClose})
    try {
        try SettingsRepository(futurePath)
        catch as failure
            caught := failure
    } finally SqliteConnection.Prototype.DefineProp("Close",closeMethod)
    try {
        Assert(caught && InStr(caught.Message,"未対応の設定形式です"),"future schema rejection retains its original reason")
        Assert(!!InStr(caught.Message,"settings close probe failure")=closeFails,"schema rejection retains any connection cleanup failure")
        Assert(ProbeRepositoryConnection && !!ProbeRepositoryConnection.Handle=closeFails,"schema rejection releases only confirmed closed connections")
        if closeFails
            Assert(ProbeRepositoryConnection.ProbeCloseCalls=1,"schema cleanup does not retry implicitly")
    } finally {
        ProbeRepositoryConnection.Close()
    }
}
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
; Offline recovery copies only a closed database, matching the manual restore procedure.
recovery.Close()
FileCopy(recoveryPath,recoveryPath ".good",false)
recovery := SettingsRepository(recoveryPath)
recovery.Db.Run("DELETE FROM preferences")
recovery.Close()
; The public load boundary must preserve the read error even if cleanup also fails.
recovery := OpenSettingsRepository(recoveryPath), caught := 0
recovery.Db.DefineProp("Close",{Call:RejectSettingsClose})
try {
    try LoadSettings(recoveryPath)
    catch as failure
        caught := failure
} finally recovery.Db.DeleteProp("Close")
try {
    Assert(caught && InStr(caught.Message,"共通設定がありません") && InStr(caught.Message,"settings close probe failure"),
        "load reports both the invalid data and connection cleanup failure")
    Assert(InStr(caught.Stack,"ReadState"),"load cleanup preserves the original read failure location")
    Assert(ActiveSettingsRepository=recovery && recovery.Db.Handle && recovery.Db.ProbeCloseCalls=1,
        "failed load cleanup retains ownership for explicit retry without an implicit retry")
    Assert(!recovery.Saved && recovery.Db.Scalar("SELECT COUNT(*) FROM preferences")=0,
        "failed load cleanup does not publish a baseline or replace invalid data")
} finally {
    CloseSettingsStore()
}
failed := false
try LoadSettings(recoveryPath)
catch
    failed := true
Assert(failed && !ActiveSettingsRepository,"failed load releases active connection before repair")
FileMove(recoveryPath,recoveryPath ".bad",false)
FileMove(recoveryPath ".good",recoveryPath,false)
VerifySettingsRoundTrip(recoveryState,LoadSettings(recoveryPath))
Assert(true,"repaired database reloads in the same process")
; Opening owns the old connection; a failed switch must not trigger read cleanup.
previousRepository := ActiveSettingsRepository, previousBaseline := previousRepository.Saved
switchPath := A_ScriptDir "\switch-after-close.db", caught := 0
previousRepository.Db.DefineProp("Close",{Call:RejectSettingsClose})
try {
    try LoadSettings(switchPath)
    catch as failure
        caught := failure
} finally previousRepository.Db.DeleteProp("Close")
Assert(previousRepository.Db.ProbeCloseCalls=1,
    "failed connection switch closes the prior connection only once; calls=" previousRepository.Db.ProbeCloseCalls)
Assert(caught && caught.Message="settings close probe failure","failed opening is returned without a second cleanup error")
Assert(ActiveSettingsRepository=previousRepository && previousRepository.Db.Handle && previousRepository.Saved=previousBaseline,
    "failed connection switch retains the current repository and its saved baseline")
Assert(!FileExist(switchPath),"failed connection switch does not create the requested database")
switched := LoadSettings(switchPath)
Assert(!previousRepository.Db.Handle && ActiveSettingsRepository.Path==switchPath,
    "explicit switch retry closes the previous connection and publishes the new owner")
VerifySettingsRoundTrip(CreateDefaultSettings(),switched)
VerifySettingsRoundTrip(recoveryState,LoadSettings(recoveryPath))
Assert(true,"switch retry preserves both the new defaults and the previous database")
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
TransactionFailureAction(db) {
    db.Exec("UPDATE sample SET value='uncommitted'")
    throw db.Probe.Failure
}
TransactionFailureExec(db,sql) {
    if sql="ROLLBACK" {
        db.Probe.Rollbacks++
        if db.Probe.Cleanup!="normal"
            throw Error("rollback probe failure")
    }
    return SqliteConnection.Prototype.Exec.Call(db,sql)
}
TransactionFailureClose(db) {
    db.Probe.Closes++
    if db.Probe.Cleanup="rollback-close"
        throw Error("close probe failure")
    return SqliteConnection.Prototype.Close.Call(db)
}
RejectSettingsClose(db) {
    db.ProbeCloseCalls := db.HasOwnProp("ProbeCloseCalls") ? db.ProbeCloseCalls+1 : 1
    throw Error("settings close probe failure")
}
class FailedOpeningConnection extends SqliteConnection {
    Exec(sql) {
        global OpeningConnection := this, OpeningFailure := ValueError("opening setup probe failure")
        throw OpeningFailure
    }
    Close() {
        this.CloseCalls := this.HasOwnProp("CloseCalls") ? this.CloseCalls+1 : 1
        if OpeningCloseFails
            throw Error("opening close probe failure")
        return super.Close()
    }
}
'@
Invoke-AhkTest -Runtime $release -Source $tests

# Round-trip data checks own their fixtures, independently of application startup.
$roundTripRuntime = New-TestRuntime
Invoke-AhkTest -Runtime $roundTripRuntime -Source @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
OnExit(CloseSettingsStore)
schemaPath := A_ScriptDir "\schema-check.db"
schemaState := CreateDefaultSettings()
schemaState.Profiles := [{Id:"roundtrip-author",Name:"roundtrip author",Channel:"",Items:[]}]
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
savedRoundTrip := FileRead(schemaPath,"RAW")
schemaState.SharedDanmakuItems[1].Text := "first`nsecond"
rejected := false
try OpenSettingsRepository(schemaPath).SaveAll(schemaState)
catch
    rejected := true
Assert(rejected && SameFileBytes(FileRead(schemaPath,"RAW"),savedRoundTrip), "multiline text cannot corrupt persisted database")
schemaState.SharedDanmakuItems[1].Text := "👏"
bulkState := CreateDefaultSettings()
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

FileAppend("PASS: " Checks " standalone storage round-trip checks`n","*")
ExitApp()
SameFileBytes(left,right) {
    return left.Size=right.Size && (!left.Size || DllCall("msvcrt\memcmp","Ptr",left,"Ptr",right,"UPtr",left.Size,"CDecl Int")=0)
}

'@
