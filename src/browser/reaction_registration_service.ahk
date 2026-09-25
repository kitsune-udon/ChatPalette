; The application owns durable registration. Workers receive only committed snapshots.
PrepareReactionRegistrations(hwnd) {
    EnsureWorkerRunning()
    if IsWorkerRegistrationCurrent()
        return true
    reply := SendWorkerRequest(hwnd,"reaction_configure","","Payload=" LoadReactionRegistrationSnapshot() "`n")
    if reply.State != "configured"
        return false
    MarkWorkerRegistrationCurrent()
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
    InvalidateWorkerRegistration()
    try {
        if !PrepareReactionRegistrations(hwnd)
            throw Error("登録情報の同期に失敗しました。")
    } catch as failure {
        ; The committed registration remains unsynchronized; every reaction entry retries it.
        reply.State := "sync_failed", reply.Detail := failure.Message
        return reply
    }
    reply.State := "registered", reply.Detail := ""
    return reply
}
