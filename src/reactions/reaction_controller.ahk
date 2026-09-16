; Feature module. The worker adapter is in reaction_automation.ps1.
InitReactions() {
    InstallKeybdHook()
    global DefaultReactionKind, ReactionShortcut, ActiveReactionJob
    global DefaultReactionCount
    global DefaultReactionIntervalMs
    ActiveReactionJob := 0
    global ReactionExecutionStatus := {Phase: "idle", Message: "", Final: false}
    global LastReactionResult := {Message:"まだ実行していません。",Detail:"",Completed:0,Total:0,Mode:"",Reason:"idle"}
    global ReactionApplied := ""
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

QueueQuickReaction(*) {
    global ActiveReactionJob
    if ShortcutBlocked()
        return
    ActiveReactionJob := {Mode: "queued", Cancelled: false, Window: WinExist("A")}
    SetReactionStatus("ショートカットを受け付けました。キーを離してください。", false, "queued")
    ShowReactionProgress()
    SetTimer(QuickReaction, -1)
}

ScheduleReaction(mode, delay, options := 0) {
    global ActiveReactionJob
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob
        return false
    if !IsBrowser(TargetBrowserHwnd) {
        ReactionNotice("wrong_window")
        return false
    }
    context := RequestBrowserOperation(TargetBrowserHwnd, "browser_context")
    if context.State != "ok" {
        ReactionNotice(context.State)
        return false
    }
    choice := options ? options.Reaction : DefaultReactionKind
    global ReactionApplied := "適用：" (options ? "今回の設定" : "共通設定") " / " ReactionNames[choice]
    if !choice
        return false
    ActiveReactionJob := {Mode: mode, Window: TargetBrowserHwnd, Video: context.Video,
        Choice: choice, Remaining: delay, Total: options ? options.Count : DefaultReactionCount,
        Completed: 0, Cancelled: false, Interval: options ? options.Interval : DefaultReactionIntervalMs}
    PaletteWindow.Hide()
    WinActivate("ahk_id " TargetBrowserHwnd)
    SetReactionStatus(mode = "reaction_capture" ? "登録待機中：YouTubeの♡にマウスを重ねてください。Escで中止。" : delay "秒後に開始します。♡のメニューを開いてください。")
    ShowReactionProgress()
    SetTimer(ReactionCountdown, 1000)
    return true
}

ReactionCountdown() {
    global ActiveReactionJob
    if !ActiveReactionJob {
        SetTimer(ReactionCountdown, 0)
        return
    }
    if !WinActive("ahk_id " ActiveReactionJob.Window) {
        stoppedJob := ActiveReactionJob
        CancelReaction()
        ReactionNotice("wrong_window","","",stoppedJob)
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
            job.Detail := reply.HasOwnProp("Detail") ? reply.Detail : ""
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
            SetReactionStatus("中止しました。操作済み " ActiveReactionJob.Completed " / " ActiveReactionJob.Total " 回。", true,"","",ActiveReactionJob,"cancelled")
        else
            SetReactionStatus("中止しました。", true,"","",ActiveReactionJob,"cancelled")
    }
    ActiveReactionJob := 0
    ToolTip()
}

ReactionSendNext() {
    global ActiveReactionJob
    if !ActiveReactionJob
        return
    job := ActiveReactionJob
    if job.Cancelled || !WinActive("ahk_id " job.Window) {
        CancelReaction()
        SetReactionStatus("操作先が変わったため停止しました。操作済み " job.Completed " / " job.Total " 回。", true,"","",job,"wrong_window")
        return
    }
    precisionEnabled := false
    releasePrecision := (*) => SetReactionTimingPrecision(false)
    try {
        if job.Interval > 0 {
            precisionEnabled := SetReactionTimingPrecision(true)
            if precisionEnabled
                OnExit(releasePrecision)
        }
        while ActiveReactionJob = job && !job.Cancelled {
            if !WaitReactionInterval(job)
                return
            if !WinActive("ahk_id " job.Window) {
                CancelReaction()
                ReactionNotice("wrong_window","","",job)
                return
            }
            job.StartedAt := ReactionClockMs()
            reply := RequestBrowserOperation(job.Window, "reaction_send", job.Video, "Reaction=" ResolveReactionKind(job.Choice) "`n")
            if ActiveReactionJob != job
                return
            ApplyReactionResult(job, reply)
        }
    } catch as operationError {
        SetTimer(ReactionSendNext, 0)
        ActiveReactionJob := 0
        ReactionNotice("unknown", operationError.Message,"",job)
    } finally {
        if precisionEnabled {
            OnExit(releasePrecision, 0)
            SetReactionTimingPrecision(false)
        }
    }
}

; Only interval-controlled runs request higher precision. Always balance successful requests.
SetReactionTimingPrecision(enabled) {
    if enabled
        return DllCall("Winmm\timeBeginPeriod", "UInt", 1, "UInt") = 0
    DllCall("Winmm\timeEndPeriod", "UInt", 1, "UInt")
    return 0 ; OnExit callbacks must never prevent shutdown.
}

; Resolve once per operation. The worker continues to accept only concrete kinds 1..5.
ResolveReactionKind(choice) {
    return choice = RandomReactionKind ? Random(1, 5) : choice
}

ReactionClockMs() {
    static frequency := 0
    if !frequency
        DllCall("QueryPerformanceFrequency", "Int64*", &frequency)
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    return counter * 1000 / frequency
}

ReactionWaitRemaining(job, now) {
    return job.Interval = 0 || !job.HasOwnProp("StartedAt") ? 0 : Max(0, job.StartedAt + job.Interval - now)
}

WaitReactionInterval(job) {
    ; Always pump cancellation, including 待機なし. Never queue concurrent requests.
    Sleep(-1)
    while ActiveReactionJob = job && !job.Cancelled {
        remaining := ReactionWaitRemaining(job, ReactionClockMs())
        if remaining <= 0
            return true
        ; Wake for Windows messages as well as the deadline; keep cancellation responsive.
        DllCall("MsgWaitForMultipleObjectsEx", "UInt", 0, "Ptr", 0,
            "UInt", Min(10, Ceil(remaining)), "UInt", 0x4FF, "UInt", 0x4)
        Sleep(-1)
    }
    return false
}

ApplyReactionResult(job, reply) {
    global ActiveReactionJob
    if reply.State != "operated" {
        SetTimer(ReactionSendNext, 0)
        ActiveReactionJob := 0
        ReactionNotice(reply.State, reply.HasOwnProp("Detail") ? reply.Detail : "", " 操作済み " job.Completed " / " job.Total " 回で停止。",job)
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
        SetReactionStatus(progress "。" (job.Cancelled ? "中止しました。" : "完了しました。") " YouTube側の受理回数は未確認です。", true,"","",job,job.Cancelled ? "cancelled" : "completed")
        return
    }
    SetReactionStatus(progress "。実行中：Escで停止。")
    ; The serial loop schedules against this operation's start, not its completion.
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
        context := RequestBrowserOperation(hwnd, "browser_context")
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        if context.State != "ok" || !WinActive("ahk_id " hwnd) {
            ReactionNotice("unavailable")
            return
        }
        choice := DefaultReactionKind
        global ReactionApplied := "適用：共通設定 / " ReactionNames[choice]
        if !choice || ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        ActiveReactionJob := {Mode: "reaction_send", Window: hwnd, Video: context.Video,
            Choice: choice, Total: DefaultReactionCount, Completed: 0, Cancelled: false, Interval: DefaultReactionIntervalMs}
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

SetReactionStatus(message, final := false, phase := "", detail := "", job := 0, reason := "") {
    global ReactionExecutionStatus, LastReactionResult
    ReactionExecutionStatus := {Phase: phase != "" ? phase : (final ? "finished" : "running"), Message: message, Final: final}
    if final {
        if !job && ActiveReactionJob
            job := ActiveReactionJob
        LastReactionResult := {Message:message, Detail:detail,
            Completed:job && job.HasOwnProp("Completed") ? job.Completed : 0,
            Total:job && job.HasOwnProp("Total") ? job.Total : 0,
            Mode:job && job.HasOwnProp("Mode") ? job.Mode : "", Reason:reason != "" ? reason : "finished", FinishedAt:FormatTime(,"yyyy/MM/dd HH:mm:ss")}
    }
    RenderReactionStatus()
}
