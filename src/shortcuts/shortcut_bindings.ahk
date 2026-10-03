; One registration path; contexts and callbacks are identified by action, not key text.
ReactionHotkeyContext(*) {
    return IsBrowser(WinExist("A"))
}
StopHotkeyContext(*) {
    return !!ActiveReactionJob || !!ActiveShortcutCommand || !!ShortcutCommands.Length
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
        ; Commands run once on release; cancellation remains immediate on press.
        key .= action = "stop" ? "" : " Up"
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
            failure.Message .= "`n一部のキー割当を元に戻せませんでした。ChatPaletteを再起動してください。" recoveryFailures
        throw failure
    }
}
HandleConfiguredShortcut(action,*) {
    if action = "stop"
        return CancelReaction()
    return EnqueueConfiguredShortcut(action)
}
SaveShortcutMap(keys) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        state := CreatePreferences(), state.ShortcutKeys := keys.Clone()
        ApplyPreferences(state)
    } finally Critical(previousCritical)
}
