DeliverText(text, hwnd, expectedVideo, activate := false) {
    if activate {
        WinActivate("ahk_id " hwnd)
        if !WinWaitActive("ahk_id " hwnd, , 2)
            return false
        KeyWait("Enter")
        KeyWait("LButton")
    }
    if !WinActive("ahk_id " hwnd)
        return false
    if !VerifyInputTarget(hwnd, expectedVideo)
        return false
    SendText(text)
    return true
}
