; The application owns durable registration. Workers receive only committed snapshots.
EnsureReactionRegistrations(hwnd) {
    EnsureWorkerRunning()
    if IsWorkerRegistrationCurrent()
        return
    reply := SendWorkerRequest(hwnd,"reaction_configure","","Payload=" LoadReactionRegistrationSnapshot() "`n")
    if reply.State != "configured"
        throw Error(reply.HasOwnProp("Detail") && reply.Detail != "" ? reply.Detail : "登録情報の同期に失敗しました。")
    MarkWorkerRegistrationCurrent()
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
    try EnsureReactionRegistrations(hwnd)
    catch as failure {
        ; The committed registration remains unsynchronized; every reaction entry retries it.
        reply.State := "sync_failed", reply.Detail := failure.Message
        return reply
    }
    reply.State := "registered", reply.Detail := ""
    return reply
}
