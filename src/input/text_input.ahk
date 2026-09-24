DeliverText(text, hwnd, expectedVideo, activate := false) {
    if activate {
        try WinActivate("ahk_id " hwnd)
        catch TargetError
            return false
        if !WinWaitActive("ahk_id " hwnd, , 2)
            return false
        KeyWait("Enter")
        KeyWait("LButton")
    }
    if !IsTargetForeground(hwnd)
        return false
    if !VerifyInputTarget(hwnd, expectedVideo)
        return false
    SendInputText(text)
    return true
}
SendInputText(text) {
    if RuntimePorts.Text
        RuntimePorts.Text.Call(text)
    else
        ; VK_IME_OFF is idempotent; send it and literal text in one ordered batch.
        SendInput("{vk1A}{Text}" text)
}
