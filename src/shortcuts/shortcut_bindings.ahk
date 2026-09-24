; One registration path; contexts and callbacks are identified by action, not key text.
ReactionHotkeyContext(*) {
    return IsBrowser(WinExist("A"))
}
StopHotkeyContext(*) {
    return !!ActiveReactionJob
}
GetShortcutKey(action) {
    return ShortcutKeys[action]
}
CurrentShortcutMap() {
    return ShortcutKeys.Clone()
}

SetShortcutHotkey(action,key,enabled := true) {
    if key = ""
        return
    if !ApplicationShortcutsInstalled
        return
    return RuntimePorts.ShortcutKey ? RuntimePorts.ShortcutKey.Call(action,key,enabled) : NativeSetShortcutHotkey(action,key,enabled)
}
NativeSetShortcutHotkey(action,key,enabled := true) {
    if action = "palette"
        HotIf()
    else
        HotIf(action = "stop" ? StopHotkeyContext : ReactionHotkeyContext)
    try {
        if enabled
            Hotkey(key,HandleConfiguredShortcut.Bind(action),"T1 On")
        else
            Hotkey(key,"Off")
    } finally HotIf()
}
InstallApplicationShortcuts() {
    global ApplicationShortcutsInstalled := true
    for definition in ShortcutDefinitions()
        SetShortcutHotkey(definition.Id,GetShortcutKey(definition.Id))
}
HandleConfiguredShortcut(action,*) {
    if action = "palette"
        return ShowPalette()
    if action = "stop"
        return CancelReaction()
    if action = "reaction"
        return QueueQuickReaction()
    if SubStr(action,1,7) = "profile" || SubStr(action,1,6) = "shared"
        return HandleDanmakuShortcut(SubStr(action,1,-1),Integer(SubStr(action,-1)))
    return HandlePageShortcut(action,RegExReplace(GetShortcutKey(action),"[!^+]",""))
}
SaveShortcutMap(keys) {
    state := CreatePreferences(), state.ShortcutKeys := keys.Clone()
    ApplyPreferences(state)
}
