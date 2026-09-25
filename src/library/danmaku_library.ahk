AssignItemSlot(items, index, slot) {
    if !IsInteger(index) || !IsInteger(slot) || index < 1 || index > items.Length || slot < 0 || slot > 2
        throw Error("キーの割当が正しくありません。")
    ; Clearing a slot cannot conflict with another item; avoid scanning the list.
    if !slot {
        if items[index].Slot {
            replacement := items[index].Clone(), replacement.Slot := 0
            items[index] := replacement
        }
        return
    }
    for i, item in items {
        nextSlot := i = index ? slot : (item.Slot = slot ? 0 : item.Slot)
        if item.Slot != nextSlot {
            replacement := item.Clone()
            replacement.Slot := nextSlot
            items[i] := replacement
        }
    }
}
