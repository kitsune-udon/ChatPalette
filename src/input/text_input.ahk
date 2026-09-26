SendInputText(text) {
    ; Text mode translates these characters into editing/navigation keys.
    if RegExMatch(text,"[\x08\x09\x0A\x0D]")
        return {State:"invalid_text"}
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
