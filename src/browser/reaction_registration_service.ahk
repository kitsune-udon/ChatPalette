; The application owns durable registration. Workers receive only committed snapshots.
PrepareReactionRegistrations(hwnd) {
    global RegistrationWorkerPid
    EnsureWorkerRunning()
    if IsSet(RegistrationWorkerPid) && RegistrationWorkerPid = WorkerProcessId
        return true
    reply := SendWorkerRequest(hwnd,"reaction_configure","","Payload=" LoadReactionRegistrationSnapshot() "`n")
    if reply.State != "configured" {
        StopBrowserWorker()
        return false
    }
    RegistrationWorkerPid := WorkerProcessId
    return true
}
SaveCapturedReactionRegistration(reply) {
    if reply.State != "captured"
        return reply
    try SaveReactionRegistration(reply.Detail)
    catch as failure {
        reply.State := "save_failed", reply.Detail := failure.Message
        return reply
    }
    reply.State := "saved"
    return reply
}
SynchronizeCapturedReactionRegistration(hwnd,reply) {
    if reply.State != "saved"
        return reply
    global RegistrationWorkerPid := 0
    try {
        if !PrepareReactionRegistrations(hwnd)
            throw Error("登録情報の同期に失敗しました。")
    } catch as failure {
        ; The DB is committed, but the old worker must never remain usable.
        StopBrowserWorker()
        reply.State := "sync_failed", reply.Detail := failure.Message
        return reply
    }
    reply.State := "registered", reply.Detail := ""
    return reply
}
