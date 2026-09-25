$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')

# Each scenario gets its own files, process, application state and fake worker.
function Invoke-AppFixture {
    param([string]$Body, [string]$Helpers = '', [string]$Runtime = '', [int]$TimeoutMs = 30000)
    $release = if ($Runtime) { $Runtime } else { New-TestRuntime }
$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
New-Item -ItemType Directory -Path "$fixture\data" -Force | Out-Null
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
function Find-RegisteredReactions([long]$WindowHandle, $Plan) { return @{ Elements=@($script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget); Detail="fixture reactions" } }
'@
Write-TestWorker -Runtime $release -Definitions $mock
    $frame = @'
InstallApplicationShortcuts()
'@ + "`r`n" + $Body + "`r`n" + @'
StopBrowserWorker()
FileAppend("PASS: " Checks " scenario checks; no real messages or reactions sent`n", "*")
ExitApp(0)
RejectFixtureInput(text) {
    throw Error("Unexpected input outside fixture")
}


'@
    Invoke-AppTest -Runtime $release -Body ($frame + "`r`n" + $Helpers) -TimeoutMs $TimeoutMs -Setup @'
fixtureSettings := CreateDefaultSettings()
fixtureSettings.InputProfileId := "fixture-profile"
fixtureSettings.DefaultReactionIntervalMs := 25
fixtureSettings.Profiles := [{Id:"fixture-profile",Name:"テスト投稿者",Channel:"/channel/fixture",Items:[
    {Id:"fixture-one",Name:"定番",Text:"test-one",Slot:1},
    {Id:"fixture-two",Name:"サビ",Text:"test-two",Slot:2}]}]
fixtureSettings.SharedDanmakuItems := [{Id:"fixture-shared",Name:"拍手",Text:"👏👏👏👏👏👏",Slot:1}]
OpenSettingsRepository(A_ScriptDir "\data\settings.db").SaveAll(fixtureSettings)
CloseSettingsStore()
RuntimePorts.WorkerScript := A_ScriptDir "\src\browser\fixture_worker.ps1"
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.Foreground := (hwnd) => hwnd=123
RuntimePorts.Text := RejectFixtureInput
RuntimePorts.ShortcutKey := (*) => 0

'@
}
