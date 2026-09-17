; Stable IDs shared by profiles, items, and isolated temporary files.
NewRecordId() {
    guid := Buffer(16), text := Buffer(78)
    if DllCall("ole32\CoCreateGuid", "Ptr", guid, "Int") != 0
        throw Error("識別子を作成できませんでした。")
    DllCall("ole32\StringFromGUID2", "Ptr", guid, "Ptr", text, "Int", 39)
    return StrGet(text)
}
