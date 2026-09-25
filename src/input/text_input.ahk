DeliverText(text, hwnd, expectedVideo, activate := false) {
    if activate {
        try WinActivate("ahk_id " hwnd)
        catch TargetError
            return {State:"input_cancelled"}
        if !WinWaitActive("ahk_id " hwnd, , 2)
            return {State:"input_cancelled"}
        KeyWait("Enter")
        KeyWait("LButton")
    }
    if !IsTargetForeground(hwnd)
        return {State:"input_cancelled"}
    if !VerifyInputTarget(hwnd, expectedVideo)
        return {State:"input_cancelled"}
    return SendInputText(text)
}
SendInputText(text) {
    try {
        if RuntimePorts.Text
            RuntimePorts.Text.Call(text)
        else
            ; VK_IME_OFF is idempotent; send it and literal text in one ordered batch.
            SendInput("{vk1A}{Text}" text)
        return {State:"inserted"}
    } catch {
        ; A failed send may already have inserted part of the text. Never replay it.
        return {State:"unknown"}
    }
}
