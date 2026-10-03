CreateShortcutSchema(db) {
    db.Exec("CREATE TABLE shortcut_bindings(action TEXT PRIMARY KEY NOT NULL, key TEXT NOT NULL)")
    keys := DefaultShortcutKeys()
    for action, key in keys
        db.Run("INSERT INTO shortcut_bindings VALUES(?,?)",action,key)
}
; Assemble the complete key map once; no storage source may shadow another.
ReadShortcutKeys(db) {
    keys := Map()
    for row in db.Rows("SELECT action,key FROM shortcut_bindings") {
        if keys.Has(row[1])
            throw Error("キー設定の操作が重複しています。")
        keys[row[1]] := row[2]
    }
    return keys
}
