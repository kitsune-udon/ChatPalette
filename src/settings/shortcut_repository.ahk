CreateShortcutSchema(db) {
    db.Exec("CREATE TABLE shortcut_bindings(action TEXT PRIMARY KEY NOT NULL, key TEXT NOT NULL)")
    keys := DefaultShortcutKeys()
    for action, key in keys
        if action != "reaction"
            db.Run("INSERT INTO shortcut_bindings VALUES(?,?)",action,key)
}
ReadShortcutKeys(db) {
    keys := Map()
    for row in db.Rows("SELECT action,key FROM shortcut_bindings")
        keys[row[1]] := row[2]
    return keys
}
