; Pure key validation and normalization; no UI or hotkey registration.
ValidReactionKey(key) {
    return !IsReservedReactionKey(key) && RegExMatch(key, "^[!^+]*(?:[A-Za-z0-9]|F(?:[1-9]|1[0-2]))$")
        && InStr(key, "^") && (InStr(key, "!") || InStr(key, "+"))
}

CanonicalReactionKey(key) {
    return (InStr(key,"^") ? "^" : "") (InStr(key,"!") ? "!" : "") (InStr(key,"+") ? "+" : "") StrLower(RegExReplace(key,"[!^+]",""))
}

IsReservedReactionKey(key) {
    plain := StrLower(RegExReplace(key, "[!^+]", ""))
    return InStr(key, "^") && InStr(key, "!") && !InStr(key, "+") && (plain = "1" || plain = "2" || plain = "3" || plain = "4" || plain = "q")
}
