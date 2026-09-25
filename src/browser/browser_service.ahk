; Browser request orchestration, including UI wait lifetime. Transport stays in worker_client.
IsBrowser(hwnd) {
    return RuntimePorts.BrowserIdentity ? RuntimePorts.BrowserIdentity.Call(hwnd) : NativeIsBrowser(hwnd)
}

BrowserNames() {
    static names := Map("chrome.exe","Chrome", "msedge.exe","Edge", "firefox.exe","Firefox",
        "brave.exe","Brave", "opera.exe","Opera", "vivaldi.exe","Vivaldi")
    return names
}

NativeIsBrowser(hwnd) {
    if !hwnd
        return false
    try name := StrLower(WinGetProcessName("ahk_id " hwnd))
    catch TargetError
        return false
    return BrowserNames().Has(name)
}

RequestBrowserOperation(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    return RuntimePorts.BrowserRequest ? RuntimePorts.BrowserRequest.Call(hwnd,mode,expectedVideo,extra) : NativeRequestBrowserOperation(hwnd,mode,expectedVideo,extra)
}

NativeRequestBrowserOperation(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global IsBrowserOperationBusy
    if IsBrowserOperationBusy || !IsBrowser(hwnd)
        return {State: mode = "reaction_send" ? "unknown" : "unavailable", Author: "", Channel: "", Video: ""}
    IsBrowserOperationBusy := true
    try {
        waitView := CreateWorkerWait(mode)
        BeginWorkerWait(waitView)
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
    return RuntimePorts.ResolveChannel ? RuntimePorts.ResolveChannel.Call(hwnd) : RequestBrowserOperation(hwnd)
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
