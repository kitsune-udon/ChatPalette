DeliverText(text, hwnd, expectedVideo, activate := false) {
    if activate {
        WinActivate("ahk_id " hwnd)
        if !WinWaitActive("ahk_id " hwnd, , 2)
            return false
        KeyWait("Enter")
        KeyWait("LButton")
    }
    if !IsTargetForeground(hwnd)
        return false
    if !VerifyInputTarget(hwnd, expectedVideo)
        return false
    if RuntimePorts.Text
        RuntimePorts.Text.Call(text)
    else
        SendText(text)
    return true
}
