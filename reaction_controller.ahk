; Feature module. The worker adapter is in reaction_automation.ps1.
InitReactions() {
    InstallKeybdHook()
    global ReactionDefault, ReactionShortcut, ActiveReactionJob, ReactionChoice, ReactionScope
    global ReactionInfo, ReactionKeyControl, FeatureTabs, ReactionNames
    global ReactionCount, ReactionCountChoice
    global ReactionInterval, ReactionIntervalChoice
    ActiveReactionJob := 0
    global ReactionLastDetail := "", ReactionExecutionStatus := {Phase: "idle", Message: "", Final: false}
    global HasUnsavedReactionSettings := false, ReactionSettingsInfo := 0, ReactionLastResult := "まだ実行していません。"
    global HasUnsavedProfileReaction := false, HasUnsavedSharedReaction := false
    global ProfileReactionDraft := 0, SharedReactionDraft := 0
    global ReactionApplied := ""
    global ReactionOverlay := 0, ReactionOverlayText := 0
    global ReactionStatusFinal := false
    ReactionChoice := 0
    ReactionInfo := 0
    ReactionNames := ["❤️ ハート", "😁 笑顔", "🎉 お祝い", "😲 驚き", "💯 100点"]
    try SetReactionHotkey(ReactionShortcut)
    catch {
        ReactionShortcut := ReactionDefaults.Shortcut
        SetReactionHotkey(ReactionShortcut)
    }
    HotIf((*) => !!ActiveReactionJob)
    Hotkey("Esc", CancelReaction)
    HotIf()
    global ReactionsInitialized := true
}

ReactionHotkeyContext(*) {
    return IsBrowser(WinExist("A"))
}

ShortcutBlocked() {
    if ProfileManagerActive {
        ToolTip("投稿者・チャンネル管理を閉じてから実行してください。")
        SetTimer(() => ToolTip(), -2500)
        return true
    }
    if !IsBrowserOperationBusy && !DanmakuEditorWindow && !ActiveReactionJob
        return false
    message := ActiveReactionJob ? "リアクション処理中です。Escで停止してから押してください。"
        : (IsBrowserOperationBusy ? "前の処理を確認中です。完了後にもう一度押してください。" : "編集中です。編集画面を閉じてください。")
    ToolTip(message)
    SetTimer(() => ToolTip(), -2500)
    return true
}

WaitShortcutRelease(keys) {
    for key in keys {
        if !KeyWait(key, "T2") {
            ToolTip("キーを離してから、もう一度押してください。")
            SetTimer(() => ToolTip(), -2500)
            return false
        }
    }
    return true
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

IsReservedReactionKey(key) {
    plain := StrLower(RegExReplace(key, "[!^+]", ""))
    return InStr(key, "^") && InStr(key, "!") && !InStr(key, "+") && (plain = "1" || plain = "2" || plain = "3" || plain = "4" || plain = "q")
}

ResetReactionKey(*) {
    ReactionKeyControl.Value := ReactionDefaults.Shortcut
    CaptureSharedReactionEdits()
}
CaptureSharedReactionEdits(*) {
    global HasUnsavedReactionSettings := true, HasUnsavedSharedReaction := true
    UpdateSharedDraftFromControls()
    UpdateReactionSettingsInfo()
}

CaptureProfileReactionEdits(*) {
    if !ProfileReactionDraft
        return
    global HasUnsavedReactionSettings := true, HasUnsavedProfileReaction := true
    UpdateProfileDraftFromControls()
    UpdateReactionSettingsInfo()
}

SaveProfileReactionEdits(*) {
    global HasUnsavedProfileReaction, HasUnsavedReactionSettings
    if IsBrowserOperationBusy || ActiveReactionJob
        return
    if !ProfileReactionDraft || ProfileReactionDraft.Profile != Profiles[SelectedProfileIndex] {
        ProfileSettingsInfo.Text := "編集対象が変わりました。変更を戻してから編集し直してください。"
        return
    }
    try CommitProfileReactionDraft(ProfileReactionDraft, Profiles[SelectedProfileIndex])
    catch as failure {
        ProfileSettingsInfo.Text := "保存できませんでした。" failure.Message
        return
    }
    BeginProfileReactionDraft()
    RefreshReactionUI()
}

DiscardProfileReactionEdits(*) {
    BeginProfileReactionDraft()
    RefreshReactionUI()
}

ReactionKeyLabel() {
    return (InStr(ReactionShortcut, "^") ? "Ctrl＋" : "")
        . (InStr(ReactionShortcut, "!") ? "Alt＋" : "")
        . (InStr(ReactionShortcut, "+") ? "Shift＋" : "")
        . StrUpper(RegExReplace(ReactionShortcut, "[!^+]", ""))
}

DiscardSharedReactionEdits(*) {
    BeginSharedReactionDraft()
    ReactionDefaultChoice.Choose(ReactionDefault)
    ReactionKeyControl.Value := ReactionShortcut
    for i, value in ReactionCounts
        if value = ReactionCount
            ReactionCountChoice.Choose(i)
    for i, value in ReactionIntervals
        if value = ReactionInterval
            ReactionIntervalChoice.Choose(i)
    if !HasUnsavedProfileReaction
        RefreshReactionUI()
    UpdateReactionSettingsInfo()
}

QueueQuickReaction(*) {
    global ActiveReactionJob
    if ShortcutBlocked()
        return
    if HasUnsavedReactionSettings {
        SetReactionStatus("未保存の変更があります。Ctrl＋Alt＋Qで設定画面を開き、保存するか変更を戻してください。", true)
        ShowReactionProgress()
        return
    }
    ActiveReactionJob := {Mode: "queued", Cancelled: false, Window: WinExist("A")}
    SetReactionStatus("ショートカットを受け付けました。キーを離してください。", false, "queued")
    ShowReactionProgress()
    SetTimer(QuickReaction, -1)
}

SaveSharedReactionEdits(*) {
    global ReactionDefault, ReactionShortcut, ReactionCount, ReactionInterval, HasUnsavedReactionSettings, HasUnsavedSharedReaction
    if IsBrowserOperationBusy || ActiveReactionJob
        return
    try CommitSharedReactionDraft(SharedReactionDraft)
    catch as failure {
        CommonSettingsInfo.Text := "保存できませんでした。" failure.Message
        return
    }
    HasUnsavedSharedReaction := false
    HasUnsavedReactionSettings := HasUnsavedProfileReaction
    if !HasUnsavedProfileReaction
        RefreshReactionUI()
    UpdateReactionSettingsInfo()
    CommonSettingsInfo.Text := "共通のリアクション設定を保存しました。"
}

ScheduleReaction(mode, delay) {
    global ActiveReactionJob
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob
        return
    if mode = "reaction_send" && HasUnsavedReactionSettings {
        SetReactionStatus("設定を保存するか、変更を戻してから実行してください。", true)
        return
    }
    if !IsBrowser(TargetBrowserHwnd) {
        ReactionNotice("wrong_window")
        return
    }
    context := RequestBrowserOperation(TargetBrowserHwnd, "reaction_context")
    if context.State != "ok" {
        ReactionNotice(context.State)
        return
    }
    choice := mode = "reaction_send" ? ResolveReactionChoice(TargetBrowserHwnd, context.Video) : ReactionChoice.Value
    if !choice
        return
    ActiveReactionJob := {Mode: mode, Window: TargetBrowserHwnd, Video: context.Video,
        Choice: choice, Remaining: delay, Total: ReactionCount,
        Completed: 0, Cancelled: false, Interval: ReactionInterval}
    MainWindow.Hide()
    WinActivate("ahk_id " TargetBrowserHwnd)
    SetReactionStatus(mode = "reaction_capture" ? "登録待機中：YouTubeの♡にマウスを重ねてください。Escで中止。" : delay "秒後に開始します。♡のメニューを開いてください。")
    ShowReactionProgress()
    SetTimer(ReactionCountdown, 1000)
}

ReactionCountdown() {
    global ActiveReactionJob
    if !ActiveReactionJob {
        SetTimer(ReactionCountdown, 0)
        return
    }
    if !WinActive("ahk_id " ActiveReactionJob.Window) {
        CancelReaction()
        ReactionNotice("wrong_window")
        return
    }
    ActiveReactionJob.Remaining--
    if ActiveReactionJob.Remaining > 0 {
        ToolTip(ActiveReactionJob.Remaining "秒後に実行。♡のメニューを表示してください。Escで中止。")
        return
    }
    SetTimer(ReactionCountdown, 0)
    job := ActiveReactionJob
    if job.Mode = "reaction_send" {
        ReactionSendNext()
        return
    }
    try {
        point := Buffer(8, 0)
        DllCall("GetPhysicalCursorPos", "Ptr", point)
        extra := "Reaction=" job.Choice "`nX=" NumGet(point, 0, "Int") "`nY=" NumGet(point, 4, "Int") "`n"
        reply := RequestBrowserOperation(job.Window, job.Mode, job.Video, extra)
        if job.Cancelled {
            SetReactionStatus("登録・確認を中止しました。", true)
        } else if ShouldWaitForRegistration(job, reply) {
            global ReactionLastDetail := reply.HasOwnProp("Detail") ? reply.Detail : ""
            SetReactionStatus("登録待機中：♡のメニューを開き、マウスをその上に置いてください。Escで中止。")
            SetTimer(ReactionCountdown, -1000)
            return
        } else
            ReactionNotice(reply.State, reply.HasOwnProp("Detail") ? reply.Detail : "")
    } catch as captureError {
        ReactionNotice("unavailable", captureError.Message)
    } finally {
        if !IsSet(reply) || !ShouldWaitForRegistration(job, reply)
            ActiveReactionJob := 0
    }
}

ShouldWaitForRegistration(job, reply) {
    return !job.Cancelled && job.Mode = "reaction_capture" && (reply.State = "unsupported" || reply.State = "wrong_window")
}

CancelReaction(*) {
    global ActiveReactionJob
    SetTimer(ReactionCountdown, 0)
    SetTimer(ReactionSendNext, 0)
    SetTimer(QuickReaction, 0)
    if ActiveReactionJob {
        ActiveReactionJob.Cancelled := true
        if IsBrowserOperationBusy {
            SetReactionStatus("停止を受け付けました。現在の操作の結果を確認して終了します。")
            return
        }
        if ActiveReactionJob.HasOwnProp("Completed")
            SetReactionStatus("中止しました。操作済み " ActiveReactionJob.Completed " / " ActiveReactionJob.Total " 回。", true)
        else
            SetReactionStatus("中止しました。", true)
    }
    ActiveReactionJob := 0
    ToolTip()
}

IsReactionCount(value) {
    for count in ReactionCounts {
        if value = count
            return true
    }
    return false
}

ReactionSendNext() {
    global ActiveReactionJob
    if !ActiveReactionJob
        return
    job := ActiveReactionJob
    if job.Cancelled || !WinActive("ahk_id " job.Window) {
        CancelReaction()
        SetReactionStatus("操作先が変わったため停止しました。操作済み " job.Completed " / " job.Total " 回。", true)
        return
    }
    try {
        reply := RequestBrowserOperation(job.Window, "reaction_send", job.Video, "Reaction=" job.Choice "`n")
        ApplyReactionResult(job, reply)
    } catch as operationError {
        SetTimer(ReactionSendNext, 0)
        ActiveReactionJob := 0
        ReactionNotice("unknown", operationError.Message)
    }
}

ApplyReactionResult(job, reply) {
    global ActiveReactionJob
    if reply.State != "operated" {
        SetTimer(ReactionSendNext, 0)
        ActiveReactionJob := 0
        ReactionNotice(reply.State, reply.HasOwnProp("Detail") ? reply.Detail : "", " 操作済み " job.Completed " / " job.Total " 回で停止。")
        return
    }
    if !job.HasOwnProp("FirstOperationAt") {
        job.FirstOperationAt := A_TickCount
        job.Measurement := ""
    }
    job.Completed++
    if job.Completed > 1
        job.Measurement := "（平均操作間隔 " Round((A_TickCount - job.FirstOperationAt) / (job.Completed - 1)) " ms）"
    progress := ReactionApplied "`n操作済み " job.Completed " / " job.Total " 回" job.Measurement
    if job.Cancelled || job.Completed >= job.Total {
        ActiveReactionJob := 0
        SetReactionStatus(progress "。" (job.Cancelled ? "中止しました。" : "完了しました。") " YouTube側の受理回数は未確認です。", true)
        ToolTip(ReactionExecutionStatus.Message)
        SetTimer(() => ToolTip(), -4000)
        return
    }
    SetReactionStatus(progress "。実行中：Escで停止。")
    ToolTip(ReactionExecutionStatus.Message)
    ; One-shot scheduling: no queued requests and no catch-up burst.
    SetTimer(ReactionSendNext, -job.Interval)
}

QuickReaction(*) {
    global ActiveReactionJob
    if !ActiveReactionJob || ActiveReactionJob.Mode != "queued"
        return
    queuedJob := ActiveReactionJob
    hwnd := queuedJob.Window
    batchStarted := false
    try {
        key := RegExReplace(ReactionShortcut, "[!^+#<>]", "")
        if !WaitShortcutRelease([key, "Control", "Alt", "Shift"])
            return
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled || !WinActive("ahk_id " hwnd)
            return
        context := RequestBrowserOperation(hwnd, "reaction_context")
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        if context.State != "ok" || !WinActive("ahk_id " hwnd) {
            ReactionNotice("unavailable")
            return
        }
        choice := ResolveReactionChoice(hwnd, context.Video)
        if !choice || ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        ActiveReactionJob := {Mode: "reaction_send", Window: hwnd, Video: context.Video,
            Choice: choice, Total: ReactionCount, Completed: 0, Cancelled: false, Interval: ReactionInterval}
        batchStarted := true
        ReactionSendNext()
    } catch as operationError {
        if ActiveReactionJob = queuedJob
            ReactionNotice("unknown", operationError.Message)
    } finally {
        if !batchStarted && ActiveReactionJob = queuedJob {
            ActiveReactionJob := 0
            if ReactionExecutionStatus.Phase = "queued"
                SetReactionStatus("開始できませんでした。キーを離し、YouTubeを最前面にして再実行してください。", true)
        }
    }
}

ResolveReactionChoice(hwnd, video) {
    global ReactionApplied
    ReactionApplied := "適用：共通設定 / " ReactionNames[ReactionDefault]
    if !AutoMode && GetSelectedProfile() {
        choice := Profiles[SelectedProfileIndex].Reaction ? Profiles[SelectedProfileIndex].Reaction : ReactionDefault
        ReactionApplied := "適用：" Profiles[SelectedProfileIndex].Name " / " ReactionNames[choice]
        return choice
    }
    overrides := false
    for profile in Profiles
        overrides := overrides || profile.Reaction > 0
    if !overrides
        return ReactionDefault
    DetectedChannel := ResolveBrowserChannel(hwnd)
    if DetectedChannel.State != "ok" {
        ReactionNotice("unavailable")
        return 0
    }
    if !(DetectedChannel.Video == video) {
        ReactionNotice("changed")
        return 0
    }
    match := ChannelIndex.Get(DetectedChannel.Channel, 0)
    choice := match > 0 && Profiles[match].Reaction ? Profiles[match].Reaction : ReactionDefault
    ReactionApplied := "適用：" (match > 0 ? Profiles[match].Name : "共通設定") " / " ReactionNames[choice]
    return choice
}

; Execution status is owned here; controls are output only.
SetReactionStatus(message, final := false, phase := "") {
    global ReactionExecutionStatus, ReactionLastResult
    ReactionExecutionStatus := {Phase: phase != "" ? phase : (final ? "finished" : "running"), Message: message, Final: final}
    if final
        ReactionLastResult := message
    RenderReactionStatus(message, final)
}
