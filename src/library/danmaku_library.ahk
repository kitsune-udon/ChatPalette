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
    ; Clearing a slot cannot conflict with another item; avoid scanning the list.
    if !slot {
        if ItemSlot(items[index]) {
            replacement := items[index].Clone(), replacement.Slot := 0
            items[index] := replacement
        }
        return
    }
    for i, item in items {
        nextSlot := i = index ? slot : (slot && ItemSlot(item) = slot ? 0 : ItemSlot(item))
        if ItemSlot(item) != nextSlot {
            replacement := item.Clone()
            replacement.Slot := nextSlot
            items[i] := replacement
        }
    }
}
