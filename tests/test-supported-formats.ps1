# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
state := CreateDefaultSettings()
state.SharedDanmakuItems := [{Id:"format-item",Name:"kept",Text:"current body",Slot:1}]
state.ShortcutKeys["chat_clear"] := "^+w", state.ShortcutKeys["reactions_show"] := ""
path := A_ScriptDir "\current.db"
store := SettingsRepository(path,true)
try {
    store.SaveAll(state)
    Assert(store.Db.Scalar("PRAGMA user_version")=5,"new DB uses current schema5")
} finally store.Close()
for readOnly in [false,true] {
    store := SettingsRepository(path,false,readOnly)
    try VerifySettingsRoundTrip(state,store.Load())
    finally store.Close()
}
data := ReadStoredUserData(path), jsonPath := A_ScriptDir "\current.json"
WriteUserData(data,jsonPath)
roundTrip := ReadUserData(jsonPath)
VerifySettingsRoundTrip(state,roundTrip.State)
Assert(roundTrip.State.ShortcutKeys["chat_clear"]="^+w" && roundTrip.State.ShortcutKeys["reactions_show"]="",
    "current formats preserve custom and optional unassigned keys")
codec := SqliteConnection(":memory:",true)
try {
    json := FileRead(jsonPath,"UTF-8")
    Assert(codec.Scalar("SELECT json_extract(?,'$.version')",json)=2,"export uses JSON2")
    invalidJsons := [codec.Scalar("SELECT json_set(?,'$.version',1)",json),
        codec.Scalar("SELECT json_set(?,'$.version',3)",json),
        codec.Scalar("SELECT json_remove(?,'$.preferences.shortcutKeys.chat_send')",json),
        codec.Scalar("SELECT json_set(?,'$.preferences.shortcutKeys.unknown','^+x')",json),
        StrReplace(json,'"chat_send": "^!e"','"chat_send": "^!e", "CHAT_SEND": "^!e"')]
    for index, invalid in invalidJsons {
        source := A_ScriptDir "\invalid-" index ".json"
        FileAppend(invalid,source,"UTF-8-RAW"), raw := FileRead(source,"RAW"), rejected := false
        try ReadUserData(source)
        catch
            rejected := true
        Assert(rejected && SameFormatBytes(raw,FileRead(source,"RAW")),"unsupported or malformed JSON is rejected unchanged: " index)
    }
} finally codec.Close()
for version in [0,1,3,4,SettingsRepository.SchemaVersion+1] {
    for mode in (version=4 ? ["DELETE","WAL"] : ["DELETE"]) {
        source := A_ScriptDir "\unsupported-" version "-" mode ".db"
        FileCopy(path,source,false), db := SqliteConnection(source)
        db.Exec("PRAGMA user_version=" version)
        Assert(StrUpper(db.Scalar("PRAGMA journal_mode=" mode))=mode,"fixture journal mode: " mode)
        db.Close(), raw := FileRead(source,"RAW")
        AssertFormatSidecars(source,mode)
        for operation in ["writable","readonly","snapshot"] {
            rejected := false, store := 0
            try {
                if operation="snapshot"
                    ReadStoredUserData(source)
                else {
                    store := SettingsRepository(source,false,operation="readonly")
                    store.Load()
                }
            } catch
                rejected := true
            finally {
                if store
                    store.Close()
            }
            Assert(rejected && SameFormatBytes(raw,FileRead(source,"RAW")),
                "unsupported DB rejected unchanged: " version "/" mode "/" operation)
            AssertFormatSidecars(source,mode)
        }
    }
}
; Keep a writer open so committed version4 remains in WAL, not the main header.
source := A_ScriptDir "\committed-wal.db"
FileCopy(path,source,false), writer := SqliteConnection(source)
try {
    writer.Exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=4")
    raw := FileRead(source,"RAW"), wal := FileRead(source "-wal","RAW")
    Assert(wal.Size>0,"fixture contains committed WAL data")
    for operation in ["writable","readonly","snapshot"] {
        rejected := false, store := 0
        try {
            if operation="snapshot"
                ReadStoredUserData(source)
            else
                store := SettingsRepository(source,false,operation="readonly")
        } catch
            rejected := true
        finally {
            if store
                store.Close()
        }
        Assert(rejected && SameFormatBytes(raw,FileRead(source,"RAW"))
            && SameFormatBytes(wal,FileRead(source "-wal","RAW")),"committed unsupported WAL is rejected and preserved: " operation)
    }
} finally writer.Close()
for sql in ["DELETE FROM shortcut_bindings WHERE action='chat_send'",
    "INSERT INTO shortcut_bindings VALUES('unknown','^+x')",
    "UPDATE shortcut_bindings SET key='^+w' WHERE action='chat_focus'",
    "UPDATE items SET body=char(0)||'hidden'",
    "INSERT INTO reaction_registrations VALUES('fixture','{}')"] {
    source := A_ScriptDir "\malformed-" A_Index ".db"
    FileCopy(path,source,false), db := SqliteConnection(source)
    db.Exec(sql), db.Close(), raw := FileRead(source,"RAW"), rejected := false
    try ReadStoredUserData(source)
    catch
        rejected := true
    Assert(rejected && SameFormatBytes(raw,FileRead(source,"RAW")),"malformed current DB rejected unchanged: " sql)
}
'@ -Helpers @'
SameFormatBytes(first,second) {
    if first.Size!=second.Size
        return false
    Loop first.Size
        if NumGet(first,A_Index-1,"UChar")!=NumGet(second,A_Index-1,"UChar")
            return false
    return true
}
AssertFormatSidecars(path,mode) {
    Assert(!FileExist(path "-journal"),"rejected source leaves no rollback journal")
    if mode="WAL" {
        ; Read-only SQLite may create an empty WAL and engine-managed SHM.
        Assert(!FileExist(path "-wal") || FileGetSize(path "-wal")=0,"rejected clean WAL source has no committed changes")
    } else {
        Assert(!FileExist(path "-wal") && !FileExist(path "-shm"),"DELETE source remains without WAL sidecars")
    }
}
'@
