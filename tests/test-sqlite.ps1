$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
OnExit(StopBrowserWorker)
global SqliteChecks := 0
try {
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
    SqlCheck(failed,"future schema rejected")
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
$source = [IO.File]::ReadAllText((Join-Path $release 'main.ahk')).Replace('OnExit(StopBrowserWorker)',$tests)
[IO.File]::WriteAllText((Join-Path $release 'main.ahk'),$source,[Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut',('"'+(Join-Path $release 'main.ahk')+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $release 'stdout.txt') -RedirectStandardError (Join-Path $release 'stderr.txt')
$null = $run.Handle
if (!$run.WaitForExit(30000)) { Stop-Process -Id $run.Id; throw 'SQLite test timed out' }
Get-Content -LiteralPath (Join-Path $release 'stdout.txt'),(Join-Path $release 'stderr.txt')
if ($run.ExitCode -ne 0) { throw "SQLite test failed: $release" }
