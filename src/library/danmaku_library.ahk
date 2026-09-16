GetDanmakuItems(common, profile) {
    return common ? SharedDanmakuItems : (profile ? profile.Items : [])
}
ItemSlot(item) {
    return item.HasOwnProp("Slot") ? item.Slot : 0
}
NormalizeLibrarySlots(items) {
    used := Map()
    for item in items {
        slot := ItemSlot(item)
        if slot < 1 || slot > 2 || used.Has(slot)
            slot := 0
        item.Slot := slot
        if slot
            used[slot] := true
    }
}
AssignItemSlot(items, index, slot) {
    if !IsInteger(index) || !IsInteger(slot) || index < 1 || index > items.Length || slot < 0 || slot > 2
        throw Error("キーの割当が正しくありません。")
    for i, item in items
        if i = index
            item.Slot := slot
        else if slot && ItemSlot(item) = slot
            item.Slot := 0
}
