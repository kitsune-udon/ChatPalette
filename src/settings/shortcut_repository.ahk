CreateShortcutSchema(db) {
    db.Exec("CREATE TABLE shortcut_bindings(action TEXT PRIMARY KEY NOT NULL, key TEXT NOT NULL)")
    keys := ImportShortcutKeys(db.Scalar("SELECT reaction_key FROM preferences WHERE id=1"))
    for action, key in keys
        if action != "reaction"
            db.Run("INSERT INTO shortcut_bindings VALUES(?,?)",action,key)
    db.Exec("PRAGMA user_version=3")
}
ReadShortcutKeys(db) {
    keys := Map()
    for row in db.Rows("SELECT action,key FROM shortcut_bindings")
        keys[row[1]] := row[2]
    return keys
}

; Convert an older persisted reaction-only key at the storage boundary.
ImportShortcutKeys(reactionKey) {
    keys := DefaultShortcutKeys()
    if reactionKey = ""
        return keys
    for action,key in keys
        if action != "reaction" && CanonicalShortcutKey(key) = CanonicalShortcutKey(reactionKey)
            keys[action] := ""
    keys["reaction"] := reactionKey
    return keys
}
