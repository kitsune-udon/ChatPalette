; Browser request orchestration, including UI wait lifetime. Transport stays in worker_client.
IsBrowser(hwnd) {
    return BrowserNames().Has(ReadBrowserProcessName(hwnd))
}

BrowserNames() {
    static names := Map("chrome.exe","Chrome", "msedge.exe","Edge", "firefox.exe","Firefox",
        "brave.exe","Brave", "opera.exe","Opera", "vivaldi.exe","Vivaldi")
    return names
}

; Native identity checks bypass the fixture even when its process-name port is set.
NativeIsBrowser(hwnd) {
    return BrowserNames().Has(NativeReadBrowserProcessName(hwnd))
}
ReadBrowserProcessName(hwnd) {
    if !RuntimePorts.BrowserProcessName
        return NativeReadBrowserProcessName(hwnd)
    ; Select the fixture before the native empty-handle guard; tests may own synthetic IDs.
    try return StrLower(RuntimePorts.BrowserProcessName.Call(hwnd))
    catch TargetError
        return ""
}
NativeReadBrowserProcessName(hwnd) {
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
    started := AppClockMs(), reply := 0
    IsBrowserOperationBusy := true
    try {
        waitView := CreateWorkerWait(mode)
        BeginWorkerWait(waitView)
        if InStr(mode,"reaction_") = 1 {
            try EnsureReactionRegistrations(hwnd)
            catch as failure
                reply := {State:"sync_failed",Author:"",Channel:"",Video:"",Detail:failure.Message}
        }
        if !reply
            reply := SendWorkerRequest(hwnd, mode, expectedVideo, extra)
        return reply
    } finally {
        ; Release the request and restore its windows before another owner can enter.
        cleanupCritical := A_IsCritical
        Critical("On")
        try {
            ; No reply means the outcome is unknown; never leave an older success.
            try RecordBrowserOperation({Mode:mode, State:reply ? reply.State : "unknown",
                Window:hwnd, Duration:Round(AppClockMs()-started)})
            finally {
                IsBrowserOperationBusy := false
                if IsSet(waitView)
                    EndWorkerWait(waitView)
            }
        } finally Critical(cleanupCritical)
    }
}

ResolveBrowserChannel(hwnd) {
    return RuntimePorts.ResolveChannel ? RuntimePorts.ResolveChannel.Call(hwnd) : RequestBrowserOperation(hwnd)
}


; Input orchestration owns foreground checks; this adapter verifies only video and field.
VerifyInputTarget(hwnd, expectedVideo) {
    result := RequestBrowserOperation(hwnd, "verify_input", expectedVideo)
    if result.State = "ok" && expectedVideo != "" && !(result.Video == expectedVideo)
        return {State:"changed"}
    return result
}

; Clear and queued input consume the same focus proof and require the same video.
VerifyChatFocus(hwnd, focus) {
    if focus.Video = "" || !focus.HasOwnProp("Detail") || focus.Detail = ""
        return {State:"wrong_input"}
    result := RequestBrowserOperation(hwnd,"verify_chat",focus.Video,"FocusToken=" focus.Detail)
    if result.State = "ok" && !(result.Video == focus.Video)
        return {State:"changed"}
    return result
}
