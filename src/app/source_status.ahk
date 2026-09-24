; Read only at startup and explicit diagnostic refresh; never poll or inspect data/.
CaptureAppSource() {
    paths := "main.ahk`nVERSION`n"
    Loop Files A_ScriptDir "\src\*", "FR" {
        if A_LoopFileExt = "ahk" || A_LoopFileExt = "ps1"
            paths .= SubStr(A_LoopFileFullPath,StrLen(A_ScriptDir)+2) "`n"
    }
    signature := ""
    for path in StrSplit(RTrim(Sort(paths),"`n"),"`n") {
        bytes := FileRead(A_ScriptDir "\" path,"RAW"), hash := Buffer(32), size := 32
        if !DllCall("crypt32\CryptHashCertificate2","Str","SHA256","UInt",0,"Ptr",0,
            "Ptr",bytes,"UInt",bytes.Size,"Ptr",hash,"UInt*",&size)
            throw Error("ソース情報を取得できません。")
        signature .= path ":"
        Loop size
            signature .= Format("{:02x}",NumGet(hash,A_Index-1,"UChar"))
        signature .= "`n"
    }
    return signature
}
AppSourceStatus() {
    try {
        if StartupSource = ""
            return "起動時のソース情報を取得できませんでした"
        return CaptureAppSource() == StartupSource ? "起動時のソースと一致" : "更新あり：再起動で反映"
    } catch {
        return "ソースを確認できません（削除・読み取り失敗）"
    }
}
RestartApplication(*) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        policy := OperationPolicy("edit")
        if !policy.Allowed {
            ShowStatusTip(policy.Message,3000)
            return false
        }
        if RuntimePorts.Restart
            RuntimePorts.Restart.Call()
        else
            Reload()
        return true
    } finally {
        Critical(previousCritical)
    }
}
