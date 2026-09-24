; Profile identity and active input selection. Editing has a separate selection.
GetInputProfile() {
    return FindProfileById(Profiles,InputProfileId)
}
FindProfileIndexById(profiles, id) {
    if id = ""
        return 0
    for i, profile in profiles
        if profile.Id == id
            return i
    return 0
}
FindProfileById(profiles, id) {
    index := FindProfileIndexById(profiles,id)
    return index ? profiles[index] : 0
}
; Only GUI adapters translate list positions into IDs.
SaveInputProfileSelection(index) {
    if index >= 1 && index <= Profiles.Length
        SaveInputProfileId(Profiles[index].Id)
}
SaveInputProfileId(id) {
    global InputProfileId
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if id == InputProfileId || (id != "" && !FindProfileById(Profiles,id))
            return
        state := CreatePreferences()
        state.InputProfileId := id
        SaveSettingsPreferences(state,SettingsDatabasePath)
        InputProfileId := id
    } finally {
        Critical(previousCritical)
    }
}

RebuildChannelIndex() {
    global ChannelIndex
    ChannelIndex := Map()
    ChannelIndex.CaseSense := "On"
    for p in Profiles {
        if p.Channel != ""
            ChannelIndex[p.Channel] := ChannelIndex.Has(p.Channel) ? "" : p.Id
    }
}
