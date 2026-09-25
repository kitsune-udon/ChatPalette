; SQLite schema and persistence. No UI, shortcut registration, or browser ownership.
class SettingsRepository {
    static ApplicationId := 1129335892
    __New(path, create := false) {
        if FileExist(path) && FileGetSize(path)>128*1024*1024
            throw Error("設定データベースが上限128MiBを超えています。")
        this.Path := path, this.Scopes := Map(), this.Scopes.CaseSense := "On", this.Loaded := create
        this.Db := SqliteConnection(path,create)
        try {
            if create {
                this.Db.ConfigureStorage()
                this.Db.Transaction(ObjBindMethod(this,"CreateSchema"))
            } else {
                if this.Db.Scalar("PRAGMA application_id") != SettingsRepository.ApplicationId
                    throw Error("ChatPaletteの設定データベースではありません。")
                version := this.Db.Scalar("PRAGMA user_version")
                if version != "1" && version != "2" && version != "3"
                    throw Error("未対応の設定形式です。対応するChatPaletteで開いてください。")
                this.Db.ConfigureStorage()
                if version = "1"
                    this.Db.Transaction(() => CreateReactionRegistrationSchema(this.Db,this.Path))
                if version != "3"
                    this.Db.Transaction(() => CreateShortcutSchema(this.Db))
            }
            this.Db.Exec("PRAGMA max_page_count=" (128*1024*1024//Integer(this.Db.Scalar("PRAGMA page_size"))))
        } catch as failure {
            ; Keep the schema error even if a broken connection cannot close cleanly.
            try this.Db.Close()
            catch {
            }
            throw failure
        }
    }
    CreateSchema() {
        this.Db.Exec("CREATE TABLE scopes(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, channel TEXT UNIQUE, position INTEGER NOT NULL CHECK(position>=0));"
            . "CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL, scope_id TEXT NOT NULL REFERENCES scopes(id) ON DELETE CASCADE, position INTEGER NOT NULL, name TEXT NOT NULL, body TEXT NOT NULL, slot INTEGER CHECK(slot IS NULL OR slot IN(1,2)), UNIQUE(scope_id,position), UNIQUE(scope_id,slot));"
            . "CREATE TABLE preferences(id INTEGER PRIMARY KEY CHECK(id=1), active_scope TEXT REFERENCES scopes(id) ON DELETE SET NULL, auto_mode INTEGER NOT NULL CHECK(auto_mode IN(0,1)), reaction_kind INTEGER NOT NULL, reaction_count INTEGER NOT NULL, reaction_interval INTEGER NOT NULL, reaction_key TEXT NOT NULL);"
            . "PRAGMA application_id=" SettingsRepository.ApplicationId "; PRAGMA user_version=1")
        CreateReactionRegistrationSchema(this.Db,this.Path)
        CreateShortcutSchema(this.Db)
    }
    Load() {
        return this.Db.Transaction(ObjBindMethod(this,"ReadState"),false)
    }
    ReadState() {
        if Integer(this.Db.Scalar("SELECT COUNT(*) FROM scopes"))>10001 || Integer(this.Db.Scalar("SELECT COUNT(*) FROM items"))>100000
            throw Error("設定の件数が上限を超えています。")
        state := {Profiles:[],SharedDanmakuItems:[],InputProfileId:""}, scopes := Map()
        scopes.CaseSense := "On"
        for row in this.Db.Rows("SELECT id,name,channel,position FROM scopes ORDER BY position,id") {
            scope := {Id:row[1],Name:row[2],Channel:row[3],Position:Integer(row[4]),Items:[],Rows:Map()}
            scope.Rows.CaseSense := "On"
            scopes[scope.Id] := scope
            if scope.Id = "@shared"
                state.SharedDanmakuItems := scope.Items
            else
                state.Profiles.Push({Id:scope.Id,Name:scope.Name,Channel:scope.Channel,Items:scope.Items})
        }
        if !scopes.Has("@shared")
            throw Error("共通弾幕の保存領域がありません。")
        for row in this.Db.Rows("SELECT id,scope_id,position,name,body,COALESCE(slot,0) FROM items ORDER BY scope_id,position") {
            if !scopes.Has(row[2])
                throw Error("弾幕の所属先がありません。")
            scope := scopes[row[2]], item := {Id:row[1],Name:row[4],Text:row[5],Slot:Integer(row[6])}
            scope.Items.Push(item)
            scope.Rows[item.Id] := {Id:item.Id,Name:item.Name,Text:item.Text,Slot:item.Slot,Position:Integer(row[3]),Item:item}
            if Integer(row[3]) <= 0
                throw Error("弾幕の保存順序が不正です。")
        }
        prefs := this.Db.Rows("SELECT active_scope,auto_mode,reaction_kind,reaction_count,reaction_interval,reaction_key FROM preferences WHERE id=1")
        if prefs.Length != 1
            throw Error("共通設定がありません。")
        row := prefs[1]
        state.InputProfileId := row[1]
        if row[1] != "" && !FindProfileIndexById(state.Profiles,state.InputProfileId)
            throw Error("選択中の配信者がありません。")
        state.AutoMode := Integer(row[2]), state.DefaultReactionKind := Integer(row[3]), state.DefaultReactionCount := Integer(row[4])
        state.DefaultReactionIntervalMs := Integer(row[5])
        state.ShortcutKeys := ReadShortcutKeys(this.Db)
        state.ShortcutKeys["reaction"] := row[6]
        ValidateSettingsPreferences(state)
        validated := BuildLibraryStoragePlan(state,scopes,true)
        for id, scope in scopes
            scope.TextBytes := validated.Scopes[id].TextBytes
        this.Scopes := scopes
        this.PreferenceValues := this.PreferenceRow(state)
        this.DataVersion := this.Db.Scalar("PRAGMA data_version")
        this.Loaded := true
        return state
    }
    EnsureLoaded() {
        if !this.Loaded
            this.Load()
    }
    SaveAll(state) {
        this.EnsureLoaded()
        ValidateSettingsPreferences(state)
        plan := BuildLibraryStoragePlan(state,this.Scopes,true)
        this.Write(plan,this.PreferenceRow(state))
    }
    SaveLibrary(library, inputProfileId) {
        this.EnsureLoaded()
        plan := BuildLibraryStoragePlan(library,this.Scopes)
        values := this.PreferenceValues.Clone()
        values[1] := inputProfileId
        this.Write(plan,values)
    }
    SavePreferences(preferences) {
        this.EnsureLoaded()
        ValidateSettingsPreferences(preferences)
        this.Write(0,this.PreferenceRow(preferences))
    }
    Write(plan,values) {
        scopes := plan ? plan.Scopes : this.Scopes
        if values[1] != "" && (values[1] = "@shared" || !scopes.Has(values[1]))
            throw Error("選択中の配信者がありません。")
        version := this.Db.Transaction(() => this.Apply(plan,values))
        if plan
            this.Scopes := plan.Scopes
        this.PreferenceValues := values
        this.DataVersion := version
    }
    PreferenceRow(state) {
        active := state.InputProfileId
        values := [active,Integer(state.AutoMode),Integer(state.DefaultReactionKind),Integer(state.DefaultReactionCount),Integer(state.DefaultReactionIntervalMs),state.ShortcutKeys["reaction"]]
        keys := state.ShortcutKeys
        for definition in ShortcutDefinitions()
            if definition.Id != "reaction"
                values.Push(keys[definition.Id])
        return values
    }
    ; Call inside the write transaction, after its lock has been acquired.
    VerifyDataVersion() {
        version := this.Db.Scalar("PRAGMA data_version")
        if this.HasOwnProp("DataVersion") && this.DataVersion != version
            throw Error("設定が別の接続で変更されました。再起動して最新の設定を読み込んでください。")
        return version
    }
    Apply(plan,values) {
        version := this.VerifyDataVersion()
        if plan
            this.ApplyLibrary(plan)
        previous := this.HasOwnProp("PreferenceValues") ? this.PreferenceValues : 0
        baseChanged := !previous
        if previous {
            Loop 6 {
                if !(values[A_Index] == previous[A_Index]) {
                    baseChanged := true
                    break
                }
            }
        }
        if baseChanged
            this.Db.Run("INSERT OR REPLACE INTO preferences VALUES(1,NULLIF(?,''),?,?,?,?,?)",values[1],values[2],values[3],values[4],values[5],values[6])
        i := 6
        for definition in ShortcutDefinitions() {
            if definition.Id = "reaction"
                continue
            i++
            if !previous || !(values[i] == previous[i])
                this.Db.Run("UPDATE shortcut_bindings SET key=? WHERE action=?",values[i],definition.Id)
        }
        return version
    }
    ApplyLibrary(plan) {
        ; Remove changed ownership first, then insert/update. A failed step rolls it all back.
        for id, old in this.Scopes {
            if !plan.Scopes.Has(id)
                this.Db.Run("DELETE FROM scopes WHERE id=?",id)
        }
        for id, scope in plan.Scopes {
            old := this.Scopes.Get(id,0)
            if old && !(old.Channel == scope.Channel)
                this.Db.Run("UPDATE scopes SET channel=NULL WHERE id=?",id)
        }
        for id, scope in plan.Scopes {
            old := this.Scopes.Get(id,0)
            if !old
                this.Db.Run("INSERT INTO scopes VALUES(?,?,NULLIF(?,''),?)",id,scope.Name,scope.Channel,scope.Position)
            else if !(old.Name == scope.Name) || !(old.Channel == scope.Channel) || old.Position != scope.Position
                this.Db.Run("UPDATE scopes SET name=?,channel=NULLIF(?,''),position=? WHERE id=?",scope.Name,scope.Channel,scope.Position,id)
        }
        changed := []
        for id in plan.Touched {
            scope := plan.Scopes[id], old := this.Scopes.Get(id,0)
            for itemId in scope.Deleted
                this.Db.Run("DELETE FROM items WHERE id=?",itemId)
            for itemId in scope.Changed {
                row := scope.Rows[itemId]
                prior := old ? old.Rows.Get(itemId,0) : 0
                changed.Push({Scope:id,Row:row,Existing:!!prior,Stage:prior && (prior.Position != row.Position || prior.Slot != row.Slot)})
            }
        }
        ; Temporary negative ranks avoid immediate UNIQUE conflicts during rank/slot swaps.
        for i, change in changed {
            if change.Stage
                this.Db.Run("UPDATE items SET position=?,slot=NULL WHERE id=?",-i,change.Row.Id)
        }
        for change in changed {
            row := change.Row
            if change.Existing
                this.Db.Run("UPDATE items SET scope_id=?,position=?,name=?,body=?,slot=NULLIF(?,0) WHERE id=?",change.Scope,row.Position,row.Name,row.Text,row.Slot,row.Id)
            else
                this.Db.Run("INSERT INTO items VALUES(?,?,?,?,?,NULLIF(?,0))",row.Id,change.Scope,row.Position,row.Name,row.Text,row.Slot)
        }
    }
    CheckIntegrity() {
        if this.Db.Scalar("PRAGMA integrity_check") != "ok" || this.Db.Rows("PRAGMA foreign_key_check").Length
            throw Error("設定データベースの整合性を確認できません。")
    }
    Close() {
        this.Db.Close()
    }
}
