CreateShortcutSchema(db) {
    db.Exec("CREATE TABLE shortcut_bindings(action TEXT PRIMARY KEY NOT NULL, key TEXT NOT NULL)")
    keys := DefaultShortcutKeys(db.Scalar("SELECT reaction_key FROM preferences WHERE id=1"))
    for action, key in keys
        db.Run("INSERT INTO shortcut_bindings VALUES(?,?)",action,key)
    db.Exec("PRAGMA user_version=3")
}
ReadShortcutKeys(db) {
    keys := Map()
    for row in db.Rows("SELECT action,key FROM shortcut_bindings")
        keys[row[1]] := row[2]
    return keys
}
