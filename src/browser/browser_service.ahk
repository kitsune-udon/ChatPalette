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
    return BrowserNames().Has(ReadBrowserProcessName(hwnd))
}
ReadBrowserProcessName(hwnd) {
    if !hwnd
        return ""
    try return StrLower(WinGetProcessName("ahk_id " hwnd))
    catch TargetError
        return ""
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
        started := AppClockMs()
        reply := 0
        if InStr(mode,"reaction_") = 1 {
            try EnsureReactionRegistrations(hwnd)
            catch as failure
                reply := {State:"sync_failed",Author:"",Channel:"",Video:"",Detail:failure.Message}
        }
        if !reply
            reply := SendWorkerRequest(hwnd, mode, expectedVideo, extra)
        RecordBrowserOperation({Mode:mode, State:reply.State, Window:hwnd, Duration:Round(AppClockMs()-started)})
        return reply
    } finally {
        ; Release the request and restore its windows before another owner can enter.
        cleanupCritical := A_IsCritical
        Critical("On")
        try {
            IsBrowserOperationBusy := false
            if IsSet(waitView)
                EndWorkerWait(waitView)
        } finally Critical(cleanupCritical)
    }
}

ResolveBrowserChannel(hwnd) {
    return RuntimePorts.ResolveChannel ? RuntimePorts.ResolveChannel.Call(hwnd) : RequestBrowserOperation(hwnd)
}


VerifyInputTarget(hwnd, expectedVideo) {
    return RuntimePorts.VerifyInput ? RuntimePorts.VerifyInput.Call(hwnd,expectedVideo) : NativeVerifyInputTarget(hwnd,expectedVideo)
}

; Input orchestration owns foreground checks; this adapter verifies only video and field.
NativeVerifyInputTarget(hwnd, expectedVideo) {
    result := RequestBrowserOperation(hwnd, "verify_input", expectedVideo)
    return result.State = "ok" && (expectedVideo = "" || result.Video == expectedVideo)
}
