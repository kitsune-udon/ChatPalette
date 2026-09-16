; Browser request orchestration, including UI wait lifetime. Transport stays in worker_client.
IsBrowser(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false
    name := StrLower(WinGetProcessName("ahk_id " hwnd))
    return name = "chrome.exe" || name = "msedge.exe" || name = "firefox.exe" || name = "brave.exe" || name = "opera.exe" || name = "vivaldi.exe"
}

RequestBrowserOperation(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global IsBrowserOperationBusy, LastBrowserOperation
    if IsBrowserOperationBusy || !IsBrowser(hwnd)
        return {State: mode = "reaction_send" ? "unknown" : "unavailable", Author: "", Channel: "", Video: ""}
    IsBrowserOperationBusy := true
    try {
        waitView := BeginWorkerWait(mode)
        started := A_TickCount
        reply := SendWorkerRequest(hwnd, mode, expectedVideo, extra)
        ; Display-only queries must not erase the operation the user is investigating.
        if mode != "reaction_status"
            LastBrowserOperation := {Mode:mode, State:reply.State, Duration:A_TickCount-started}
        return reply
    } finally {
        IsBrowserOperationBusy := false
        if IsSet(waitView)
            EndWorkerWait(waitView)
    }
}

ResolveBrowserChannel(hwnd) {
    return RequestBrowserOperation(hwnd)
}

VerifyInputTarget(hwnd, expectedVideo) {
    if !WinActive("ahk_id " hwnd)
        return false
    result := RequestBrowserOperation(hwnd, "verify_input", expectedVideo)
    if result.State = "ok" && (expectedVideo = "" || result.Video == expectedVideo) && WinActive("ahk_id " hwnd)
        return true
    return false
}
