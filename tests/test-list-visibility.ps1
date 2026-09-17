$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$fixture = $release
$tests = @'
OnExit(StopBrowserWorker)
try {
    AutoMode := false
    ExecuteDanmakuCommand("add","",0,{Name:"Visible",Text:"visible test",Slot:0})
    ShowManagement(1)
    AssertVisibleList("initial management display")
    ShowManagement(2)
    if DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
        throw Error("inactive tab leaked its list")
    ManagementTabs.Choose(1)
    AssertVisibleList("return after inactive tab refresh")
    ShowManagement(3)
    if DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
        throw Error("support tab leaked its list")
    ShowManagement(1)
    AssertVisibleList("return from support")
    ReturnToPalette()
    OpenPaletteLibrary()
    AssertVisibleList("reopen from palette")
    ; An explicitly hidden control must still remain hidden after tab changes.
    ManagedList.Visible := false
    RefreshManagement()
    ManagementTabs.Choose(2)
    ManagementTabs.Choose(1)
    if DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
        throw Error("explicitly hidden list became visible")
    ManagedList.Visible := true
    AssertVisibleList("explicit visibility restored")
    RefreshPalette()
    ShowPalette()
    if !DllCall("IsWindowVisible","Ptr",PaletteList.Hwnd)
        throw Error("palette list became hidden")
    FileAppend("PASS: management list remains visible across tabs and reopening`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message "`n","**")
    ExitApp(1)
}
AssertVisibleList(label) {
    if ManagedList.GetCount()!=1
        throw Error(label ": list data missing")
    if !DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
        throw Error(label ": populated list is hidden")
}
'@
$source = [IO.File]::ReadAllText((Join-Path $release 'main.ahk'))
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText((Join-Path $fixture 'main.ahk'), $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $fixture 'main.ahk') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
$null = $run.Handle
if (!$run.WaitForExit(15000)) { Stop-Process -Id $run.Id; throw 'List visibility test timed out' }
Get-Content -LiteralPath (Join-Path $fixture 'stdout.txt'),(Join-Path $fixture 'stderr.txt')
if ($run.ExitCode -ne 0) { throw "List visibility test failed: $fixture" }
