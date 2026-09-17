; Profile identity and active input selection. Editing has a separate selection.
GetInputProfile() {
    return InputProfileIndex >= 1 && InputProfileIndex <= Profiles.Length ? Profiles[InputProfileIndex] : 0
}
FindProfileIndexById(profiles, id) {
    for i, profile in profiles
        if profile.Id = id
            return i
    return 0
}
SaveInputProfileSelection(index) {
    global InputProfileIndex
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if index < 1 || index > Profiles.Length || index = InputProfileIndex
            return
        state := CreateSettingsSnapshot(false)
        state.InputProfileIndex := index
        SaveSettingsPreferences(state, SettingsDatabasePath)
        InputProfileIndex := index
    } finally {
        Critical(previousCritical)
    }
}

RebuildChannelIndex() {
    global ChannelIndex
    ChannelIndex := Map()
    ChannelIndex.CaseSense := "On"
    for i, p in Profiles {
        if p.Channel != ""
            ChannelIndex[p.Channel] := ChannelIndex.Has(p.Channel) ? -1 : i
    }
}
