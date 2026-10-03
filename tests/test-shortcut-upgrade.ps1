# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
legacy := DefaultShortcutKeys(), legacy.Delete("chat_send")
legacy["chat_clear"] := "^!c", legacy["reactions_show"] := "^!e", legacy["reaction"] := "^!r"
cases := [legacy]
canonical := legacy.Clone(), canonical["chat_clear"] := "!^C", canonical["reactions_show"] := "!^E", canonical["reaction"] := "!^R"
cases.Push(canonical)
custom := legacy.Clone(), custom["chat_clear"] := "^+w", custom["reactions_show"] := "^+r", custom["reaction"] := "^+t"
cases.Push(custom)
blockedW := legacy.Clone(), blockedW["chat_focus"] := "^!w", cases.Push(blockedW)
blockedT := legacy.Clone(), blockedT["chat_focus"] := "^!t", cases.Push(blockedT)
occupiedE := legacy.Clone(), occupiedE["reactions_show"] := "^+r", occupiedE["palette"] := "^!e", cases.Push(occupiedE)
unassigned := legacy.Clone(), unassigned["chat_clear"] := "", unassigned["reactions_show"] := "", cases.Push(unassigned)
expected := UpgradeLegacyShortcutKeys(legacy)
Assert(expected["chat_clear"]="^!w" && expected["reactions_show"]="^!r" && expected["reaction"]="^!t"
    && expected["chat_send"]="^!e","old defaults migrate together to all four new keys")
Assert(UpgradeLegacyShortcutKeys(canonical)["chat_send"]="^!e","canonical modifier order and case migrate")
Assert(UpgradeLegacyShortcutKeys(custom)["reaction"]="^+t","custom assignments remain unchanged")
Assert(UpgradeLegacyShortcutKeys(blockedW)["chat_clear"]="^!c","custom W keeps the blocked old clear key")
chain := UpgradeLegacyShortcutKeys(blockedT)
Assert(chain["reaction"]="^!r" && chain["reactions_show"]="^!e" && chain["chat_send"]="",
    "custom T reverts reaction and display candidates without replacing a custom key")
Assert(UpgradeLegacyShortcutKeys(occupiedE)["chat_send"]="","custom E leaves new send unassigned")
Assert(UpgradeLegacyShortcutKeys(unassigned)["chat_clear"]="","optional unassigned key is preserved")

codec := SqliteConnection(":memory:",true)
try {
    for index, oldKeys in cases {
        path := A_ScriptDir "\legacy-" index ".db"
        CreateLegacyKeysDatabase(path,oldKeys)
        raw := FileRead(path,"RAW"), expected := UpgradeLegacyShortcutKeys(oldKeys)
        imported := ReadStoredUserData(path)
        Assert(SameLegacyBytes(raw,FileRead(path,"RAW")),"read-only legacy DB import leaves original bytes unchanged: " index)
        AssertSameKeys(expected,imported.State.ShortcutKeys,"legacy DB normalized keys: " index)
        v2 := A_ScriptDir "\current-" index ".json"
        WriteUserData(imported,v2)
        text := FileRead(v2,"UTF-8")
        Assert(codec.Scalar("SELECT json_extract(?,'$.version')",text)=2,"export uses JSON version2")
        v1 := codec.Scalar("SELECT json_set(?,'$.version',1,'$.preferences.shortcutKeys',json(?))",text,EncodeUserDataValue(codec,oldKeys))
        legacyJson := A_ScriptDir "\legacy-" index ".json"
        FileAppend(v1,legacyJson,"UTF-8-RAW")
        AssertSameKeys(expected,ReadUserData(legacyJson).State.ShortcutKeys,"JSONv1 uses the same conversion: " index)
        Assert(FileRead(legacyJson,"UTF-8")==v1,"legacy JSON source remains unchanged")
        if index=1 {
            badJsons := [codec.Scalar("SELECT json_remove(?,'$.preferences.shortcutKeys.reaction')",v1),
                codec.Scalar("SELECT json_set(?,'$.preferences.shortcutKeys.unknown','^+x')",v1),
                codec.Scalar("SELECT json_set(?,'$.preferences.shortcutKeys.chat_send','^+x')",v1),
                StrReplace(v1,'"reaction":"^!r"','"reaction":"^!r","reaction":"^!r"'),
                codec.Scalar("SELECT json_remove(?,'$.preferences.shortcutKeys.chat_send')",text),
                codec.Scalar("SELECT json_set(?,'$.version',99)",text)]
            for invalidIndex, invalidJson in badJsons {
                invalidPath := A_ScriptDir "\invalid-legacy-json-" invalidIndex ".json"
                FileAppend(invalidJson,invalidPath,"UTF-8-RAW"), rejected := false
                try ReadUserData(invalidPath)
                catch
                    rejected := true
                Assert(rejected && FileRead(invalidPath,"UTF-8")==invalidJson,
                    "invalid legacy/current JSON shape or version rejected unchanged: " invalidIndex)
            }
        }
        store := SettingsRepository(path)
        try {
            migrated := store.Load()
            AssertSameKeys(expected,migrated.ShortcutKeys,"writable DB upgrade: " index)
            Assert(store.Db.Scalar("PRAGMA user_version")=5 && store.Db.Scalar("SELECT COUNT(*) FROM shortcut_bindings")=11,
                "upgrade commits version and complete action set together")
            Assert(migrated.SharedDanmakuItems[1].Text="legacy body","upgrade preserves user library")
            changes := store.Db.Scalar("SELECT total_changes()")
            store.Load()
            Assert(store.Db.Scalar("SELECT total_changes()")=changes,"repeated load does not upgrade twice")
        } finally store.Close()
    }
} finally codec.Close()

for sql in ["DELETE FROM shortcut_bindings WHERE action='reaction'",
    "INSERT INTO shortcut_bindings VALUES('unknown','^+x')",
    "INSERT INTO shortcut_bindings VALUES('chat_send','^+x')",
    "UPDATE shortcut_bindings SET key='^!c' WHERE action='chat_focus'",
    "UPDATE items SET body=char(0)||'hidden'",
    "INSERT INTO reaction_registrations VALUES('fixture','{}')"] {
    path := A_ScriptDir "\invalid-" A_Index ".db"
    CreateLegacyKeysDatabase(path,legacy)
    db := SqliteConnection(path)
    db.Exec(sql), db.Exec("PRAGMA journal_mode=WAL"), db.Close()
    raw := FileRead(path,"RAW"), rejected := false, store := 0
    try {
        store := SettingsRepository(path)
        store.Load()
    } catch
        rejected := true
    finally {
        if store
            store.Close()
    }
    Assert(rejected && SameLegacyBytes(raw,FileRead(path,"RAW")),"invalid legacy DB rejected before persistent configuration: " sql)
    db := SqliteConnection(path,false,true)
    Assert(db.Scalar("PRAGMA user_version")=4,"invalid source keeps its old version")
    db.Close()
}

path := A_ScriptDir "\rollback.db"
CreateLegacyKeysDatabase(path,legacy)
store := SettingsRepository(path)
originalExec := SqliteConnection.Prototype.Exec.Bind(store.Db)
store.Db.DefineProp("Exec",{Call:(db,sql) => FailAfterUpgradeVersion(db,sql,originalExec)})
rejected := false
try store.Load()
catch
    rejected := true
Assert(rejected && !store.Saved && store.Version=4,"failed upgrade does not publish new runtime state")
Assert(store.Db.Scalar("PRAGMA user_version")=4 && store.Db.Scalar("SELECT COUNT(*) FROM shortcut_bindings")=10
    && store.Db.Scalar("SELECT key FROM shortcut_bindings WHERE action='chat_clear'")="^!c",
    "failure after version write rolls back version, added action and changed keys")
store.Db.DeleteProp("Exec")
Assert(store.Load().ShortcutKeys["chat_send"]="^!e","same legacy database can upgrade after failure recovery")
store.Close()
'@ -Helpers @'
CreateLegacyKeysDatabase(path,keys) {
    state := CreateDefaultSettings()
    state.SharedDanmakuItems := [{Id:"legacy-item",Name:"legacy",Text:"legacy body",Slot:1}]
    state.ShortcutKeys := keys.Clone(), state.ShortcutKeys["chat_send"] := ""
    store := SettingsRepository(path,true)
    try {
        store.SaveAll(state)
        store.Db.Exec("DELETE FROM shortcut_bindings WHERE action='chat_send'; PRAGMA user_version=4")
    } finally store.Close()
}
AssertSameKeys(expected,actual,label) {
    matches := expected.Count=actual.Count
    for action,key in expected
        matches := matches && actual.Has(action) && actual[action]==key
    Assert(matches,label)
}
SameLegacyBytes(first,second) {
    if first.Size!=second.Size
        return false
    Loop first.Size
        if NumGet(first,A_Index-1,"UChar")!=NumGet(second,A_Index-1,"UChar")
            return false
    return true
}
FailAfterUpgradeVersion(db,sql,original) {
    original.Call(sql)
    if sql="PRAGMA user_version=5"
        throw Error("Injected failure after migration version write")
}
'@
