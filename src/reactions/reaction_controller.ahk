; Feature module. The worker adapter is in reaction_automation.ps1.
InitReactions() {
    InstallKeybdHook()
    global ActiveReactionJob := 0
    global ReactionExecutionStatus := {Phase: "idle", Message: ""}
    global LastReactionResult := {Message:"まだ実行していません。",Detail:"",Completed:0,Total:0,Mode:"",Reason:"idle"}
}

CreateReactionJob(values) {
    job := {Mode:"reaction_send", Phase:"waiting", Window:0, Video:"", Choice:1,
        Remaining:0, Total:0, Completed:0, Cancelled:false, Interval:0,
        StartedAt:-1, FirstStartedAt:-1, Applied:"", RegistrationCommitted:false, ReleasedStatus:0}
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
; All job timers verify ownership and arm within one uninterrupted decision.
ArmReactionTimer(job, callback, period) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if ActiveReactionJob != job || job.Cancelled || job.Phase = "finished"
            return false
        SetTimer(callback, period)
        return true
    } finally Critical(previousCritical)
}

StopReactionTimers() {
    SetTimer(ReactionCountdown, 0)
    SetTimer(QuickReaction, 0)
}
FinishReactionJob(job) {
    global ActiveReactionJob
    previousCritical := A_IsCritical
    Critical("On")
    try {
        job.Phase := "finished"
        if ActiveReactionJob != job
            return false
        StopReactionTimers()
        ; Release and the final publication's baseline are one ownership decision.
        job.ReleasedStatus := ReactionExecutionStatus
        ActiveReactionJob := 0
    } finally Critical(previousCritical)
    RefreshOperationControls()
    return true
}

QueueQuickReaction(*) {
    if ShortcutBlocked("reaction")
        return
    StartReactionJob(CreateReactionJob({Mode: "queued", Window: WinExist("A")}))
}

ScheduleReaction(mode, delay, options := 0) {
    if !OperationAllowed("reaction")
        return false
    hwnd := TargetBrowserHwnd
    if !IsBrowser(hwnd) {
        ReactionNotice({State:"wrong_window"})
        return false
    }
    try context := RequestBrowserOperation(hwnd, "browser_context")
    catch as failure
        context := {State:"unavailable",Detail:failure.Message}
    if !OperationAllowed("reaction")
        return false
    if context.State != "ok" {
        ReactionNotice(context)
        return false
    }
    choice := options ? options.Reaction : DefaultReactionKind
    if !choice
        return false
    job := CreateReactionJob({Mode: mode, Window: hwnd, Video: context.Video,
        Applied:"適用：" (options ? "今回の設定" : "共通設定") " / " ReactionNames[choice],
        Choice: choice, Remaining: delay, Total: options ? options.Count : DefaultReactionCount,
        Interval: options ? options.Interval : DefaultReactionIntervalMs})
    return StartReactionJob(job)
}

; Both entry paths publish, present and schedule through the same owner lifetime.
StartReactionJob(job) {
    global ActiveReactionJob
    ActiveReactionJob := job
    started := false, startFailure := 0
    try {
        if job.Mode = "queued"
            message := "ショートカットを受け付けました。キーを離してください。"
        else {
            PaletteWindow.Hide()
            WinActivate("ahk_id " job.Window)
            message := job.Mode = "reaction_capture" ? "登録待機中：YouTubeの♡にマウスを重ねてください。" ShortcutKeyLabel(GetShortcutKey("stop")) "で中止。"
                : job.Remaining "秒後に開始します。♡のメニューを開いてください。"
        }
        if ActiveReactionJob != job || job.Cancelled
            return false
        SetReactionStatus(message,false,"",job)
        if ActiveReactionJob != job || job.Cancelled
            return false
        ShowReactionProgress()
        started := job.Mode = "queued" ? ArmReactionTimer(job,QuickReaction,-1)
            : ArmReactionTimer(job,ReactionCountdown,1000)
        return started
    } catch as failure {
        startFailure := failure
        return false
    } finally {
        if !started && FinishReactionJob(job) && startFailure
            ReactionNotice({State:"unavailable",Detail:startFailure.Message},job)
    }
}

ReactionCountdown() {
    job := ActiveReactionJob
    if !job {
        SetTimer(ReactionCountdown, 0)
        return
    }
    waiting := false, reply := 0
    try {
        if !IsTargetForeground(job.Window) {
            reply := {State:"wrong_window"}
            return
        }
        if ActiveReactionJob != job || job.Cancelled
            return
        job.Remaining--
        if job.Remaining > 0 {
            ShowStatusTip(job.Remaining "秒後に実行。♡のメニューを表示してください。" ShortcutKeyLabel(GetShortcutKey("stop")) "で中止。")
            waiting := true
            return
        }
        SetTimer(ReactionCountdown, 0)
        if job.Mode = "reaction_send" {
            RunReactionSendLoop(job)
            return
        }
        if !SetReactionJobPhase(job,"running")
            return
        point := Buffer(8, 0)
        DllCall("GetPhysicalCursorPos", "Ptr", point)
        extra := "Reaction=" job.Choice "`nX=" NumGet(point, 0, "Int") "`nY=" NumGet(point, 4, "Int") "`n"
        started := AppClockMs()
        reply := RequestBrowserOperation(job.Window, job.Mode, job.Video, extra)
        if ActiveReactionJob != job
            return
        if job.Mode = "reaction_capture"
            reply := FinalizeReactionCapture(job,reply)
        if ActiveReactionJob != job
            return
        if job.Mode = "reaction_capture"
            RecordBrowserOperation({Mode:job.Mode,State:reply.State,Window:job.Window,Duration:Round(AppClockMs()-started)})
        if ShouldWaitForRegistration(job, reply) {
            if !SetReactionJobPhase(job,"waiting")
                return
            SetReactionStatus("登録待機中：♡のメニューを開き、マウスをその上に置いてください。" ShortcutKeyLabel(GetShortcutKey("stop")) "で中止。",false,"",job)
            waiting := ArmReactionTimer(job,ReactionCountdown,-1000)
        }
    } catch as captureError {
        reply := {State:"unavailable",Detail:captureError.Message}
    } finally {
        ; Publish a result only after releasing this tick's owner; a replacement keeps its state.
        if !waiting && FinishReactionJob(job) {
            if job.Cancelled && !job.RegistrationCommitted
                SetReactionStatus("登録・確認を中止しました。", true,"",job,"cancelled")
            else if reply
                ReactionNotice(reply,job)
        }
    }
}

; The job owns cancellation; persistence and worker synchronization stay in their service.
FinalizeReactionCapture(job, reply) {
    global IsBrowserOperationBusy
    previousCritical := A_IsCritical
    Critical("On")
    previousBusy := IsBrowserOperationBusy
    IsBrowserOperationBusy := true
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
        return reply
    } finally {
        Critical(previousCritical)
        IsBrowserOperationBusy := previousBusy
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
        SetReactionStatus("停止を受け付けました。現在の操作の結果を確認して終了します。",false,"",job)
        return
    }
    message := job.Mode = "queued" ? "中止しました。" : "中止しました。操作済み " job.Completed " / " job.Total " 回。"
    FinishReactionJob(job)
    if SetReactionStatus(message,true,"",job,"cancelled")
        ShowStatusTip()
}

; One serial loop owns this explicit job; stale calls cannot run a replacement.
RunReactionSendLoop(job) {
    if !job || !SetReactionJobPhase(job,"running")
        return
    precisionEnabled := false
    releasePrecision := (*) => SetReactionTimingPrecision(false)
    try {
        if !IsTargetForeground(job.Window) {
            if FinishReactionJob(job)
                ReactionNotice({State:"wrong_window"},job)
            return
        }
        if job.Interval > 0 {
            precisionEnabled := SetReactionTimingPrecision(true)
            if precisionEnabled
                OnExit(releasePrecision)
        }
        while ActiveReactionJob = job && !job.Cancelled {
            if !WaitReactionInterval(job)
                return
            if !IsTargetForeground(job.Window) {
                if FinishReactionJob(job)
                    ReactionNotice({State:"wrong_window"},job)
                return
            }
            job.StartedAt := AppClockMs()
            reply := RequestBrowserOperation(job.Window, "reaction_send", job.Video, "Reaction=" ResolveReactionKind(job.Choice) "`n")
            if ActiveReactionJob != job
                return
            ApplyReactionResult(job, reply)
        }
    } catch as operationError {
        if FinishReactionJob(job)
            ReactionNotice({State:"unknown",Detail:operationError.Message},job)
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

ReactionWaitRemaining(job, now) {
    return job.Interval = 0 || job.StartedAt < 0 ? 0 : Max(0, job.StartedAt + job.Interval - now)
}

WaitReactionInterval(job) {
    ; Always pump cancellation, including 待機なし. Never queue concurrent requests.
    Sleep(-1)
    while ActiveReactionJob = job && !job.Cancelled {
        remaining := ReactionWaitRemaining(job, AppClockMs())
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
        ReactionNotice(reply,job)
        return
    }
    if job.FirstStartedAt < 0
        job.FirstStartedAt := job.StartedAt
    job.Completed++
    measurement := job.Completed > 1 ? "（平均開始間隔 " Round((job.StartedAt - job.FirstStartedAt) / (job.Completed - 1)) " ms）" : ""
    progress := job.Applied "`n操作済み " job.Completed " / " job.Total " 回" measurement
    if job.Cancelled || job.Completed >= job.Total {
        FinishReactionJob(job)
        SetReactionStatus(progress "。" (job.Cancelled ? "中止しました。" : "完了しました。") " YouTube側の受理回数は未確認です。", true,"",job,job.Cancelled ? "cancelled" : "completed")
        return
    }
    SetReactionStatus(progress "。実行中：" ShortcutKeyLabel(GetShortcutKey("stop")) "で停止。",false,"",job)
    ; The serial loop schedules against this operation's start, not its completion.
}

QuickReaction(*) {
    global ActiveReactionJob
    if !ActiveReactionJob || ActiveReactionJob.Mode != "queued"
        return
    queuedJob := ActiveReactionJob
    hwnd := queuedJob.Window, startFailure := 0
    try {
        if !WaitShortcutRelease(GetShortcutKey("reaction"))
            return
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        if !IsTargetForeground(hwnd) {
            startFailure := {State:"wrong_window"}
            return
        }
        context := RequestBrowserOperation(hwnd, "browser_context")
        if ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        if context.State != "ok" || !IsTargetForeground(hwnd) {
            startFailure := context.State != "ok" ? context : {State:"wrong_window"}
            return
        }
        choice := DefaultReactionKind
        if !choice || ActiveReactionJob != queuedJob || queuedJob.Cancelled
            return
        sendJob := CreateReactionJob({Mode: "reaction_send", Window: hwnd, Video: context.Video,
            Applied:"適用：共通設定 / " ReactionNames[choice],
            Choice: choice, Total: DefaultReactionCount, Interval: DefaultReactionIntervalMs})
        ActiveReactionJob := sendJob
        RunReactionSendLoop(sendJob)
    } catch as operationError {
        startFailure := {State:"unknown",Detail:operationError.Message}
    } finally {
        ; Finalize the queued attempt once; never overwrite a handed-off or replacement job.
        if ActiveReactionJob = queuedJob {
            FinishReactionJob(queuedJob)
            if queuedJob.Cancelled
                SetReactionStatus("中止しました。",true,"",queuedJob,"cancelled")
            else if startFailure
                ReactionNotice(startFailure,queuedJob)
            else
                SetReactionStatus("開始できませんでした。キーを離し、YouTubeを最前面にして再実行してください。",true,"",queuedJob,"unavailable")
        }
    }
}

SetReactionStatus(message, final := false, detail := "", job := 0, reason := "") {
    global ReactionExecutionStatus, LastReactionResult
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !job && ActiveReactionJob
            job := ActiveReactionJob
        ; After release, publish only if no later status has taken its place.
        if job && ActiveReactionJob != job
            && (!final || ActiveReactionJob || ReactionExecutionStatus != job.ReleasedStatus)
            return false
        status := {Phase:final ? "finished" : (job ? job.Phase : "running"), Message: message}
        ReactionExecutionStatus := status
        if final {
            LastReactionResult := {Message:message, Detail:detail,
                Completed:job ? job.Completed : 0,
                Total:job ? job.Total : 0,
                Mode:job ? job.Mode : "", Reason:reason != "" ? reason : "finished"}
        }
    } finally Critical(previousCritical)
    RefreshOperationControls()
    RenderReactionStatus()
    ; Rendering can yield to a new status; callers must not publish an older tooltip afterward.
    return ReactionExecutionStatus = status
}
