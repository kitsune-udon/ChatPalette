; Key callbacks only capture commands. One drainer owns execution and session cleanup.
InitShortcutQueue() {
    global ShortcutCommands := [], ShortcutSession := 0, ActiveShortcutCommand := 0, ShortcutDraining := false
}

; Rejection is shared; busy work is admitted now and deferred only by the drainer.
ShortcutQueueRejected(action, state, transferActive) {
    return transferActive || state.Refreshing || (action != "palette" && state.EditorLabel != "")
}

EnqueueConfiguredShortcut(action, hwnd := 0) {
    global ShortcutSession
    hwnd := hwnd ? hwnd : WinExist("A")
    if !IsTargetForeground(hwnd) || (action != "palette" && !IsBrowser(hwnd))
        return false
    state := CurrentOperationState()
    if ShortcutQueueRejected(action,state,SettingsTransferActive) {
        ShortcutBlocked(action = "reaction" ? "reaction" : "input")
        return false
    }
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if ShortcutSession && ShortcutSession.Window != hwnd
            CancelShortcutQueue(ShortcutSession)
        if !ShortcutSession {
            video := ""
            if ActiveReactionJob && ActiveReactionJob.Window = hwnd && ActiveReactionJob.HasOwnProp("Video")
                video := ActiveReactionJob.Video
            else if ActivePageAction && ActivePageAction.Window = hwnd && ActivePageAction.HasOwnProp("Video")
                video := ActivePageAction.Video
            ShortcutSession := {Window:hwnd,Video:video,Focus:0,Cancelled:false}
        }
        command := {Action:action,Window:hwnd,Session:ShortcutSession,Result:0}
        if SubStr(action,1,7) = "profile" || SubStr(action,1,6) = "shared" {
            command.Scope := SubStr(action,1,-1), command.Slot := Integer(SubStr(action,-1))
            command.Library := {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}
            command.Auto := AutoMode, command.ProfileId := InputProfileId
        }
        ShortcutCommands.Push(command)
        SetTimer(DrainShortcutQueue,-1)
        return true
    } finally Critical(previousCritical)
}

CancelShortcutQueue(owner := 0) {
    global ShortcutCommands, ShortcutSession
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if owner && ShortcutSession != owner
            return
        if ShortcutSession
            ShortcutSession.Cancelled := true
        ShortcutCommands := [], ShortcutSession := 0
        SetTimer(DrainShortcutQueue,0)
    } finally Critical(previousCritical)
}

ShortcutRequestCurrent(command) {
    if ActiveShortcutCommand != command || ShortcutSession != command.Session || command.Session.Cancelled
        return false
    if !IsTargetForeground(command.Window)
        return false
    if command.HasOwnProp("Scope") && command.Scope = "profile"
        return AutoMode = command.Auto && (command.Auto || InputProfileId == command.ProfileId)
    return true
}

DrainShortcutQueue() {
    global ShortcutDraining, ActiveShortcutCommand, ShortcutSession
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if ShortcutDraining || !ShortcutCommands.Length
            return
        ShortcutDraining := true
    } finally Critical(previousCritical)
    try {
        while ShortcutCommands.Length {
            previousCritical := A_IsCritical
            Critical("On")
            try {
                ; Stop may clear the queue between iterations; admission and dequeue are one decision.
                if !ShortcutCommands.Length
                    break
                state := CurrentOperationState()
                if ShortcutQueueRejected(ShortcutCommands[1].Action,state,SettingsTransferActive) {
                    CancelShortcutQueue(ShortcutCommands[1].Session)
                    return
                }
                if state.BrowserBusy || state.ReactionActive {
                    SetTimer(DrainShortcutQueue,-20)
                    return
                }
                command := ShortcutCommands.RemoveAt(1)
                ActiveShortcutCommand := command
            } finally Critical(previousCritical)
            succeeded := false
            try {
                succeeded := ExecuteQueuedShortcut(command)
            } catch as failure {
                if ShortcutRequestCurrent(command) {
                    PaletteHint.Text := failure.Message
                    ShowStatusTip(failure.Message,2500)
                }
            } finally {
                if ActiveShortcutCommand = command
                    ActiveShortcutCommand := 0
                if !succeeded
                    CancelShortcutQueue(command.Session)
            }
        }
    } finally {
        previousCritical := A_IsCritical
        Critical("On")
        try {
            ShortcutDraining := false
            if ShortcutCommands.Length
                SetTimer(DrainShortcutQueue,-20)
            else if !ActiveShortcutCommand
                ShortcutSession := 0
        } finally Critical(previousCritical)
    }
}

ExecuteQueuedShortcut(command) {
    if !ShortcutRequestCurrent(command)
        return false
    if command.Action = "palette" {
        ShowPalette()
        return true
    }
    if !IsBrowser(command.Window)
        return false
    context := RequestBrowserOperation(command.Window,"browser_context",command.Session.Video)
    if !ShortcutRequestCurrent(command)
        return false
    if context.State != "ok" || context.Video = "" || (command.Session.Video != "" && !(context.Video == command.Session.Video)) {
        ShowInputFailure(context.State = "ok" ? "changed" : context.State)
        return false
    }
    command.Session.Video := context.Video
    if command.Action = "reaction"
        return QueueQuickReaction(command)
    if command.HasOwnProp("Scope") {
        result := RequestShortcutInput(command.Scope,command.Slot,command.Window,command)
        return result.State = "inserted"
    }
    ; Clear consumes its own focus proof; no earlier proof may survive it.
    if command.Action = "chat_clear" || command.Action = "chat_focus"
        command.Session.Focus := 0
    succeeded := RunPageAction(command.Action,command.Window,command)
    if succeeded && command.Action = "chat_focus" && ShortcutRequestCurrent(command) {
        if !command.Result.HasOwnProp("Detail") || command.Result.Detail = ""
            return false
        command.Session.Focus := command.Result
    }
    return succeeded
}
