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
SaveInputProfileId(id) {
    global InputProfileId
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if id == InputProfileId
            return
        state := CreatePreferences()
        state.InputProfileId := id
        SaveSettingsPreferences(state,SettingsDatabasePath)
        InputProfileId := id
    } finally {
        Critical(previousCritical)
    }
}

FindProfileByChannel(profiles, channel) {
    if channel = ""
        return 0
    for profile in profiles
        if profile.Channel == channel
            return profile
    return 0
}
