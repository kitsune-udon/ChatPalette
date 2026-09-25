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
    global ApplicationShortcutsInstalled
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if ApplicationShortcutsInstalled
            return
        ValidateShortcutMap(ShortcutKeys)
        CommitShortcutBindings(Map(),CurrentShortcutMap())
        ApplicationShortcutsInstalled := true
    } finally Critical(previousCritical)
}
; Both callers hold Critical through binding changes and publication. A failed
; registration or persistence callback rolls back the same owned bindings.
CommitShortcutBindings(previous,next,commit := 0) {
    disabled := [], installed := []
    try {
        ; Remove changed bindings first so swapping two keys is safe.
        for action in ChangedShortcutBindings(previous,next) {
            SetShortcutHotkey(action,previous.Get(action,""),false)
            disabled.Push(action)
        }
        for action in disabled {
            SetShortcutHotkey(action,next[action])
            installed.Push(action)
        }
        if commit
            commit.Call()
    } catch as failure {
        recoveryFailures := ""
        for action in installed {
            try SetShortcutHotkey(action,next[action],false)
            catch as recoveryFailure
                recoveryFailures .= "`n新しい割当の解除（" ShortcutKeyLabel(next[action]) "）: " recoveryFailure.Message
        }
        for action in disabled {
            try SetShortcutHotkey(action,previous.Get(action, ""))
            catch as recoveryFailure
                recoveryFailures .= "`n以前の割当の復元（" ShortcutKeyLabel(previous.Get(action, "")) "）: " recoveryFailure.Message
        }
        if recoveryFailures != ""
            throw Error(failure.Message "`n一部のキー割当を元に戻せませんでした。ChatPaletteを再起動してください。" recoveryFailures)
        throw failure
    }
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
    return HandlePageShortcut(action)
}
SaveShortcutMap(keys) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        state := CreatePreferences(), state.ShortcutKeys := keys.Clone()
        ApplyPreferences(state)
    } finally Critical(previousCritical)
}
