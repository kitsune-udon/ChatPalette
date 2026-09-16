; Runtime hotkey adapter. Validation is in shortcut_policy.
ReactionHotkeyContext(*) {
    return IsBrowser(WinExist("A"))
}

SetReactionHotkey(key, enabled := true) {
    if enabled && IsReservedReactionKey(key)
        throw Error("パネル・弾幕用のキーは指定できません。")
    HotIf(ReactionHotkeyContext)
    try {
        if enabled
            Hotkey(key, QueueQuickReaction, "T1 On")
        else
            Hotkey(key, "Off")
    } finally {
        HotIf()
    }
}
