# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
# Fail one rollback move only in the isolated runtime.
Edit-TestSource $release 'src/app/app_lifecycle.ahk' 'try FileMove(pair[2],pair[1],false)' 'try ProbeResetRestore(pair)'
Edit-TestSource $release 'src/app/app_lifecycle.ahk' 'FileMove(pair[1],pair[2],false)' 'ProbeResetMove(pair)'

$tests = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
OnExit(CloseSettingsStore)
path := A_ScriptDir "\integrity.db"
for sql in ["DELETE FROM preferences", "DELETE FROM scopes WHERE id='@shared'",
    "DELETE FROM shortcut_bindings WHERE action='chat_focus'",
    "UPDATE shortcut_bindings SET action='CHAT_FOCUS' WHERE action='chat_focus'",
    "INSERT INTO shortcut_bindings VALUES('CHAT_FOCUS','^!f')",
    "DELETE FROM shortcut_bindings WHERE action='reaction'",
    "UPDATE preferences SET reaction_count=7",
    "UPDATE preferences SET reaction_kind=1.5",
    "UPDATE preferences SET reaction_count=10.5",
    "UPDATE preferences SET reaction_interval=200.5",
    "UPDATE scopes SET position=0.5",
    "UPDATE items SET position=1024.5",
    "UPDATE preferences SET reaction_interval=-0.5",
    "UPDATE preferences SET reaction_kind='0x1'",
    "UPDATE items SET position='0x10000000000000400'",
    "UPDATE items SET position=1e30",
    "UPDATE preferences SET reaction_kind=CAST('1' AS BLOB)",
    "UPDATE items SET position=CAST('1024' AS BLOB)",
    "UPDATE items SET body=char(10)", "UPDATE items SET id=''",
    "UPDATE items SET body='prefix'||char(0)||'suffix'",
    "UPDATE items SET body=char(0)||'suffix'",
    "UPDATE items SET body='prefix'||char(0)",
    "UPDATE items SET id=id||char(0)||'other'"] {
    CloseSettingsStore()
    if FileExist(path)
        FileDelete(path)
    state := CreateDefaultSettings()
    state.SharedDanmakuItems := [{Id:"integrity-item",Name:"kept",Text:"important",Slot:0}]
    OpenSettingsRepository(path).SaveAll(state)
    CloseSettingsStore()
    db := SqliteConnection(path)
    ; Deliberately bypass CHECKs to exercise defensive reads of damaged data.
    db.Exec("PRAGMA ignore_check_constraints=ON")
    db.Exec(sql), db.Close()
    original := FileRead(path,"RAW"), message := ""
    try LoadSettings(path)
    catch as failure
        message := failure.Message
    Assert(message != "","invalid database state is rejected: " sql)
    actual := FileRead(path,"RAW")
    Assert(actual.Size=original.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",original,"UPtr",actual.Size,"CDecl Int")=0,"rejection preserves original database")
}
CloseSettingsStore()
FileDelete(path)
; Preserve exact 64-bit ranks, including values that cannot round-trip through a float.
numericStore := SettingsRepository(A_ScriptDir "\integer-values.db",true)
try {
    numericState := CreateDefaultSettings()
    numericState.SharedDanmakuItems := [{Id:"integer-item",Name:"kept",Text:"important",Slot:0}]
    numericStore.SaveAll(numericState)
    for rank in [2147483648,9007199254740993,9223372036854775807] {
        numericStore.Db.Run("UPDATE items SET position=?",rank)
        loaded := numericStore.Load()
        Assert(numericStore.Saved.Scopes["@shared"].Rows["integer-item"].Position=rank,"load preserves the exact integer rank: " rank)
        before := numericStore.Db.Scalar("SELECT total_changes()")
        numericStore.SaveAll(loaded)
        Assert(numericStore.Db.Scalar("SELECT total_changes()")=before,"unchanged save does not normalize an exact integer rank: " rank)
    }
    numericStore.Db.Exec("UPDATE preferences SET reaction_interval=200.0; UPDATE items SET position=1024.0")
    VerifySettingsRoundTrip(numericState,numericStore.Load())
    Assert(true,"integral numeric values normalized by SQLite remain readable")
    baseline := numericStore.Saved, rejected := false
    numericStore.Db.Exec("PRAGMA ignore_check_constraints=ON; UPDATE preferences SET reaction_kind=1.5; PRAGMA ignore_check_constraints=OFF")
    try numericStore.Load()
    catch
        rejected := true
    Assert(rejected && numericStore.Saved=baseline,"a lossy numeric read cannot replace a previously loaded baseline")
    numericStore.Db.Exec("UPDATE preferences SET reaction_kind=1")
    VerifySettingsRoundTrip(numericState,numericStore.Load())
    Assert(true,"load succeeds after an explicit repair of the invalid numeric value")
} finally numericStore.Close()
; Database constraints reject invalid writes before they become stored state.
constraintStore := SettingsRepository(A_ScriptDir "\constraints.db",true)
try {
    valid := CreateDefaultSettings()
    valid.SharedDanmakuItems := [{Id:"constraint-item",Name:"kept",Text:"important",Slot:0}]
    constraintStore.SaveAll(valid)
    for sql in ["UPDATE items SET id=''", "UPDATE scopes SET id=''",
        "UPDATE scopes SET name='unexpected' WHERE id='@shared'",
        "UPDATE scopes SET channel='unexpected' WHERE id='@shared'",
        "UPDATE scopes SET position=1 WHERE id='@shared'",
        "UPDATE scopes SET position=0.5", "UPDATE items SET position=1.5",
        "UPDATE items SET slot=1.5", "UPDATE preferences SET active_scope='@shared'",
        "UPDATE preferences SET auto_mode=0.5", "UPDATE preferences SET reaction_kind=1.5",
        "UPDATE preferences SET reaction_kind=0", "UPDATE preferences SET reaction_count=0",
        "UPDATE preferences SET reaction_count=10.5", "UPDATE preferences SET reaction_interval=-1",
        "UPDATE preferences SET reaction_interval=200.5",
        "UPDATE preferences SET reaction_kind=CAST('1' AS BLOB)"] {
        rejected := false
        try constraintStore.Db.Exec(sql)
        catch
            rejected := true
        Assert(rejected,"database rejects invalid write: " sql)
        VerifySettingsRoundTrip(valid,constraintStore.Load())
        constraintStore.Db.CheckIntegrity()
    }
} finally constraintStore.Close()
state := CreateDefaultSettings()
OpenSettingsRepository(path).SaveAll(state)
VerifySettingsRoundTrip(state,LoadSettings(path))
Assert(state.Profiles.Length=0 && state.SharedDanmakuItems.Length=0,"new settings model starts empty")
; A rejected write must not repair the caller's missing identity as a side effect.
for kind in ["missing-invalid-body","empty-invalid-body","missing","empty"] {
    candidate := CreateDefaultSettings()
    item := {Name:"candidate",Text:InStr(kind,"invalid-body") ? "first`nsecond" : "valid",Slot:0}
    hasId := InStr(kind,"empty")=1
    if hasId
        item.Id := ""
    candidate.SharedDanmakuItems := [item]
    original := FileRead(path,"RAW"), rejected := false
    try OpenSettingsRepository(path).SaveAll(candidate)
    catch
        rejected := true
    Assert(item.HasOwnProp("Id")=hasId && (!hasId || item.Id==""),"save never invents or replaces caller identity: " kind)
    Assert(rejected,"missing item identity is rejected: " kind)
    actual := FileRead(path,"RAW")
    Assert(actual.Size=original.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",original,"UPtr",actual.Size,"CDecl Int")=0,"invalid identity preserves stored data: " kind)
}
; Stored models must contain an explicit assignment; commands may default an omitted input.
candidate := CreateDefaultSettings()
item := {Id:"missing-slot",Name:"candidate",Text:"valid"}
candidate.SharedDanmakuItems := [item]
original := FileRead(path,"RAW"), rejected := false
try OpenSettingsRepository(path).SaveAll(candidate)
catch
    rejected := true
Assert(rejected && !item.HasOwnProp("Slot"),"a missing stored assignment is rejected without mutating the caller")
actual := FileRead(path,"RAW")
Assert(actual.Size=original.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",original,"UPtr",actual.Size,"CDecl Int")=0,"a missing assignment preserves the stored database")
item.Slot := 0
OpenSettingsRepository(path).SaveAll(candidate)
loaded := LoadSettings(path)
Assert(loaded.SharedDanmakuItems.Length=1 && loaded.SharedDanmakuItems[1].Slot=0,"explicitly unassigned items survive a save/load round trip")
; Backup publication must reject broken references without modifying the source.
CloseSettingsStore()
global SettingsDatabasePath := A_ScriptDir "\backup-source.db"
source := OpenSettingsRepository(SettingsDatabasePath).Db
source.Exec("PRAGMA foreign_keys=OFF")
source.Run("INSERT INTO items VALUES(?,?,?,?,?,NULL)","orphan","missing-scope",1024,"kept","important")
source.Exec("PRAGMA foreign_keys=ON")
Assert(source.Scalar("PRAGMA integrity_check")="ok" && source.Rows("PRAGMA foreign_key_check").Length=1,"backup fixture has a broken reference in a structurally valid database")
original := FileRead(SettingsDatabasePath,"RAW"), rejected := false
backup := A_ScriptDir "\reference-backup.json"
try ExportUserData(backup)
catch
    rejected := true
Assert(rejected && !FileExist(backup),"backup rejects broken references before publishing the destination")
leftovers := 0
Loop Files backup ".creating-*"
    leftovers++
Assert(leftovers=0,"rejected JSON backup leaves no temporary export")
actual := FileRead(SettingsDatabasePath,"RAW")
Assert(actual.Size=original.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",original,"UPtr",actual.Size,"CDecl Int")=0,"rejected backup preserves the original database bytes")
source.Run("UPDATE items SET scope_id='@shared' WHERE id=?","orphan")
ExportUserData(backup)
loaded := ReadUserData(backup).State
Assert(loaded.SharedDanmakuItems.Length=1 && loaded.SharedDanmakuItems[1].Id="orphan"
    && loaded.SharedDanmakuItems[1].Text="important","JSON backup retries after explicit repair and preserves the item")
; Reset preserves the corrupt source and every sidecar without opening recovery dialogs.
CloseSettingsStore()
SettingsDatabasePath := A_ScriptDir "\reset-control.db"
OpenSettingsRepository(SettingsDatabasePath)
global ProbeRollbackFailure := false, ProbeResetFailure := 0
brokenPath := A_ScriptDir "\broken.db"
FileAppend("invalid database", brokenPath)
invalidMessage := ""
try LoadSettings(brokenPath)
catch as failure
    invalidMessage := failure.Message
Assert(invalidMessage != "", "invalid database is rejected")
backup := BackupSettingsForReset(brokenPath)
Assert(FileExist(backup) && !FileExist(brokenPath) && FileRead(backup)="invalid database", "reset preserves corrupt original")
resetDirectory := A_ScriptDir "\recovery-target"
DirCreate(resetDirectory)
resetPath := resetDirectory "\settings.db"
resetFiles := ["settings.db","settings.db-journal","settings.db-wal","settings.db-shm"]
currentDatabase := FileRead(SettingsDatabasePath,"RAW")
for name in resetFiles
    FileAppend(name,resetDirectory "\" name)
for blockRollback in [false,true] {
    ProbeRollbackFailure := blockRollback
    ; Lock the last file so every preceding move must be rolled back.
    locked := DllCall("CreateFileW","Str",resetDirectory "\settings.db-shm","UInt",0x80000000,"UInt",0,"Ptr",0,"UInt",3,"UInt",0,"Ptr",0,"Ptr")
    Assert(locked != -1,"reset failure fixture holds the final file exclusively")
    try {
        resetError := "", resetFailure := 0
        try BackupSettingsForReset(resetPath)
        catch as failure {
            resetFailure := failure
            resetError := failure.Message
        }
        Assert(resetError != "","reset aborts when a source cannot be moved")
    } finally DllCall("CloseHandle","Ptr",locked)
    Assert(InStr(resetError,ProbeResetFailure.Message)=1 && !!InStr(resetError,"Injected reset rollback failure")=blockRollback,
        "reset reports the original move failure and any restoration failure together")
    Assert(resetFailure=ProbeResetFailure.Error && resetFailure.Stack=ProbeResetFailure.Stack && resetFailure.Extra=ProbeResetFailure.Extra,
        "reset preserves the original move exception and its failure location")
    remainingBackups := []
    Loop Files resetDirectory "\*.backup-*"
        remainingBackups.Push(A_LoopFileFullPath)
    if blockRollback {
        Assert(remainingBackups.Length=1 && FileRead(remainingBackups[1])="settings.db-wal","rollback failure preserves the unmoved backup")
        Assert(InStr(resetError,remainingBackups[1]) && InStr(resetError,resetDirectory "\settings.db-wal"),"rollback failure identifies saved file and original destination")
        Assert(!FileExist(resetDirectory "\settings.db-wal"),"failed restoration is not reported as complete")
        FileMove(remainingBackups[1],resetDirectory "\settings.db-wal",false)
    } else
        Assert(remainingBackups.Length=0,"successful rollback leaves no partial backup set")
    for name in resetFiles
        Assert(FileExist(resetDirectory "\" name) && FileRead(resetDirectory "\" name)=name,"reset preserves every original despite intermediate failures")
}
ProbeRollbackFailure := false
backup := BackupSettingsForReset(resetPath)
for name in resetFiles {
    saved := backup SubStr(name,StrLen("settings.db")+1)
    Assert(!FileExist(resetDirectory "\" name) && FileExist(saved) && FileRead(saved)=name,"reset preserves target files and sidecar names")
}
actual := FileRead(SettingsDatabasePath,"RAW")
Assert(actual.Size=currentDatabase.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",currentDatabase,"UPtr",actual.Size,"CDecl Int")=0,"reset never changes the database in a different directory")
FileAppend("PASS: " Checks " settings integrity checks; no application startup`n","*")
ExitApp()
ProbeResetMove(pair) {
    global ProbeResetFailure
    try FileMove(pair[1],pair[2],false)
    catch as failure {
        ProbeResetFailure := {Error:failure,Message:failure.Message,Stack:failure.Stack,Extra:failure.Extra}
        throw failure
    }
}
ProbeResetRestore(pair) {
    global ProbeRollbackFailure
    if ProbeRollbackFailure && RegExMatch(pair[1],"\\settings\.db-wal$")
        throw Error("Injected reset rollback failure")
    FileMove(pair[2],pair[1],false)
}
'@
Invoke-AhkTest -Runtime $release -Source $tests

# Exercise all storage boundaries with small fixtures in a separate runtime.
$limitsRuntime = New-TestRuntime
Edit-TestSource $limitsRuntime 'src/settings/settings_schema.ahk' 'static Profiles => 10000' 'static Profiles => 2'
Edit-TestSource $limitsRuntime 'src/settings/settings_schema.ahk' 'static Items => 100000' 'static Items => 3'
Edit-TestSource $limitsRuntime 'src/settings/settings_schema.ahk' 'static DatabaseBytes => 128*1024*1024' 'static DatabaseBytes => 1024*1024'
$limitsTests = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
path := A_ScriptDir "\limits.db"
repository := SettingsRepository(path,true)
state := CreateDefaultSettings()
state.Profiles := [{Id:"a",Name:"A",Channel:"",Items:[]},{Id:"b",Name:"B",Channel:"",Items:[]}]
state.SharedDanmakuItems := [{Id:"one",Name:"1",Text:"first",Slot:0},{Id:"two",Name:"2",Text:"second",Slot:0}]
state.Profiles[1].Items := [{Id:"three",Name:"3",Text:"third",Slot:0}]
repository.SaveAll(state)
VerifySettingsRoundTrip(state,repository.Load())
Assert(true,"exact profile and total item limits allow save and load, including the shared scope")
for kind in ["profiles","items"] {
    candidate := CreateDefaultSettings()
    candidate.Profiles := state.Profiles.Clone(), candidate.SharedDanmakuItems := state.SharedDanmakuItems.Clone()
    if kind="profiles"
        candidate.Profiles.Push({Id:"extra",Name:"extra",Channel:"",Items:[]})
    else
        candidate.SharedDanmakuItems.Push({Id:"extra",Name:"extra",Text:"extra",Slot:0})
    baseline := repository.Saved, rejected := false
    try repository.SaveAll(candidate)
    catch
        rejected := true
    Assert(rejected && repository.Saved=baseline,"over-limit save preserves the published baseline: " kind)
    VerifySettingsRoundTrip(state,repository.Load())
    if kind="profiles"
        repository.Db.Exec("INSERT INTO scopes VALUES('extra','extra',NULL,3)")
    else
        repository.Db.Exec("INSERT INTO items VALUES('extra','@shared',3072,'extra','extra',NULL)")
    original := FileRead(path,"RAW"), baseline := repository.Saved, rejected := false
    try repository.Load()
    catch
        rejected := true
    actual := FileRead(path,"RAW")
    Assert(rejected && repository.Saved=baseline,"over-limit load preserves the published baseline: " kind)
    Assert(actual.Size=original.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",original,"UPtr",actual.Size,"CDecl Int")=0,"over-limit load preserves database bytes: " kind)
    repository.Db.Exec("DELETE FROM " (kind="profiles" ? "scopes" : "items") " WHERE id='extra'")
}
; A physical growth failure must roll back the update and remain readable.
candidate := CreateDefaultSettings()
candidate.SharedDanmakuItems := [{Id:"large",Name:"large",Text:Format("{:1100000}","x"),Slot:0}]
baseline := repository.Saved, rejected := false
try repository.SaveAll(candidate)
catch
    rejected := true
Assert(rejected && repository.Saved=baseline && FileGetSize(path)<=1024*1024,"SQLite growth limit rejects the write without publishing its state")
VerifySettingsRoundTrip(state,repository.Load())
repository.Close()
; Check the physical file boundary before SQLite interprets the contents.
oversize := A_ScriptDir "\oversize.db", oversizeFile := FileOpen(oversize,"w")
oversizeFile.Length := 1024*1024+1, oversizeFile.Close(), message := ""
try SettingsRepository(oversize)
catch as failure
    message := failure.Message
Assert(InStr(message,"上限1MiB") && FileGetSize(oversize)=1024*1024+1,"oversized database is rejected before open and left intact")
FileAppend("PASS: " Checks " storage boundary checks with reduced isolated limits`n","*")
ExitApp()
'@
Invoke-AhkTest -Runtime $limitsRuntime -Source $limitsTests
