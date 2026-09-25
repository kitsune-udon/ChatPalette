; Domain commands and persistence. No editing selection or window dependencies.
GetLibraryItems(library, profileId := "") {
    if profileId = ""
        return library.SharedDanmakuItems
    index := FindProfileIndexById(library.Profiles, profileId)
    if !index
        throw Error("対象の配信者が見つかりません。選び直してください。")
    return library.Profiles[index].Items
}

; Persist first, then publish from one place for commands, undo, and reload.
PublishLibraryState(state) {
    global Profiles := state.Profiles, SharedDanmakuItems := state.SharedDanmakuItems
    global InputProfileId := state.InputProfileId
}
SaveLibraryDraft(library) {
    state := {Profiles:library.Profiles, SharedDanmakuItems:library.SharedDanmakuItems, InputProfileId:InputProfileId}
    if !FindProfileById(state.Profiles,state.InputProfileId)
        state.InputProfileId := ""
    SaveLibrarySettings(library,state.InputProfileId,SettingsDatabasePath)
    PublishLibraryState(state)
}
; Internal command drafts transfer ownership after successful persistence.
CommitLibraryDraft(library, label) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        before := {Profiles:Profiles, SharedDanmakuItems:SharedDanmakuItems, Label:label}
        SaveLibraryDraft(library)
        LibraryHistory.Push(before)
        if LibraryHistory.Length > 30
            LibraryHistory.RemoveAt(1)
    } finally {
        Critical(previousCritical)
    }
}
UndoLibraryCommand() {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !LibraryHistory.Length
            return ""
        previous := LibraryHistory[-1]
        SaveLibraryDraft(previous)
        LibraryHistory.Pop()
        return previous.Label
    } finally {
        Critical(previousCritical)
    }
}

ExecuteDanmakuCommand(action, profileId, itemId := "", value := 0, destinationId := "") {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        library := CreateLibraryDraft(), items := EditLibraryItems(library,profileId)
        index := 0
        if action != "add" {
            for i, item in items {
                if item.Id == itemId {
                    index := i
                    break
                }
            }
            if !index
                throw Error("対象の弾幕が見つかりません。選び直してください。")
        }
        selected := index
        switch action {
            case "add", "edit":
                if !IsObject(value) || !Trim(value.Name) || !Trim(value.Text)
                    throw Error("弾幕名と本文を入力してください。")
                requestedSlot := value.HasOwnProp("Slot") ? value.Slot : 0
                original := action = "edit" ? items[index] : 0
                item := {Id:action = "add" ? NewRecordId() : items[index].Id, Name:Trim(value.Name), Text:value.Text, Slot:0}
                if action = "add"
                    items.Push(item), selected := items.Length
                else
                    items[index] := item
                AssignItemSlot(items,selected,requestedSlot)
                label := "「" item.Name "」の" (action = "add" ? "追加" : "編集")
                if original && item.Name == original.Name && item.Text == original.Text && requestedSlot = original.Slot
                    return {Label:label, Index:selected, ProfileId:profileId}
            case "delete":
                label := "「" items[index].Name "」の削除"
                items.RemoveAt(index)
            case "duplicate":
                item := items[index]
                items.InsertAt(index+1,{Id:NewRecordId(),Name:item.Name "（コピー）",Text:item.Text,Slot:0})
                selected := index+1, label := "「" item.Name "」の複製"
            case "up", "down":
                selected := index + (action = "up" ? -1 : 1)
                if selected < 1 || selected > items.Length
                    return 0
                item := items[index], items[index] := items[selected], items[selected] := item
                label := "「" item.Name "」の並べ替え"
            case "move":
                if destinationId == profileId
                    throw Error("別の移動先を選んでください。")
                destination := EditLibraryItems(library,destinationId)
                item := items.RemoveAt(index).Clone(), item.Slot := 0
                destination.Push(item)
                label := "「" item.Name "」の移動"
            default:
                throw Error("不明な弾幕操作です。")
        }
        CommitLibraryDraft(library,label)
        return {Label:label, Index:selected, ProfileId:profileId}
    } finally {
        Critical(previousCritical)
    }
}

ExecuteProfileCommand(action, profileId := "", value := "", channel := "") {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        library := CreateLibraryDraft(), index := FindProfileIndexById(library.Profiles,profileId)
        if action != "add" && !index
            throw Error("対象の配信者が見つかりません。選び直してください。")
        if (action = "add" || action = "rename") && !Trim(value)
            throw Error("配信者名を入力してください。")
        if action = "bind" && value = ""
            throw Error("連携するチャンネルがありません。")
        binding := action = "add" ? channel : (action = "bind" ? value : "")
        if binding != "" {
            for i, profile in library.Profiles
                if (action = "add" || i != index) && profile.Channel == binding
                    throw Error("既に「" profile.Name "」と連携しています。")
        }
        if action != "add" && action != "delete"
            library.Profiles[index] := library.Profiles[index].Clone()
        switch action {
            case "add", "rename":
                if action = "add" {
                    profileId := NewRecordId()
                    library.Profiles.Push({Id:profileId,Name:Trim(value),Channel:channel,Items:[]})
                } else
                    library.Profiles[index].Name := Trim(value)
                label := action = "add" ? "配信者の追加" : "配信者名の変更"
            case "delete":
                library.Profiles.RemoveAt(index), label := "配信者の削除"
            case "unbind":
                library.Profiles[index].Channel := "", label := "チャンネル連携の解除"
            case "bind":
                library.Profiles[index].Channel := value, label := "チャンネル連携の変更"
            default:
                throw Error("不明な配信者操作です。")
        }
        ; Metadata-only no-ops must not consume the bounded undo history.
        if action = "add" || action = "delete"
            || !(library.Profiles[index].Name == Profiles[index].Name)
            || !(library.Profiles[index].Channel == Profiles[index].Channel)
            CommitLibraryDraft(library,label)
        return {Label:label, ProfileId:profileId}
    } finally {
        Critical(previousCritical)
    }
}

; Share immutable profiles and item arrays; clone the owner when a command edits it.
CreateLibraryDraft() {
    return {Profiles:Profiles.Clone(), SharedDanmakuItems:SharedDanmakuItems}
}

EditLibraryItems(library, profileId) {
    if profileId = "" {
        library.SharedDanmakuItems := library.SharedDanmakuItems.Clone()
        return library.SharedDanmakuItems
    }
    index := FindProfileIndexById(library.Profiles,profileId)
    if !index
        throw Error("対象の配信者が見つかりません。選び直してください。")
    profile := library.Profiles[index].Clone()
    profile.Items := profile.Items.Clone()
    library.Profiles[index] := profile
    return profile.Items
}

SaveShortcutItemAssignments(profileId,firstId,secondId) {
    if firstId != "" && firstId == secondId
        throw Error("同じ弾幕を2つのキーへ割り当てることはできません。")
    previousCritical := A_IsCritical
    Critical("On")
    try {
        library := CreateLibraryDraft(), items := EditLibraryItems(library,profileId)
        unmatched := (firstId != "") + (secondId != ""), changed := false
        for i,item in items {
            slot := item.Id == firstId ? 1 : (item.Id == secondId ? 2 : 0)
            if slot
                unmatched--
            if item.Slot != slot {
                replacement := item.Clone(), replacement.Slot := slot
                items[i] := replacement, changed := true
            }
        }
        if unmatched
            throw Error("対象の弾幕が変更されました。画面を開き直してください。")
        if changed
            CommitLibraryDraft(library,"ショートカットの弾幕割当")
    } finally Critical(previousCritical)
}
