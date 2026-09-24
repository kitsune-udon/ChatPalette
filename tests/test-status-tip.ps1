# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$body = @'
try {
    ShowStatusTip("old",150)
    Sleep(50)
    ShowStatusTip("new",500)
    Sleep(250)
    tip := "ahk_class tooltips_class32 ahk_pid " DllCall("GetCurrentProcessId")
    if !WinExist(tip) || WinGetTitle(tip)!="new"
        throw Error("Replacement notification mismatch: hwnd=" WinExist(tip) " title=" (WinExist(tip) ? WinGetTitle(tip) : "missing"))
    Sleep(350)
    if WinExist(tip)
        throw Error("Replacement notification did not expire")
    ShowStatusTip("temporary",150)
    ShowStatusTip("waiting")
    Sleep(250)
    if !WinExist(tip) || WinGetTitle(tip)!="waiting"
        throw Error("Persistent notification inherited an old expiry")
    ShowStatusTip()
    if WinExist(tip)
        throw Error("Explicit clear left a notification visible")
    FileAppend("PASS: 4 notification lifetime checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message "`n","**")
    ExitApp(1)
}
'@
Invoke-AppTest -Runtime $release -Body $body
