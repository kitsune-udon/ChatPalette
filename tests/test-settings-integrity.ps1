# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$tests = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
OnExit(CloseSettingsStore)
path := A_ScriptDir "\integrity.db"
for sql in ["DELETE FROM preferences", "DELETE FROM scopes WHERE id='@shared'",
    "DELETE FROM shortcut_bindings WHERE action='chat_focus'",
    "UPDATE shortcut_bindings SET action='CHAT_FOCUS' WHERE action='chat_focus'",
    "INSERT INTO shortcut_bindings VALUES('CHAT_FOCUS','^!f')",
    "INSERT INTO shortcut_bindings VALUES('reaction','^+F12')",
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
    numericStore.Db.Exec("UPDATE preferences SET reaction_kind=1.5")
    try numericStore.Load()
    catch
        rejected := true
    Assert(rejected && numericStore.Saved=baseline,"a lossy numeric read cannot replace a previously loaded baseline")
    numericStore.Db.Exec("UPDATE preferences SET reaction_kind=1")
    VerifySettingsRoundTrip(numericState,numericStore.Load())
    Assert(true,"load succeeds after an explicit repair of the invalid numeric value")
} finally numericStore.Close()
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
backup := A_ScriptDir "\reference-backup.db"
try BackupSettingsDatabase(backup)
catch
    rejected := true
Assert(rejected && !FileExist(backup),"backup rejects broken references before publishing the destination")
leftovers := 0
Loop Files backup ".creating-*"
    leftovers++
Assert(leftovers=0,"rejected backup removes its temporary database and journal")
actual := FileRead(SettingsDatabasePath,"RAW")
Assert(actual.Size=original.Size && DllCall("msvcrt\memcmp","Ptr",actual,"Ptr",original,"UPtr",actual.Size,"CDecl Int")=0,"rejected backup preserves the original database bytes")
source.Run("UPDATE items SET scope_id='@shared' WHERE id=?","orphan")
BackupSettingsDatabase(backup)
restored := SettingsRepository(backup)
try {
    loaded := restored.Load()
    Assert(loaded.SharedDanmakuItems.Length=1 && loaded.SharedDanmakuItems[1].Id="orphan"
        && loaded.SharedDanmakuItems[1].Text="important","backup retries after explicit repair and preserves the item")
} finally restored.Close()
FileAppend("PASS: " Checks " settings integrity checks; no application startup`n","*")
ExitApp()
'@
Invoke-AhkTest -Runtime $release -Source $tests
