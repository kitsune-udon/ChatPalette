; Test data preparation only. Product commands own persistence and publication.
CopyTestItems(items) {
    result := []
    for item in items
        result.Push({Id:item.Id, Name:item.Name, Text:item.Text, Slot:item.Slot})
    return result
}

CopyTestProfiles(profiles) {
    result := []
    for profile in profiles
        result.Push({Name:profile.Name, Channel:profile.Channel, Id:profile.Id, Items:CopyTestItems(profile.Items)})
    return result
}

CreateTestLibrarySnapshot() {
    return {Profiles:CopyTestProfiles(Profiles), SharedDanmakuItems:CopyTestItems(SharedDanmakuItems)}
}

; A snapshot is always an independent editable copy.
CreateTestSettingsSnapshot() {
    state := CreatePreferences()
    state.Profiles := CopyTestProfiles(Profiles)
    state.SharedDanmakuItems := CopyTestItems(SharedDanmakuItems)
    return state
}
; External callers retain ownership of their mutable draft.
CommitTestLibraryChange(library, label) {
    return CommitLibraryDraft({Profiles:CopyTestProfiles(library.Profiles), SharedDanmakuItems:CopyTestItems(library.SharedDanmakuItems)},label)
}
