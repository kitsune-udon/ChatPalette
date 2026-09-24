$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')

# Each scenario gets its own files, process, application state and fake worker.
function Invoke-AppFixture {
    param([string]$Body, [string]$Helpers = '', [string]$Runtime = '', [int]$TimeoutMs = 30000)
    $release = if ($Runtime) { $Runtime } else { New-TestRuntime }
$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
New-Item -ItemType Directory -Path "$fixture\data" -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\settings.ini') -Destination "$fixture\data\settings.ini" -Force
$mock = @'
function Invoke-FixtureRequest($Request) {
    if ($Request.Mode -eq 'fixture_native') {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$Request.Element)
        $record = Get-ReactionRecord $element
        $valid = (Test-ElementWindow $element ([long]$Request.Parent)) -and !(Test-ElementWindow $element ([long]$Request.Other)) -and ($record.Enabled -eq ($Request.Enabled -eq '1'))
        return @{Seq=$Request.Seq;Window=$Request.Window;State=$(if($valid){'ok'}else{'failed'})}
    }
    if ($Request.FixtureExit -eq '1') { exit 1 }
    if ($Request.FixtureDelay) { Start-Sleep -Milliseconds ([int]$Request.FixtureDelay) }
    return Invoke-WorkerRequest $Request
}
function Read-BrowserVideoId([long]$WindowHandle) { return 'abcdefghijk' }
function Get-BrowserProcessName([long]$WindowHandle) { return 'fixture' }
function Test-ReactionForeground([long]$WindowHandle) { return $true }
$script:fakeTarget = [pscustomobject]@{ Current=[pscustomobject]@{IsOffscreen=$false; IsEnabled=$true} }
$script:fakeInvoke = [pscustomobject]@{}
$script:fakeInvoke | Add-Member ScriptMethod Invoke { }
function Get-ReactionInvoker($Target) { return $script:fakeInvoke }
function Find-RegisteredReactions([long]$WindowHandle, $Saved) { return @{ Elements=@($script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget) } }
'@
Write-TestWorker -Runtime $release -Definitions $mock
    $frame = @'
OnExit(StopBrowserWorker)
InstallApplicationShortcuts()
global Checks := 0
try {
'@ + "`r`n" + $Body + @'
    StopBrowserWorker()
    FileAppend("PASS: " Checks " scenario checks; no real messages or reactions sent`n", "*")
    ExitApp(0)
} catch as testError {
    FileAppend("FAIL: " testError.Message " at line " testError.Line " " testError.File " " testError.Extra "`n" testError.Stack "`n", "*")
    ExitApp(1)
}
Assert(condition, label) {
    global Checks
    if !condition
        throw Error(label)
    Checks++
}
FixtureResolveChannel(hwnd) {
    global FixtureResolveCount
    if IsSet(FixtureInputMode) && FixtureInputMode {
        FixtureResolveCount++
        return {State:"ok",Author:"A",Channel:"/channel/a",Video:"aaaaaaaaaaa"}
    }
    return RequestBrowserOperation(hwnd)
}
FixtureVerifyInput(hwnd, expectedVideo) {
    if IsSet(FixtureInputMode) && FixtureInputMode
        return expectedVideo == FixtureCurrentVideo
    return NativeVerifyInputTarget(hwnd,expectedVideo)
}
CaptureFixtureInput(text) {
    if !(IsSet(FixtureInputMode) && FixtureInputMode)
        throw Error("Unexpected input outside fixture")
    FixtureSent.Push(text)
}

FixtureRequest(hwnd, mode, video, extra) {
    if mode = "reaction_send" && ActiveReactionJob
        FixtureStarts.Push(ActiveReactionJob.StartedAt)
    return NativeRequestBrowserOperation(hwnd,mode,video,extra)
}
FixtureReactionWindowActive(hwnd) {
    return hwnd = 123
}
FixtureShortcutKey(action,key, enabled := true) {
    if IsSet(KeyCalls)
        KeyCalls.Push({Key:key, Enabled:enabled})
}
FixtureShortcutRelease(keys) {
    global ActiveReactionJob
    if IsSet(ShortcutReleaseReplacement) && ShortcutReleaseReplacement {
        ; Model Esc followed by a new shortcut while the old KeyWait is suspended.
        ActiveReactionJob := ShortcutReleaseReplacement
        return ShortcutReleaseResult
    }
    return NativeWaitShortcutRelease(keys)
}

'@
    Invoke-AppTest -Runtime $release -Body ($frame + "`r`n" + $Helpers) -TimeoutMs $TimeoutMs -Setup @'
global FixtureInputMode := false, FixtureResolveCount := 0, FixtureCurrentVideo := "", FixtureSent := []
global FixtureStarts := [], KeyCalls := [], ShortcutReleaseReplacement := 0, ShortcutReleaseResult := true
RuntimePorts.WorkerScript := A_ScriptDir "\src\browser\fixture_worker.ps1"
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.ResolveChannel := FixtureResolveChannel
RuntimePorts.VerifyInput := FixtureVerifyInput
RuntimePorts.Foreground := FixtureReactionWindowActive
RuntimePorts.Text := CaptureFixtureInput
RuntimePorts.ShortcutKey := FixtureShortcutKey
RuntimePorts.ShortcutRelease := FixtureShortcutRelease
RuntimePorts.BrowserRequest := FixtureRequest

'@
}
