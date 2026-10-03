; Versioned UTF-8 exchange documents, independent of the internal SQLite schema.
class UserDataJson {
    static Version := 2
    static MaxBytes := 128*1024*1024
}
ReadUserData(path) {
    if FileGetSize(path)>UserDataJson.MaxBytes
        throw Error("JSONファイルは128MiBまでです。")
    bytes := FileRead(path,"RAW")
    if !bytes.Size || bytes.Size>UserDataJson.MaxBytes
        throw Error("JSONファイルが空、またはサイズの上限を超えています。")
    length := DllCall("MultiByteToWideChar","UInt",65001,"UInt",8,"Ptr",bytes,"Int",bytes.Size,"Ptr",0,"Int",0)
    if !length
        throw Error("JSONファイルをUTF-8で保存してください。")
    decoded := Buffer((length+1)*2,0)
    if !DllCall("MultiByteToWideChar","UInt",65001,"UInt",8,"Ptr",bytes,"Int",bytes.Size,"Ptr",decoded,"Int",length)
        throw Error("JSONファイルを読み取れません。")
    json := StrGet(decoded,"UTF-16")
    if StrLen(json) != length
        throw Error("JSONにNUL文字が含まれています。")
    if SubStr(json,1,1)=Chr(0xFEFF)
        json := SubStr(json,2)
    store := SettingsRepository(":memory:",true)
    try {
        db := store.Db
        if db.Scalar("SELECT json_valid(?)",json) != 1
            throw Error("有効なJSONではありません。ChatPaletteのJSONエクスポートを選んでください。")
        ValidateUserDataEscapes(json)
        if db.Scalar("SELECT EXISTS(SELECT 1 FROM json_tree(?) WHERE typeof(key)='text' GROUP BY parent,key COLLATE NOCASE HAVING COUNT(*)>1)",json)
            throw Error("JSONに重複した項目があります。")
        root := ReadUserDataObject(db,json,Map("format","text","version","integer","profiles","array",
            "sharedItems","array","preferences","object","reactionRegistrations","array"))
        if !(root["format"] == "ChatPalette") || root["version"] != UserDataJson.Version
            throw Error("未対応のJSON形式です。対応するChatPaletteで開いてください。")
        prefs := ReadUserDataObject(db,root["preferences"],Map("inputProfileId","text","autoMode","integer",
            "reactionKind","integer","reactionCount","integer","reactionIntervalMs","integer","shortcutKeys","object"))
        keyShape := Map()
        for action,key in DefaultShortcutKeys()
            keyShape[action] := "text"
        state := {Profiles:[],InputProfileId:prefs["inputProfileId"],AutoMode:prefs["autoMode"],
            DefaultReactionKind:prefs["reactionKind"],DefaultReactionCount:prefs["reactionCount"],
            DefaultReactionIntervalMs:prefs["reactionIntervalMs"],ShortcutKeys:ReadUserDataObject(db,prefs["shortcutKeys"],keyShape)}
        total := 0
        state.SharedDanmakuItems := ReadUserDataItems(db,root["sharedItems"],&total)
        if db.Scalar("SELECT json_array_length(?)",root["profiles"])>SettingsLimits.Profiles
            throw Error("配信者数が上限を超えています。")
        for row in db.Rows("SELECT type,value FROM json_each(?)",root["profiles"]) {
            if row[1] != "object"
                throw Error("配信者の形式が不正です。")
            profile := ReadUserDataObject(db,row[2],Map("id","text","name","text","channel","text","items","array"))
            state.Profiles.Push({Id:profile["id"],Name:profile["name"],Channel:profile["channel"],
                Items:ReadUserDataItems(db,profile["items"],&total)})
        }
        registrations := [], browsers := Map(), registrationBytes := 0
        for row in db.Rows("SELECT type,value FROM json_each(?)",root["reactionRegistrations"]) {
            if row[1] != "object"
                throw Error("リアクション登録情報の形式が不正です。")
            browser := ValidateReactionRegistration(db,row[2])
            if browsers.Has(browser) || !(browser == db.Scalar("SELECT json_extract(?,'$.browser')",row[2]))
                throw Error("リアクション登録のブラウザーが不正または重複しています。")
            browsers[browser] := true
            registrationBytes += StrPut(row[2],"UTF-8")-1
            if registrationBytes>SettingsLimits.RegistrationsBytes
                throw Error("リアクション登録情報の合計サイズが上限を超えています。")
            registrations.Push(row[2])
        }
        ; The disposable schema checks cross-scope IDs, slots and selected-profile references.
        ReplaceStoredUserData(store,{State:state,Registrations:registrations})
        return store.Db.Transaction(() => ReadUserDataSnapshot(store),false)
    } finally store.Close()
}
ValidateUserDataEscapes(json) {
    position := 1
    while position := RegExMatch(json,'\\(?:u[0-9a-fA-F]{4}|["\\/bfnrt])',&escape,position) {
        token := escape[0], next := position+StrLen(token)
        if SubStr(token,2,1)="u" {
            code := Integer("0x" SubStr(token,3))
            if code=0
                throw Error("JSONにNUL文字が含まれています。")
            if code>=0xD800 && code<=0xDBFF {
                if !RegExMatch(SubStr(json,next,6),"^\\u[dD][c-fC-F][0-9a-fA-F]{2}$")
                    throw Error("JSONに不正なUnicode文字があります。")
                next += 6
            } else if code>=0xDC00 && code<=0xDFFF
                throw Error("JSONに不正なUnicode文字があります。")
        }
        position := next
    }
}
ReadUserDataObject(db,json,shape) {
    if db.Scalar("SELECT json_type(?)",json) != "object"
        throw Error("JSONの項目はオブジェクトで指定してください。")
    result := Map(), result.CaseSense := "On", expected := Map(), expected.CaseSense := "On"
    for key,kind in shape
        expected[key] := kind
    for row in db.Rows("SELECT key,type,value FROM json_each(?)",json) {
        if !expected.Has(row[1]) || expected[row[1]] != row[2] || result.Has(row[1])
            throw Error("JSONの項目名または型が不正です：" row[1])
        if row[2]="integer" && !(row[3] is Integer)
            throw Error("JSONの整数が範囲外です：" row[1])
        result[row[1]] := row[3]
    }
    if result.Count != shape.Count
        throw Error("JSONに必要な項目が不足しています。")
    return result
}
ReadUserDataItems(db,json,&total) {
    total += db.Scalar("SELECT json_array_length(?)",json)
    if total>SettingsLimits.Items
        throw Error("弾幕の総数が上限を超えています。")
    items := []
    for row in db.Rows("SELECT type,value FROM json_each(?)",json) {
        if row[1] != "object"
            throw Error("弾幕の形式が不正です。")
        item := ReadUserDataObject(db,row[2],Map("id","text","name","text","text","text","slot","integer"))
        items.Push({Id:item["id"],Name:item["name"],Text:item["text"],Slot:item["slot"]})
    }
    return items
}
ExportUserData(destination) {
    WriteUserData(ReadStoredUserData(SettingsDatabasePath),destination)
}
WriteUserData(data,destination) {
    if FileExist(destination)
        throw Error("保存先は既に存在します。新しいファイル名を指定してください。")
    db := SqliteConnection(":memory:",true), temporary := destination ".creating-" NewRecordId()
    try {
        state := data.State, profiles := []
        for profile in state.Profiles
            profiles.Push(Map("id",profile.Id,"name",profile.Name,"channel",profile.Channel,"items",UserDataItemMaps(profile.Items)))
        prefs := Map("inputProfileId",state.InputProfileId,"autoMode",state.AutoMode,"reactionKind",state.DefaultReactionKind,
            "reactionCount",state.DefaultReactionCount,"reactionIntervalMs",state.DefaultReactionIntervalMs,"shortcutKeys",state.ShortcutKeys)
        root := Map("format","ChatPalette","version",UserDataJson.Version,"profiles",profiles,
            "sharedItems",UserDataItemMaps(state.SharedDanmakuItems),"preferences",prefs)
        json := SubStr(EncodeUserDataValue(db,root),1,-2) ",`n  " db.Scalar("SELECT json_quote(?)","reactionRegistrations") ": ["
        for i,payload in data.Registrations
            json .= (i>1 ? "," : "") "`n    " db.Scalar("SELECT json(?)",payload)
        json .= (data.Registrations.Length ? "`n  " : "") "]`n}`n"
        if StrPut(json,"UTF-8")-1>UserDataJson.MaxBytes
            throw Error("JSONファイルが128MiBの上限を超えます。")
        FileAppend(json,temporary,"UTF-8-RAW")
        verified := ReadUserData(temporary)
        VerifySettingsRoundTrip(state,verified.State)
        if data.Registrations.Length != verified.Registrations.Length
            throw Error("リアクション登録の書き出し結果が一致しません。")
        for i,payload in data.Registrations
            if !(payload == verified.Registrations[i])
                throw Error("リアクション登録の書き出し結果が一致しません。")
        FileMove(temporary,destination,false)
    } finally {
        db.Close()
        if FileExist(temporary)
            FileDelete(temporary)
    }
}
UserDataItemMaps(items) {
    result := []
    for item in items
        result.Push(Map("id",item.Id,"name",item.Name,"text",item.Text,"slot",item.Slot))
    return result
}
EncodeUserDataValue(db,value,depth := 0) {
    if value is Integer
        return String(value)
    if value is String
        return db.Scalar("SELECT json_quote(?)",value)
    isArray := value is Array, indent := ""
    Loop depth
        indent .= "  "
    result := isArray ? "[" : "{", index := 0
    for key,child in value {
        result .= (index++ ? "," : "") "`n" indent "  "
            . (isArray ? "" : db.Scalar("SELECT json_quote(?)",key) ": ") EncodeUserDataValue(db,child,depth+1)
    }
    return result (index ? "`n" indent : "") (isArray ? "]" : "}")
}
