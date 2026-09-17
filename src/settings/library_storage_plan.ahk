; Build a transactional delta. Published arrays are immutable; cached rows own values.
BuildLibraryStoragePlan(state, previous, force := false) {
    if state.Profiles.Length > 10000
        throw Error("配信者数は10000件までです。")
    scopes := Map(), touched := [], channels := Map(), total := 0, textBytes := 0
    channels.CaseSense := "On", scopes.CaseSense := "On"
    candidates := [{Id:"@shared",Name:"",Channel:"",Items:state.SharedDanmakuItems}]
    for profile in state.Profiles
        candidates.Push(profile)
    for index, profile in candidates {
        if !profile.Id || scopes.Has(profile.Id) || (index > 1 && profile.Id = "@shared")
            throw Error("配信者の識別子が重複しています。")
        ValidateSettingsText(profile.Name,"配信者名",index > 1)
        ValidateSettingsText(profile.Channel,"チャンネルID")
        if profile.Channel != "" {
            if channels.Has(profile.Channel)
                throw Error("同じチャンネルが複数の配信者に連携されています。移行前に連携を修正してください。")
            channels[profile.Channel] := true
        }
        old := previous.Get(profile.Id,0)
        scope := {Id:profile.Id,Name:profile.Name,Channel:profile.Channel,Position:index-1,Items:profile.Items}
        if !force && old && ObjPtr(old.Items) = ObjPtr(profile.Items) {
            scope.Rows := old.Rows
            scope.TextBytes := old.TextBytes
        } else {
            delta := !force && old ? TryLibraryStorageDelta(profile.Items,old) : 0
            if delta {
                scope.Rows := delta.Rows, scope.TextBytes := delta.TextBytes
                scope.Changed := delta.Changed, scope.Deleted := delta.Deleted
            } else {
                scope.Rows := BuildItemStorageRows(profile.Items,old ? old.Rows : Map(),force)
                scope.TextBytes := 0, scope.Changed := [], scope.Deleted := []
                for itemId, row in scope.Rows {
                    scope.TextBytes += StorageRowBytes(row)
                    if !old || !old.Rows.Has(itemId) || !SameStoredItem(row,old.Rows[itemId])
                        scope.Changed.Push(itemId)
                }
                if old {
                    for itemId in old.Rows
                        if !scope.Rows.Has(itemId)
                            scope.Deleted.Push(itemId)
                }
            }
            touched.Push(scope.Id)
        }
        total += scope.Rows.Count
        textBytes += scope.TextBytes+(StrLen(scope.Name)+StrLen(scope.Channel))*2
        scopes[scope.Id] := scope
    }
    if total > 100000
        throw Error("弾幕の総数は100000件までです。")
    if textBytes > 32*1024*1024
        throw Error("設定の文字列合計が上限32MiBを超えます。")
    ; Cross-scope ID uniqueness is checked by the database PRIMARY KEY.
    return {Scopes:scopes,Touched:touched}
}
BuildItemStorageRows(items, previous, force := false) {
    rows := Map(), slots := Map(), positions := [], existing := []
    rows.CaseSense := "On"
    for item in items {
        if !item.HasOwnProp("Id") || !item.Id
            item.Id := NewRecordId()
        if rows.Has(item.Id)
            throw Error("弾幕の識別子が重複しています。")
        priorRow := previous.Get(item.Id,0)
        unchanged := !force && priorRow && priorRow.HasOwnProp("Item") && ObjPtr(priorRow.Item) = ObjPtr(item)
        if !unchanged {
            ValidateSettingsText(item.Name,"弾幕名",true)
            ValidateSettingsText(item.Text,"弾幕本文",true)
        }
        slot := ItemSlot(item)
        if !HasSettingValue([0,1,2],slot) || (slot && slots.Has(slot))
            throw Error("弾幕キーの割当が重複または不正です。")
        if slot
            slots[slot] := true
        row := {Id:item.Id,Name:item.Name,Text:item.Text,Slot:slot,Position:0,Item:item}
        rows[item.Id] := row
        if previous.Has(item.Id) {
            positions.Push(previous[item.Id].Position)
            existing.Push(row)
        }
    }
    ; Sorted available ranks preserve gaps on deletion and only swap two ranks on up/down.
    ranks := "", ordered := true, last := 0
    for position in positions {
        ordered := ordered && position > last
        last := position
    }
    sorted := positions
    if !ordered {
        for position in positions
            ranks .= position "`n"
        sorted := StrSplit(RTrim(Sort(ranks,"N"),"`n"),"`n")
    }
    for i, row in existing
        row.Position := Integer(sorted[i])
    nextRanks := [], following := 0
    nextRanks.Length := items.Length
    Loop items.Length {
        i := items.Length-A_Index+1
        nextRanks[i] := following
        if rows[items[i].Id].Position
            following := rows[items[i].Id].Position
    }
    prior := 0, rebalance := false
    for i, item in items {
        row := rows[item.Id]
        if !row.Position {
            following := nextRanks[i]
            row.Position := following ? (prior+following)//2 : prior+1024
            if row.Position <= prior
                rebalance := true
        }
        prior := row.Position
    }
    if rebalance {
        for i, item in items
            rows[item.Id].Position := i*1024
    }
    return rows
}
SameStoredItem(a,b) {
    return a.Name == b.Name && a.Text == b.Text && a.Slot = b.Slot && a.Position = b.Position
}
