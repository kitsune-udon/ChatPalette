; Fast paths for immutable lists: reuse stored rows and only materialize changed items.
TryLibraryStorageDelta(items, old) {
    if items.Length = old.Items.Length {
        indices := [], previousIds := Map(), nextIds := Map()
        previousIds.CaseSense := "On", nextIds.CaseSense := "On"
        for i, item in items {
            if ObjPtr(item) = ObjPtr(old.Items[i])
                continue
            if !item.HasOwnProp("Id") || !old.Rows.Has(item.Id)
                return 0
            indices.Push(i), previousIds[old.Items[i].Id] := true, nextIds[item.Id] := true
        }
        if previousIds.Count != nextIds.Count
            return 0
        for id in previousIds
            if !nextIds.Has(id)
                return 0
        if !indices.Length
            return {Rows:old.Rows,TextBytes:old.TextBytes,Changed:[],Deleted:[]}
        result := {Rows:old.Rows.Clone(),TextBytes:old.TextBytes,Changed:[],Deleted:[]}
        for i in indices {
            item := items[i], prior := old.Rows[item.Id]
            row := CreateChangedStorageRow(item,old.Rows[old.Items[i].Id].Position)
            result.Rows[item.Id] := row
            result.TextBytes += StorageRowBytes(row)-StorageRowBytes(prior)
            if !SameStoredItem(row,prior)
                result.Changed.Push(item.Id)
        }
        return result
    }
    difference := items.Length-old.Items.Length
    if Abs(difference) != 1
        return 0
    inserted := difference=1, short := inserted ? old.Items : items, long := inserted ? items : old.Items
    index := 1
    while index <= short.Length && ObjPtr(short[index])=ObjPtr(long[index])
        index++
    i := index
    while i <= short.Length {
        if ObjPtr(short[i])!=ObjPtr(long[i+1])
            return 0
        i++
    }
    item := long[index]
    if !item.HasOwnProp("Id") || (inserted && old.Rows.Has(item.Id))
        return 0
    result := {Rows:old.Rows.Clone(),TextBytes:old.TextBytes,Changed:[],Deleted:[]}
    if inserted {
        preceding := index>1 ? old.Rows[items[index-1].Id].Position : 0
        following := index<=old.Items.Length ? old.Rows[old.Items[index].Id].Position : 0
        position := following ? (preceding+following)//2 : preceding+1024
        if position<=preceding
            return 0
        row := CreateChangedStorageRow(item,position)
        result.Rows[item.Id] := row, result.TextBytes += StorageRowBytes(row)
        result.Changed.Push(item.Id)
    } else {
        result.TextBytes -= StorageRowBytes(old.Rows[item.Id])
        result.Rows.Delete(item.Id), result.Deleted.Push(item.Id)
    }
    return result
}
CreateChangedStorageRow(item,position) {
    ValidateSettingsText(item.Name,"弾幕名",true)
    ValidateSettingsText(item.Text,"弾幕本文",true)
    slot := ItemSlot(item)
    if !HasSettingValue([0,1,2],slot)
        throw Error("弾幕キーの割当が不正です。")
    return {Id:item.Id,Name:item.Name,Text:item.Text,Slot:slot,Position:position,Item:item}
}
StorageRowBytes(row) {
    return (StrLen(row.Name)+StrLen(row.Text))*2
}
