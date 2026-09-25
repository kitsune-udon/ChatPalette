# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$repositoryPath = Join-Path $release 'src\settings\settings_repository.ahk'
$repositorySource = [IO.File]::ReadAllText($repositoryPath)
$repositoryAnchor = 'this.Db := SqliteConnection(path,create)'
if (!$repositorySource.Contains($repositoryAnchor)) { throw 'Repository connection injection point missing' }
[IO.File]::WriteAllText($repositoryPath,$repositorySource.Replace($repositoryAnchor,$repositoryAnchor + "`r`n        global ProbeRepositoryConnection := this.Db"),[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global SqliteChecks := 0
try {
    reuse := SqliteConnection(A_ScriptDir "\statement-reuse.db",true)
    try {
        reuse.Exec("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT)")
        insert := "INSERT INTO sample VALUES(?,?)"
        reuse.Run(insert,1,"first")
        failed := false
        try reuse.Run(insert,1,"duplicate")
        catch
            failed := true
        reuse.Run(insert,2)
        SqlCheck(failed && reuse.Scalar("SELECT COUNT(*) FROM sample WHERE id=? AND value IS NULL",2)="1","step failure clears bindings before reuse")
        failed := false
        try reuse.Run(insert,3,"partial",99)
        catch
            failed := true
        reuse.Run(insert,3)
        SqlCheck(failed && reuse.Scalar("SELECT COUNT(*) FROM sample WHERE id=? AND value IS NULL",3)="1","binding failure clears partial arguments before reuse")
        SqlCheck(reuse.Scalar("SELECT value FROM sample WHERE id=?",1)="first" && reuse.Scalar("SELECT value FROM sample WHERE id=?")="","query reuse clears previous arguments")
    } finally reuse.Close()
    store := OpenSettingsRepository(SettingsDatabasePath), db := store.Db
    SqlCheck(db.Scalar("PRAGMA journal_mode")="delete" && db.Scalar("PRAGMA synchronous")="3" && db.Scalar("PRAGMA foreign_keys")="1","durable DELETE settings")
    a := ExecuteProfileCommand("add","","author A","/channel/A").ProfileId
    b := ExecuteProfileCommand("add","","author B","/channel/B").ProfileId
    state := CreateSettingsSnapshot()
    Loop 1000
        state.SharedDanmakuItems.Push({Id:NewRecordId(),Name:"item" A_Index,Text:"  👏 '引用' " A_Index "  ",Slot:0})
    SaveSettings(state,SettingsDatabasePath), ReloadAppSettings()
    id := SharedDanmakuItems[1].Id
    before := Integer(db.Scalar("SELECT total_changes()"))
    ExecuteDanmakuCommand("edit","",1,{Name:"edited",Text:"  改訂👏 '引用'  ",Slot:0})
    SqlCheck(Integer(db.Scalar("SELECT total_changes()"))-before=1,"one edit updates one row")
    SqlCheck(SharedDanmakuItems[1].Id=id,"edit retains identity")
    before := Integer(db.Scalar("SELECT total_changes()"))
    ExecuteDanmakuCommand("down","",1)
    SqlCheck(Integer(db.Scalar("SELECT total_changes()"))-before=4,"swap updates two ranks through temporary ranks")
    SqlCheck(SharedDanmakuItems[2].Id=id,"swap retains identity")
    before := Integer(db.Scalar("SELECT total_changes()"))
    SaveAutoDetection(!AutoMode)
    SqlCheck(Integer(db.Scalar("SELECT total_changes()"))-before=1,"preference change updates one row")
    before := Integer(db.Scalar("SELECT total_changes()"))
    SaveSettingsPreferences(CreatePreferences(),SettingsDatabasePath)
    SqlCheck(Integer(db.Scalar("SELECT total_changes()"))=before,"unchanged preferences do not update any row")
    originalKeys := CurrentShortcutMap(), swappedKeys := originalKeys.Clone()
    swappedKeys["chat_focus"] := originalKeys["chat_clear"], swappedKeys["chat_clear"] := originalKeys["chat_focus"]
    rejectedPreferences := CreatePreferences(), previousValues := store.PreferenceValues, previousAuto := AutoMode
    rejectedPreferences.AutoMode := !AutoMode, rejectedPreferences.ShortcutKeys := swappedKeys
    db.Exec("CREATE TEMP TRIGGER reject_binding BEFORE UPDATE ON shortcut_bindings WHEN NEW.action='chat_clear' BEGIN SELECT RAISE(ABORT,'test failure'); END")
    failed := false
    try ApplyPreferences(rejectedPreferences)
    catch
        failed := true
    db.Exec("DROP TRIGGER reject_binding")
    SqlCheck(failed && AutoMode=previousAuto && ShortcutKeys["chat_focus"]==originalKeys["chat_focus"]
        && ShortcutKeys["chat_clear"]==originalKeys["chat_clear"] && store.PreferenceValues=previousValues,"failed combined preference save preserves live values and repository snapshot")
    SqlCheck(Integer(db.Scalar("SELECT auto_mode FROM preferences WHERE id=1"))=previousAuto
        && db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_focus'")==originalKeys["chat_focus"]
        && db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_clear'")==originalKeys["chat_clear"],"failed binding update rolls back base preferences and every binding")
    before := Integer(db.Scalar("SELECT total_changes()"))
    SaveShortcutMap(swappedKeys)
    SqlCheck(Integer(db.Scalar("SELECT total_changes()"))-before=2,"shortcut swap updates only the two changed bindings")
    SqlCheck(db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_focus'")==swappedKeys["chat_focus"]
        && db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_clear'")==swappedKeys["chat_clear"],"shortcut swap persists both assignments")
    SaveShortcutMap(originalKeys)
    before := Integer(db.Scalar("SELECT total_changes()"))
    ExecuteDanmakuCommand("duplicate","",2)
    SqlCheck(Integer(db.Scalar("SELECT total_changes()"))-before=1,"middle insertion preserves other ranks")
    SqlCheck(SharedDanmakuItems[3].Id!=id,"duplicate gets distinct identity")
    ExecuteDanmakuCommand("move","",2,0,a)
    SqlCheck(Profiles[1].Items[1].Id=id && Profiles[1].Items[1].Slot=0,"cross-scope move retains identity and clears slot")
    UndoLibraryCommand()
    SqlCheck(SharedDanmakuItems[2].Id=id && Profiles[1].Items.Length=0,"undo restores moved identity")
    history := LibraryHistory.Length, prior := SharedDanmakuItems[1]
    db.Exec("CREATE TEMP TRIGGER reject_edit BEFORE UPDATE ON items WHEN NEW.body='fail' BEGIN SELECT RAISE(ABORT,'test failure'); END")
    failed := false
    try ExecuteDanmakuCommand("edit","",1,{Name:"fail",Text:"fail",Slot:1})
    catch
        failed := true
    SqlCheck(failed && SharedDanmakuItems[1]=prior && LibraryHistory.Length=history,"failed staged update preserves live state and history")
    SqlCheck(db.Scalar("SELECT position FROM items WHERE id=?",prior.Id)>0 && db.Scalar("SELECT body FROM items WHERE id=?",prior.Id)==prior.Text,"rollback restores staged rank and text")
    db.Exec("DROP TRIGGER reject_edit")
    db.Exec("PRAGMA query_only=ON")
    failed := false
    try SaveAutoDetection(!AutoMode)
    catch
        failed := true
    db.Exec("PRAGMA query_only=OFF")
    SqlCheck(failed,"read-only connection rejects saving")
    pageLimit := db.Scalar("PRAGMA max_page_count"), pages := db.Scalar("PRAGMA page_count")
    db.Exec("PRAGMA max_page_count=" pages)
    large := ""
    Loop 200000
        large .= "x"
    failed := false
    try ExecuteDanmakuCommand("edit","",1,{Name:"full",Text:large,Slot:0})
    catch
        failed := true
    db.Exec("PRAGMA max_page_count=" pageLimit)
    SqlCheck(failed && SharedDanmakuItems[1]=prior,"database capacity failure preserves live data")
    beforeRanks := CreateSettingsSnapshot()
    Loop 20
        ExecuteDanmakuCommand("duplicate","",1)
    store.CheckIntegrity()
    Loop 20
        UndoLibraryCommand()
    VerifySettingsMigration(beforeRanks,LoadSettings(SettingsDatabasePath))
    SqlCheck(true,"rank exhaustion and repeated undo preserve logical order and IDs")
    store.CheckIntegrity()
    backup := A_ScriptDir "\backup.db"
    BackupSettingsDatabase(backup)
    copy := SettingsRepository(backup)
    VerifySettingsMigration(CreateSettingsSnapshot(),copy.Load())
    copy.CheckIntegrity(), copy.Close()
    SqlCheck(true,"backup restores full logical state")
    lockedBackup := A_ScriptDir "\locked-backup.db"
    locker := SqliteConnection(SettingsDatabasePath)
    try {
        locker.Exec("BEGIN EXCLUSIVE")
        failed := false
        try BackupSettingsDatabase(lockedBackup)
        catch
            failed := true
        SqlCheck(failed && !FileExist(lockedBackup),"locked source cannot publish an incomplete backup")
        leftovers := 0
        Loop Files lockedBackup ".creating-*"
            leftovers++
        SqlCheck(leftovers=0,"failed backup removes temporary database and journal")
    } finally locker.Close()
    BackupSettingsDatabase(lockedBackup)
    copy := SettingsRepository(lockedBackup)
    try {
        VerifySettingsMigration(CreateSettingsSnapshot(),copy.Load())
        copy.CheckIntegrity()
        SqlCheck(true,"backup retries after source lock is released")
    } finally copy.Close()
    other := SqliteConnection(SettingsDatabasePath)
    other.Exec("UPDATE preferences SET reaction_interval=250 WHERE id=1")
    failed := false
    try SaveAutoDetection(!AutoMode)
    catch
        failed := true
    SqlCheck(failed,"external committed changes cannot be silently overwritten")
    other.Close(), ReloadAppSettings()
    SqlCheck(DefaultReactionIntervalMs=250,"reload reads external committed state")
    upgraded := SqliteConnection(backup)
    upgraded.Exec("PRAGMA user_version=999"), upgraded.Close()
    failed := false
    try SettingsRepository(backup)
    catch
        failed := true
    SqlCheck(failed && ProbeRepositoryConnection && !ProbeRepositoryConnection.Handle,"future schema rejection closes its connection before returning")
    ; Crash runner: raw process exit deliberately bypasses SQLite close/OnExit.
    crashSource := '#Requires AutoHotkey v2.0`n#Include ' A_ScriptDir '\src\storage\sqlite_connection.ahk`n'
        . 'db := SqliteConnection(A_Args[1])`ndb.ConfigureStorage()`ndb.Exec("BEGIN IMMEDIATE; UPDATE preferences SET reaction_interval=500 WHERE id=1")`n'
        . 'if A_Args[2]="commit"`n    db.Exec("COMMIT")`nDllCall("ExitProcess","UInt",71)`n'
    crashFile := A_ScriptDir "\crash.ahk"
    FileAppend(crashSource,crashFile,"UTF-8")
    CloseSettingsStore()
    for phase in ["pending","commit"] {
        exitCode := RunWait('"' A_AhkPath '" /ErrorStdOut "' crashFile '" "' SettingsDatabasePath '" ' phase,,"Hide")
        SqlCheck(exitCode=71,"crash child ended without clean close")
        ReloadAppSettings()
        SqlCheck(DefaultReactionIntervalMs=(phase="pending" ? 250 : 500),"process crash respects transaction boundary " phase)
        CloseSettingsStore()
    }
    recoveryPath := A_ScriptDir "\load-recovery.db"
    recoveryState := CreateSettingsSnapshot()
    recovery := SettingsRepository(recoveryPath,true)
    recovery.SaveAll(recoveryState)
    recovery.Db.Backup(recoveryPath ".good")
    recovery.Db.Run("DELETE FROM preferences")
    recovery.Close()
    failed := false
    try LoadSettings(recoveryPath)
    catch
        failed := true
    SqlCheck(failed && !ActiveSettingsRepository,"failed load releases active connection before repair")
    FileMove(recoveryPath,recoveryPath ".bad",false)
    FileMove(recoveryPath ".good",recoveryPath,false)
    VerifySettingsMigration(recoveryState,LoadSettings(recoveryPath))
    SqlCheck(true,"repaired database reloads in the same process")
    CloseSettingsStore()
    FileAppend("PASS: " SqliteChecks " SQLite storage, delta, failure and recovery checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","**")
    ExitApp(1)
}
SqlCheck(value,message) {
    global SqliteChecks
    SqliteChecks++
    if !value
        throw Error(message)
}
'@
Invoke-AppTest -Runtime $release -Body $tests
