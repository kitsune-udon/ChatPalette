; Feature module. The worker adapter is in reaction_automation.ps1.
InitReactions() {
    InstallKeybdHook()
    global ActiveReactionJob := 0
    global ReactionExecutionStatus := {Phase: "idle", Message: "", Final: false}
    global LastReactionResult := {Message:"まだ実行していません。",Detail:"",Completed:0,Total:0,Mode:"",Reason:"idle"}
}

CreateReactionJob(values) {
    job := {Mode:"reaction_send", Phase:"waiting", Window:0, Video:"", Choice:1,
        Remaining:0, Total:0, Completed:0, Cancelled:false, Interval:0,
        StartedAt:-1, FirstStartedAt:-1, Measurement:"", Detail:"", Applied:"",
        RegistrationCommitted:false, RegistrationSynced:false}
    for name, value in values.OwnProps()
        job.%name% := value
    if job.Mode = "queued"
        job.Phase := "queued"
    return job
}
SetReactionJobPhase(job, phase) {
    if ActiveReactionJob != job || job.Cancelled || job.Phase = "finished"
        return false
    job.Phase := phase
    return true
}
StopReactionTimers() {
    SetTimer(ReactionCountdown, 0)
    SetTimer(ReactionSendNext, 0)
    SetTimer(QuickReaction, 0)
}
FinishReactionJob(job) {
    global ActiveReactionJob
    job.Phase := "finished"
    if ActiveReactionJob != job
        return
    StopReactionTimers()
    ActiveReactionJob := 0
}

QueueQuickReaction(*) {
    global ActiveReactionJob
    if ShortcutBlocked("reaction")
        return
    ActiveReactionJob := CreateReactionJob({Mode: "queued", Window: WinExist("A")})
    SetReactionStatus("ショートカットを受け付けました。キーを離してください。", false, "queued")
    ShowReactionProgress()
    SetTimer(QuickReaction, -1)
}

ScheduleReaction(mode, delay, options := 0) {
    global ActiveReactionJob
    if !OperationAllowed("reaction")
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
    if !choice
        return false
    ActiveReactionJob := CreateReactionJob({Mode: mode, Window: TargetBrowserHwnd, Video: context.Video,
        Applied:"適用：" (options ? "今回の設定" : "共通設定") " / " ReactionNames[choice],
        Choice: choice, Remaining: delay, Total: options ? options.Count : DefaultReactionCount,
        Completed: 0, Cancelled: false, Interval: options ? options.Interval : DefaultReactionIntervalMs})
    PaletteWindow.Hide()
    WinActivate("ahk_id " TargetBrowserHwnd)
    SetReactionStatus(mode = "reaction_capture" ? "登録待機中：YouTubeの♡にマウスを重ねてください。" ShortcutKeyLabel(GetShortcutKey("stop")) "で中止。" : delay "秒後に開始します。♡のメニューを開いてください。")
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
    if !IsTargetForeground(ActiveReactionJob.Window) {
        stoppedJob := ActiveReactionJob
        CancelReaction()
        ReactionNotice("wrong_window","","",stoppedJob)
        return
    }
    ActiveReactionJob.Remaining--
    if ActiveReactionJob.Remaining > 0 {
        ShowStatusTip(ActiveReactionJob.Remaining "秒後に実行。♡のメニューを表示してください。" ShortcutKeyLabel(GetShortcutKey("stop")) "で中止。")
        return
    }
    SetTimer(ReactionCountdown, 0)
    job := ActiveReactionJob
    if !SetReactionJobPhase(job,"running")
        return
    if job.Mode = "reaction_send" {
        ReactionSendNext()
        return
    }
    try {
        point := Buffer(8, 0)
        DllCall("GetPhysicalCursorPos", "Ptr", point)
        extra := "Reaction=" job.Choice "`nX=" NumGet(point, 0, "Int") "`nY=" NumGet(point, 4, "Int") "`n"
        reply := RequestBrowserOperation(job.Window, job.Mode, job.Video, extra)
        if job.Mode = "reaction_capture"
            reply := FinalizeReactionCapture(job,reply)
        if job.Cancelled && !job.RegistrationCommitted {
            SetReactionStatus("登録・確認を中止しました。", true,"","",job,"cancelled")
        } else if ShouldWaitForRegistration(job, reply) {
            SetReactionJobPhase(job,"waiting")
            job.Detail := reply.HasOwnProp("Detail") ? reply.Detail : ""
            SetReactionStatus("登録待機中：♡のメニューを開き、マウスをその上に置いてください。" ShortcutKeyLabel(GetShortcutKey("stop")) "で中止。")
            SetTimer(ReactionCountdown, -1000)
            return
        } else
            ReactionNotice(reply.State, reply.HasOwnProp("Detail") ? reply.Detail : "")
    } catch as captureError {
        ReactionNotice("unavailable", captureError.Message)
    } finally {
        if ActiveReactionJob = job && (!IsSet(reply) || !ShouldWaitForRegistration(job, reply))
            FinishReactionJob(job)
    }
}

; The job owns cancellation; persistence and worker synchronization stay in their service.
FinalizeReactionCapture(job, reply) {
    global IsBrowserOperationBusy, LastBrowserOperation
    previousCritical := A_IsCritical
    Critical("On")
    previousBusy := IsBrowserOperationBusy
    IsBrowserOperationBusy := true
    started := A_TickCount
    try {
        ; Cancellation and persistence form one decision. Do not hold Critical across IPC.
        if ActiveReactionJob != job || job.Cancelled {
            reply := {State:"cancelled",Detail:""}
            return reply
        }
        reply := SaveCapturedReactionRegistration(reply)
        if reply.State = "saved"
            job.RegistrationCommitted := true
        Critical(previousCritical)
        reply := SynchronizeCapturedReactionRegistration(job.Window,reply)
        job.RegistrationSynced := reply.State = "registered"
        return reply
    } finally {
        Critical(previousCritical)
        IsBrowserOperationBusy := previousBusy
        LastBrowserOperation.State := reply.State
        LastBrowserOperation.Duration += A_TickCount-started
    }
}

ShouldWaitForRegistration(job, reply) {
    return !job.Cancelled && job.Mode = "reaction_capture" && (reply.State = "unsupported" || reply.State = "wrong_window")
}

CancelReaction(*) {
    StopReactionTimers()
    if !ActiveReactionJob
        return
    job := ActiveReactionJob
    job.Cancelled := true, job.Phase := "stopping"
    if IsBrowserOperationBusy {
        SetReactionStatus("停止を受け付けました。現在の操作の結果を確認して終了します。")
        return
    }
    message := job.Mode = "queued" ? "中止しました。" : "中止しました。操作済み " job.Completed " / " job.Total " 回。"
    FinishReactionJob(job)
    SetReactionStatus(message,true,"","",job,"cancelled")
    ShowStatusTip()
}

ReactionSendNext() {
    global ActiveReactionJob
    if !ActiveReactionJob
        return
    job := ActiveReactionJob
    if job.Cancelled || !IsTargetForeground(job.Window) {
        CancelReaction()
        SetReactionStatus("操作先が変わったため停止しました。操作済み " job.Completed " / " job.Total " 回。", true,"","",job,"wrong_window")
        return
    }
    if !SetReactionJobPhase(job,"running")
        return
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
            if !IsTargetForeground(job.Window) {
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
        FinishReactionJob(job)
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
    return RuntimePorts.TimingPrecision ? RuntimePorts.TimingPrecision.Call(enabled) : NativeSetReactionTimingPrecision(enabled)
}

NativeSetReactionTimingPrecision(enabled) {
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
    return RuntimePorts.Clock ? RuntimePorts.Clock.Call() : NativeReactionClockMs()
}

NativeReactionClockMs() {
    static frequency := 0
    if !frequency
        DllCall("QueryPerformanceFrequency", "Int64*", &frequency)
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    return counter * 1000 / frequency
}

ReactionWaitRemaining(job, now) {
    return job.Interval = 0 || !job.HasOwnProp("StartedAt") || job.StartedAt < 0 ? 0 : Max(0, job.StartedAt + job.Interval - now)
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
        FinishReactionJob(job)
        ReactionNotice(reply.State, reply.HasOwnProp("Detail") ? reply.Detail : "", " 操作済み " job.Completed " / " job.Total " 回で停止。",job)
        return
    }
    if job.FirstStartedAt < 0 {
        job.FirstStartedAt := job.StartedAt
        job.Measurement := ""
    }
    job.Completed++
    if job.Completed > 1
        job.Measurement := "（平均開始間隔 " Round((job.StartedAt - job.FirstStartedAt) / (job.Completed - 1)) " ms）"
    progress := job.Applied "`n操作済み " job.Completed " / " job.Total " 回" job.Measurement
    if job.Cancelled || job.Completed >= job.Total {
        FinishReactionJob(job)
        SetReactionStatus(progress "。" (job.Cancelled ? "中止しました。" : "完了しました。") " YouTube側の受理回数は未確認です。", true,"","",job,job.Cancelled ? "cancelled" : "completed")
        return
    }
    SetReactionStatus(progress "。実行中：" ShortcutKeyLabel(GetShortcutKey("stop")) "で停止。")
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
        key := RegExReplace(ShortcutKeys["reaction"], "[!^+#<>]", "")
        if !WaitShortcutRelease([key, "Control", "Alt", "Shift"])
            return
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled || !IsTargetForeground(hwnd)
            return
        context := RequestBrowserOperation(hwnd, "browser_context")
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        if context.State != "ok" || !IsTargetForeground(hwnd) {
            ReactionNotice("unavailable")
            return
        }
        choice := DefaultReactionKind
        if !choice || ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        ActiveReactionJob := CreateReactionJob({Mode: "reaction_send", Window: hwnd, Video: context.Video,
            Applied:"適用：共通設定 / " ReactionNames[choice],
            Choice: choice, Total: DefaultReactionCount, Completed: 0, Cancelled: false, Interval: DefaultReactionIntervalMs})
        batchStarted := true
        ReactionSendNext()
    } catch as operationError {
        if ActiveReactionJob = queuedJob
            ReactionNotice("unknown", operationError.Message)
    } finally {
        if !batchStarted && ActiveReactionJob = queuedJob {
            FinishReactionJob(queuedJob)
            if queuedJob.Cancelled
                SetReactionStatus("中止しました。",true,"","",queuedJob,"cancelled")
            else
                SetReactionStatus("開始できませんでした。キーを離し、YouTubeを最前面にして再実行してください。",true,"","",queuedJob,"unavailable")
        }
    }
}

SetReactionStatus(message, final := false, phase := "", detail := "", job := 0, reason := "") {
    global ReactionExecutionStatus, LastReactionResult
    if !job && ActiveReactionJob
        job := ActiveReactionJob
    ReactionExecutionStatus := {Phase: phase != "" ? phase : (final ? "finished" : (job ? job.Phase : "running")), Message: message, Final: final}
    if final {
        LastReactionResult := {Message:message, Detail:detail,
            Completed:job ? job.Completed : 0,
            Total:job ? job.Total : 0,
            Mode:job ? job.Mode : "", Reason:reason != "" ? reason : "finished", FinishedAt:FormatTime(,"yyyy/MM/dd HH:mm:ss")}
    }
    RefreshOperationControls()
    RenderReactionStatus()
}
