; Domain commands and persistence. No editing selection or window dependencies.
CreateLibrarySnapshot() {
    return {Profiles:CopyProfiles(Profiles), SharedDanmakuItems:CopyItems(SharedDanmakuItems)}
}

GetLibraryItems(library, profileId := "") {
    if profileId = ""
        return library.SharedDanmakuItems
    index := FindProfileIndexById(library.Profiles, profileId)
    if !index
        throw Error("対象の配信者が見つかりません。選び直してください。")
    return library.Profiles[index].Items
}

CommitLibraryChange(library, label) {
    global Profiles, SharedDanmakuItems, InputProfileIndex
    previousCritical := A_IsCritical
    Critical("On")
    try {
        activeId := GetInputProfile() ? GetInputProfile().Id : ""
        before := {Profiles:CopyProfiles(Profiles), Items:CopyItems(SharedDanmakuItems), Label:label}
        ; Only library data comes from the caller. Other preferences are always current.
        state := CreateSettingsSnapshot()
        state.Profiles := CopyProfiles(library.Profiles)
        state.SharedDanmakuItems := CopyItems(library.SharedDanmakuItems)
        state.InputProfileIndex := FindProfileIndexById(state.Profiles, activeId)
        WriteSettingsFile(state, SettingsFilePath)
        Profiles := state.Profiles, SharedDanmakuItems := state.SharedDanmakuItems
        InputProfileIndex := state.InputProfileIndex
        LibraryHistory.Push(before)
        if LibraryHistory.Length > 30
            LibraryHistory.RemoveAt(1)
        RebuildChannelIndex()
    } finally {
        Critical(previousCritical)
    }
}

UndoLibraryCommand() {
    global Profiles, SharedDanmakuItems, InputProfileIndex
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !LibraryHistory.Length
            return ""
        previous := LibraryHistory[-1]
        state := CreateSettingsSnapshot()
        state.Profiles := CopyProfiles(previous.Profiles), state.SharedDanmakuItems := CopyItems(previous.Items)
        activeId := GetInputProfile() ? GetInputProfile().Id : ""
        state.InputProfileIndex := FindProfileIndexById(state.Profiles, activeId)
        WriteSettingsFile(state, SettingsFilePath)
        Profiles := state.Profiles, SharedDanmakuItems := state.SharedDanmakuItems
        InputProfileIndex := state.InputProfileIndex
        LibraryHistory.Pop()
        RebuildChannelIndex()
        return previous.Label
    } finally {
        Critical(previousCritical)
    }
}

ExecuteDanmakuCommand(action, profileId, index := 0, value := 0, destinationId := "") {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        library := CreateLibrarySnapshot(), items := GetLibraryItems(library,profileId)
        if action != "add" && (!IsInteger(index) || index < 1 || index > items.Length)
            throw Error("対象の弾幕が見つかりません。選び直してください。")
        selected := index
        switch action {
            case "add", "edit":
                if !IsObject(value) || !Trim(value.Name) || !Trim(value.Text)
                    throw Error("弾幕名と本文を入力してください。")
                item := {Name:Trim(value.Name), Text:value.Text, Slot:0}
                if action = "add"
                    items.Push(item), selected := items.Length
                else
                    items[index] := item
                AssignItemSlot(items,selected,ItemSlot(value))
                label := "「" item.Name "」の" (action = "add" ? "追加" : "編集")
            case "delete":
                label := "「" items[index].Name "」の削除"
                items.RemoveAt(index)
            case "duplicate":
                item := items[index]
                items.InsertAt(index+1,{Name:item.Name "（コピー）",Text:item.Text,Slot:0})
                selected := index+1, label := "「" item.Name "」の複製"
            case "up", "down":
                selected := index + (action = "up" ? -1 : 1)
                if selected < 1 || selected > items.Length
                    return 0
                item := items[index], items[index] := items[selected], items[selected] := item
                label := "「" item.Name "」の並べ替え"
            case "move":
                if destinationId = profileId
                    throw Error("別の移動先を選んでください。")
                destination := GetLibraryItems(library,destinationId)
                item := items.RemoveAt(index), item.Slot := 0
                destination.Push(item)
                label := "「" item.Name "」の移動"
            default:
                throw Error("不明な弾幕操作です。")
        }
        CommitLibraryChange(library,label)
        return {Label:label, Index:selected, ProfileId:profileId}
    } finally {
        Critical(previousCritical)
    }
}

ExecuteProfileCommand(action, profileId := "", value := "", channel := "") {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        library := CreateLibrarySnapshot(), index := FindProfileIndexById(library.Profiles,profileId)
        if action != "add" && !index
            throw Error("対象の配信者が見つかりません。選び直してください。")
        switch action {
            case "add", "rename":
                if !Trim(value)
                    throw Error("配信者名を入力してください。")
                if action = "add" {
                    if channel != "" {
                        for profile in library.Profiles
                            if profile.Channel == channel
                                throw Error("既に「" profile.Name "」と連携しています。")
                    }
                    profileId := NewProfileId()
                    library.Profiles.Push({Id:profileId,Name:Trim(value),Channel:channel,Items:[]})
                } else
                    library.Profiles[index].Name := Trim(value)
                label := action = "add" ? "配信者の追加" : "配信者名の変更"
            case "delete":
                library.Profiles.RemoveAt(index), label := "配信者の削除"
            case "unbind":
                library.Profiles[index].Channel := "", label := "チャンネル連携の解除"
            case "bind":
                if value = ""
                    throw Error("連携するチャンネルがありません。")
                for i, profile in library.Profiles
                    if i != index && profile.Channel == value
                        throw Error("既に「" profile.Name "」に連携されています。")
                library.Profiles[index].Channel := value, label := "チャンネル連携の変更"
            default:
                throw Error("不明な配信者操作です。")
        }
        CommitLibraryChange(library,label)
        return {Label:label, ProfileId:profileId}
    } finally {
        Critical(previousCritical)
    }
}
