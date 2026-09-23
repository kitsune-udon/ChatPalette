; Browser request orchestration, including UI wait lifetime. Transport stays in worker_client.
IsBrowser(hwnd) {
    return RuntimePorts.BrowserIdentity ? RuntimePorts.BrowserIdentity.Call(hwnd) : NativeIsBrowser(hwnd)
}

NativeIsBrowser(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false
    name := StrLower(WinGetProcessName("ahk_id " hwnd))
    return name = "chrome.exe" || name = "msedge.exe" || name = "firefox.exe" || name = "brave.exe" || name = "opera.exe" || name = "vivaldi.exe"
}

RequestBrowserOperation(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    return RuntimePorts.BrowserRequest ? RuntimePorts.BrowserRequest.Call(hwnd,mode,expectedVideo,extra) : NativeRequestBrowserOperation(hwnd,mode,expectedVideo,extra)
}

NativeRequestBrowserOperation(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global IsBrowserOperationBusy, LastBrowserOperation
    if IsBrowserOperationBusy || !IsBrowser(hwnd)
        return {State: mode = "reaction_send" ? "unknown" : "unavailable", Author: "", Channel: "", Video: ""}
    IsBrowserOperationBusy := true
    try {
        waitView := BeginWorkerWait(mode)
        started := A_TickCount
        ready := true
        if InStr(mode,"reaction_") = 1 {
            try ready := PrepareReactionRegistrations(hwnd)
            catch {
                StopBrowserWorker()
                ready := false
            }
        }
        reply := ready ? SendWorkerRequest(hwnd, mode, expectedVideo, extra)
            : {State:"sync_failed",Author:"",Channel:"",Video:""}
        ; Display-only queries must not erase the operation the user is investigating.
        if mode != "reaction_status"
            RecordBrowserOperation({Mode:mode, State:reply.State, Window:hwnd, Duration:A_TickCount-started})
        return reply
    } finally {
        IsBrowserOperationBusy := false
        if IsSet(waitView)
            EndWorkerWait(waitView)
    }
}

ResolveBrowserChannel(hwnd) {
    return RuntimePorts.ResolveChannel ? RuntimePorts.ResolveChannel.Call(hwnd) : NativeResolveBrowserChannel(hwnd)
}

NativeResolveBrowserChannel(hwnd) {
    return RequestBrowserOperation(hwnd)
}

VerifyInputTarget(hwnd, expectedVideo) {
    return RuntimePorts.VerifyInput ? RuntimePorts.VerifyInput.Call(hwnd,expectedVideo) : NativeVerifyInputTarget(hwnd,expectedVideo)
}

NativeVerifyInputTarget(hwnd, expectedVideo) {
    if !WinActive("ahk_id " hwnd)
        return false
    result := RequestBrowserOperation(hwnd, "verify_input", expectedVideo)
    if result.State = "ok" && (expectedVideo = "" || result.Video == expectedVideo) && WinActive("ahk_id " hwnd)
        return true
    return false
}
