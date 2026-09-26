; Build a transactional delta. Published arrays are immutable; cached rows own values.
BuildLibraryStoragePlan(state, previous, force := false) {
    if state.Profiles.Length > 10000
        throw Error("配信者数は10000件までです。")
    scopes := Map(), changes := [], channels := Map(), total := 0, textBytes := 0
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
                throw Error("同じチャンネルが複数の配信者に連携されています。連携を修正してください。")
            channels[profile.Channel] := true
        }
        old := previous.Get(profile.Id,0)
        scope := {Id:profile.Id,Name:profile.Name,Channel:profile.Channel,Position:index-1,Items:profile.Items}
        if !force && old && old.Items = profile.Items {
            scope.Rows := old.Rows
            scope.TextBytes := old.TextBytes
        } else {
            delta := BuildScopeStorageDelta(profile.Items,old,force)
            scope.Rows := delta.Rows, scope.TextBytes := delta.TextBytes
            changes.Push({Scope:scope.Id,Changed:delta.Changed,Deleted:delta.Deleted})
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
    return {Scopes:scopes,Changes:changes}
}
; The same reconciliation handles edits, insertions, deletions, moves and undo.
BuildScopeStorageDelta(items, old, force := false) {
    first := 1, end := items.Length, oldEnd := old ? old.Items.Length : 0
    if old && !force {
        commonEnd := Min(end,oldEnd)
        while first <= commonEnd && items[first] = old.Items[first]
            first++
        while end >= first && oldEnd >= first && items[end] = old.Items[oldEnd]
            end--, oldEnd--
    }
    previous := Map(), previous.CaseSense := "On", changedItems := []
    if old {
        Loop Max(0,oldEnd-first+1) {
            id := old.Items[first+A_Index-1].Id
            previous[id] := old.Rows[id]
        }
    }
    Loop Max(0,end-first+1) {
        item := items[first+A_Index-1]
        if old && item.HasOwnProp("Id") && old.Rows.Has(item.Id) && !previous.Has(item.Id)
            throw Error("弾幕の識別子が重複しています。")
        changedItems.Push(item)
    }
    preceding := old && first > 1 ? old.Rows[old.Items[first-1].Id].Position : 0
    boundary := old && oldEnd < old.Items.Length ? old.Rows[old.Items[oldEnd+1].Id].Position : 0
    updated := BuildItemStorageRows(changedItems,previous,force,preceding,boundary)
    if !updated {
        previous := old.Rows
        updated := BuildItemStorageRows(items,previous,force)
    }
    result := {Rows:old ? old.Rows.Clone() : Map(), TextBytes:old && !force ? old.TextBytes : 0, Changed:[], Deleted:[]}
    if !old
        result.Rows.CaseSense := "On"
    for id, row in previous {
        if !force
            result.TextBytes -= StorageRowBytes(row)
        if !updated.Has(id) {
            result.Rows.Delete(id)
            result.Deleted.Push(id)
        }
    }
    for id, row in updated {
        result.Rows[id] := row
        result.TextBytes += StorageRowBytes(row)
        if !previous.Has(id) || !SameStoredItem(row,previous[id])
            result.Changed.Push(id)
    }
    return result
}

; Own the persisted values; retain the item only for unchanged-object comparison.
CreateStorageRow(item, position) {
    return {Id:item.Id,Name:item.Name,Text:item.Text,Slot:item.Slot,Position:position,Item:item}
}

BuildItemStorageRows(items, previous, force := false, preceding := 0, boundary := 0) {
    rows := Map(), slots := Map(), existing := [], ordered := true, last := 0
    rows.CaseSense := "On"
    for item in items {
        if !item.HasOwnProp("Id") || !item.Id
            throw Error("弾幕の識別子がありません。")
        if rows.Has(item.Id)
            throw Error("弾幕の識別子が重複しています。")
        priorRow := previous.Get(item.Id,0)
        unchanged := !force && priorRow && priorRow.Item = item
        if !unchanged {
            ValidateSettingsText(item.Name,"弾幕名",true)
            ValidateSettingsText(item.Text,"弾幕本文",true)
        }
        if !item.HasOwnProp("Slot")
            throw Error("弾幕キーの割当がありません。未割当は0を指定してください。")
        slot := item.Slot
        if (slot != 0 && slot != 1 && slot != 2) || (slot && slots.Has(slot))
            throw Error("弾幕キーの割当が重複または不正です。")
        if slot
            slots[slot] := true
        row := unchanged ? priorRow : CreateStorageRow(item,priorRow ? priorRow.Position : 0)
        rows[item.Id] := row
        if priorRow {
            ordered := ordered && priorRow.Position > last
            last := priorRow.Position
            existing.Push(item.Id)
        }
    }
    ; Sorted available ranks preserve gaps on deletion and only swap two ranks on up/down.
    if !ordered {
        ranks := ""
        for id in existing
            ranks .= rows[id].Position "`n"
        sorted := StrSplit(RTrim(Sort(ranks,"N"),"`n"),"`n")
        for i, id in existing
            SetStorageRowPosition(rows,id,Integer(sorted[i]))
    }
    ; Existing IDs already follow the requested order; use their next rank directly.
    prior := preceding, rebalance := false, nextExisting := 1
    for item in items {
        row := rows[item.Id]
        if row.Position
            nextExisting++
        else {
            following := nextExisting <= existing.Length ? rows[existing[nextExisting]].Position : boundary
            position := following ? (prior+following)//2 : prior+1024
            row := SetStorageRowPosition(rows,item.Id,position)
            if position <= prior
                rebalance := true
        }
        prior := row.Position
    }
    if rebalance && (preceding || boundary)
        return 0 ; Expand to the whole scope when the unchanged neighbors leave no rank gap.
    if rebalance {
        for i, item in items
            SetStorageRowPosition(rows,item.Id,i*1024)
    }
    return rows
}
SameStoredItem(a,b) {
    return a.Name == b.Name && a.Text == b.Text && a.Slot = b.Slot && a.Position = b.Position
}
; Published storage rows are immutable, just like library items and undo snapshots.
SetStorageRowPosition(rows, id, position) {
    row := rows[id]
    if row.Position != position {
        row := row.Clone(), row.Position := position
        rows[id] := row
    }
    return row
}
StorageRowBytes(row) {
    return (StrLen(row.Name)+StrLen(row.Text))*2
}
