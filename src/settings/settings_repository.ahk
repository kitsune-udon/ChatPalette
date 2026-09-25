; SQLite schema and persistence. No UI, shortcut registration, or browser ownership.
class SettingsRepository {
    static ApplicationId := 1129335892
    __New(path, create := false) {
        if FileExist(path) && FileGetSize(path)>128*1024*1024
            throw Error("設定データベースが上限128MiBを超えています。")
        this.Path := path, this.Saved := 0
        this.Db := SqliteConnection(path,create)
        try {
            if create {
                this.Db.ConfigureStorage()
                this.Db.Transaction(ObjBindMethod(this,"CreateSchema"))
            } else {
                if this.Db.Scalar("PRAGMA application_id") != SettingsRepository.ApplicationId
                    throw Error("ChatPaletteの設定データベースではありません。")
                version := this.Db.Scalar("PRAGMA user_version")
                if version != "3"
                    throw Error("未対応の設定形式です。対応するChatPaletteで開いてください。")
                this.Db.ConfigureStorage()
            }
            this.Db.Exec("PRAGMA max_page_count=" (128*1024*1024//Integer(this.Db.Scalar("PRAGMA page_size"))))
            if create {
                scopes := Map(), scopes.CaseSense := "On"
                this.Saved := {Scopes:scopes,Preferences:0,DataVersion:this.Db.Scalar("PRAGMA data_version")}
            }
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
            . "PRAGMA application_id=" SettingsRepository.ApplicationId "; PRAGMA user_version=3")
        CreateReactionRegistrationSchema(this.Db)
        CreateShortcutSchema(this.Db)
    }
    Load() {
        loaded := this.Db.Transaction(ObjBindMethod(this,"ReadState"),false)
        this.Saved := loaded.Saved
        return loaded.State
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
            scope.Rows[item.Id] := CreateStorageRow(item,Integer(row[3]))
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
        state.ShortcutKeys := ReadShortcutKeys(this.Db,row[6])
        ValidateSettingsPreferences(state)
        validated := BuildLibraryStoragePlan(state,scopes,true)
        for id, scope in scopes
            scope.TextBytes := validated.Scopes[id].TextBytes
        ; The caller publishes this baseline only after the read transaction commits.
        return {State:state,Saved:{Scopes:scopes,Preferences:this.CopyPreferences(state),DataVersion:this.Db.Scalar("PRAGMA data_version")}}
    }
    EnsureLoaded() {
        if !this.Saved
            this.Load()
    }
    SaveAll(state) {
        this.EnsureLoaded()
        ValidateSettingsPreferences(state)
        plan := BuildLibraryStoragePlan(state,this.Saved.Scopes,true)
        this.Write(plan,this.CopyPreferences(state))
    }
    SaveLibrary(library, inputProfileId) {
        this.EnsureLoaded()
        plan := BuildLibraryStoragePlan(library,this.Saved.Scopes)
        preferences := this.Saved.Preferences.Clone()
        preferences.InputProfileId := inputProfileId
        this.Write(plan,preferences)
    }
    SavePreferences(preferences) {
        this.EnsureLoaded()
        ValidateSettingsPreferences(preferences)
        this.Write(0,this.CopyPreferences(preferences))
    }
    Write(plan,preferences) {
        scopes := plan ? plan.Scopes : this.Saved.Scopes
        active := preferences.InputProfileId
        if active != "" && (active = "@shared" || !scopes.Has(active))
            throw Error("選択中の配信者がありません。")
        version := this.Db.Transaction(() => this.Apply(plan,preferences))
        this.Saved := {Scopes:scopes,Preferences:preferences,DataVersion:version}
    }
    CopyPreferences(state) {
        return {InputProfileId:state.InputProfileId, AutoMode:Integer(state.AutoMode),
            DefaultReactionKind:Integer(state.DefaultReactionKind), DefaultReactionCount:Integer(state.DefaultReactionCount),
            DefaultReactionIntervalMs:Integer(state.DefaultReactionIntervalMs), ShortcutKeys:state.ShortcutKeys.Clone()}
    }
    ; Call inside the write transaction, after its lock has been acquired.
    VerifyDataVersion() {
        version := this.Db.Scalar("PRAGMA data_version")
        if this.Saved && this.Saved.DataVersion != version
            throw Error("設定が別の接続で変更されました。再起動して最新の設定を読み込んでください。")
        return version
    }
    Apply(plan,preferences) {
        version := this.VerifyDataVersion()
        if plan
            this.ApplyLibrary(plan)
        previous := this.Saved.Preferences
        baseChanged := !previous || !(preferences.InputProfileId == previous.InputProfileId)
            || preferences.AutoMode != previous.AutoMode || preferences.DefaultReactionKind != previous.DefaultReactionKind
            || preferences.DefaultReactionCount != previous.DefaultReactionCount
            || preferences.DefaultReactionIntervalMs != previous.DefaultReactionIntervalMs
            || !(preferences.ShortcutKeys["reaction"] == previous.ShortcutKeys["reaction"])
        if baseChanged
            this.Db.Run("INSERT OR REPLACE INTO preferences VALUES(1,NULLIF(?,''),?,?,?,?,?)",
                preferences.InputProfileId,preferences.AutoMode,preferences.DefaultReactionKind,
                preferences.DefaultReactionCount,preferences.DefaultReactionIntervalMs,preferences.ShortcutKeys["reaction"])
        for action, key in preferences.ShortcutKeys {
            if action != "reaction" && (!previous || !(key == previous.ShortcutKeys[action]))
                this.Db.Run("UPDATE shortcut_bindings SET key=? WHERE action=?",key,action)
        }
        return version
    }
    ApplyLibrary(plan) {
        ; Remove changed ownership first, then insert/update. A failed step rolls it all back.
        for id, old in this.Saved.Scopes {
            if !plan.Scopes.Has(id)
                this.Db.Run("DELETE FROM scopes WHERE id=?",id)
        }
        for id, scope in plan.Scopes {
            old := this.Saved.Scopes.Get(id,0)
            if old && !(old.Channel == scope.Channel)
                this.Db.Run("UPDATE scopes SET channel=NULL WHERE id=?",id)
        }
        for id, scope in plan.Scopes {
            old := this.Saved.Scopes.Get(id,0)
            if !old
                this.Db.Run("INSERT INTO scopes VALUES(?,?,NULLIF(?,''),?)",id,scope.Name,scope.Channel,scope.Position)
            else if !(old.Name == scope.Name) || !(old.Channel == scope.Channel) || old.Position != scope.Position
                this.Db.Run("UPDATE scopes SET name=?,channel=NULLIF(?,''),position=? WHERE id=?",scope.Name,scope.Channel,scope.Position,id)
        }
        changed := []
        for delta in plan.Changes {
            id := delta.Scope, scope := plan.Scopes[id], old := this.Saved.Scopes.Get(id,0)
            for itemId in delta.Deleted
                this.Db.Run("DELETE FROM items WHERE id=?",itemId)
            for itemId in delta.Changed {
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
    Close() {
        this.Db.Close()
    }
}
