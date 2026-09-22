; One registration path; contexts and callbacks are identified by action, not key text.
ReactionHotkeyContext(*) {
    return IsBrowser(WinExist("A"))
}
StopHotkeyContext(*) {
    return !!ActiveReactionJob
}
GetShortcutKey(action) {
    return action = "reaction" ? ReactionShortcut : ShortcutKeys[action]
}
CurrentShortcutMap() {
    keys := ShortcutKeys.Clone(), keys["reaction"] := ReactionShortcut
    return keys
}
SetReactionHotkey(key, enabled := true) {
    return RuntimePorts.ReactionKey ? RuntimePorts.ReactionKey.Call(key,enabled) : NativeSetReactionHotkey(key,enabled)
}
NativeSetReactionHotkey(key, enabled := true) {
    NativeSetShortcutHotkey("reaction",key,enabled)
}
SetShortcutHotkey(action,key,enabled := true) {
    if key = ""
        return
    if action = "reaction"
        return SetReactionHotkey(key,enabled)
    if !ApplicationShortcutsInstalled && action != "stop"
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
        return HandleDanmakuShortcut(SubStr(action,1,6) = "shared",Integer(SubStr(action,-1)))
    return HandlePageShortcut(action,RegExReplace(GetShortcutKey(action),"[!^+]",""))
}
SaveShortcutMap(keys) {
    ValidateShortcutMap(keys)
    state := CreatePreferences(), state.ReactionShortcut := keys["reaction"], state.ShortcutKeys := keys.Clone()
    state.ShortcutKeys.Delete("reaction")
    ApplyReactionDefaults(state)
}
