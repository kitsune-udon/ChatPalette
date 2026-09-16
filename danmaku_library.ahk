; Shared text presets are independent of channel detection.
GetDanmakuItems(common, profile) {
    return common ? SharedDanmakuItems : (profile ? profile.Items : [])
}

SetDanmakuItem(items, index, item) {
    if index
        items[index] := item
    else
        items.Push(item)
}

DuplicateDanmakuItem(items, index) {
    item := items[index]
    items.InsertAt(index + 1, {Name: item.Name "（コピー）", Text: item.Text})
}

ReorderDanmakuItem(items, index, other) {
    if index < 1 || other < 1 || index > items.Length || other > items.Length
        return false
    temp := items[index]
    items[index] := items[other]
    items[other] := temp
    return true
}

CreateLibraryUndoSnapshot(targets, scope) {
    changes := []
    for items in targets {
        before := []
        for item in items
            before.Push({Name: item.Name, Text: item.Text})
        changes.Push({Target: items, Before: before})
    }
    return {Changes: changes, Scope: scope}
}

RestoreLibraryUndoSnapshot(snapshot) {
    for change in snapshot.Changes {
        change.Target.Length := 0
        for item in change.Before
            change.Target.Push({Name: item.Name, Text: item.Text})
    }
}
