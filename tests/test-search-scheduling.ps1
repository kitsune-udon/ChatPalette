$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$path = Join-Path $release 'src\ui\palette\palette_view.ahk'
$s = [IO.File]::ReadAllText($path).Replace('RefreshPaletteItems() {',"RefreshPaletteItems() {`r`n    global SearchRenders := IsSet(SearchRenders) ? SearchRenders+1 : 1")
[IO.File]::WriteAllText($path,$s,[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global ChoiceChecks := 0
try {
    AutoMode := false
    BuildManagement()
    labels := ["A","B"]
    CheckChoice(SyncChoiceNames(PaletteProfile,labels),"changed names update")
    PaletteProfile.Choose(2)
    CheckChoice(!SyncChoiceNames(PaletteProfile,["A","B"]) && PaletteProfile.Value=2,"same names keep native selection")
    labels[1] := "caller mutation"
    CheckChoice(!SyncChoiceNames(PaletteProfile,["A","B"]),"cached labels detached from caller")
    for names in [["B","A"],["b","A"],["b"],[],["same","same"]] {
        CheckChoice(SyncChoiceNames(PaletteProfile,names),"order/case/count/empty/duplicates update")
        CheckChoice(!SyncChoiceNames(PaletteProfile,names.Clone()),"equal labels reuse cached contents")
    }
    p := ExecuteProfileCommand("add","","Original").ProfileId
    SaveInputProfileSelection(1)
    RefreshPalette()
    CheckChoice(PaletteProfile.Text="Original","profile initially displayed")
    InputProfileIndex := 0
    RefreshPalette()
    CheckChoice(PaletteProfile.Value=0,"unchanged options clear absent input selection")
    SaveInputProfileSelection(1)
    ExecuteProfileCommand("rename",p,"Renamed")
    RefreshPalette()
    CheckChoice(PaletteProfile.Text="Renamed","rename reflected")
    ExecuteProfileCommand("delete",p)
    RefreshPalette()
    CheckChoice(PaletteProfile.Value=0,"delete clears selection")
    SharedDanmakuItems := []
    Loop 500
        SharedDanmakuItems.Push({Name:"row" A_Index,Text:"text" A_Index,Slot:0})
    RefreshPalette()
    PresentWindow(PaletteWindow,"w560 h740",ResizePalette,false)
    before := SearchRenders
    for query in ["t","te","text49"] {
        PaletteSearch.Value := query
        QueuePaletteSearch()
        Sleep(15)
    }
    CheckChoice(PaletteSearchPending && !PaletteInsert.Enabled && SearchRenders=before,"rapid changes defer full rebuild")
    Sleep(160)
    CheckChoice(!PaletteSearchPending && SearchRenders=before+1 && PaletteRows.Length=11,"one rebuild uses final query")
    PaletteSearch.Value := "text50"
    QueuePaletteSearch()
    before := SearchRenders
    InsertPaletteItem()
    CheckChoice(SearchRenders=before+1 && !PaletteSearchPending && !DanmakuEditorWindow,"pending insertion only refreshes")
    PaletteSearch.Value := "text40"
    QueuePaletteSearch()
    before := SearchRenders
    OpenPaletteLibrary()
    CheckChoice(SearchRenders=before+1 && !PaletteSearchPending,"pending editing only refreshes")
    QueuePaletteSearch()
    before := SearchRenders
    HidePalette()
    Sleep(160)
    CheckChoice(!PaletteSearchPending && SearchRenders=before,"closing cancels pending work")
    ReturnToPalette()
    CheckChoice(PaletteRows.Length=11,"return reflects current query")
    QueuePaletteSearch()
    RefreshPalette()
    before := SearchRenders
    Sleep(160)
    CheckChoice(SearchRenders=before && !PaletteSearchPending,"explicit refresh cancels duplicate timer")
    SharedDanmakuItems := [{Name:"small",Text:"small",Slot:0}]
    PaletteSearch.Value := "small"
    before := SearchRenders
    QueuePaletteSearch()
    CheckChoice(SearchRenders=before+1 && !PaletteSearchPending && PaletteRows.Length=1,"small library searches immediately")
    FileAppend("PASS: " ChoiceChecks " choice cache and search scheduling checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.Line "`n","**")
    ExitApp(1)
}
CheckChoice(value,label) {
    global ChoiceChecks
    ChoiceChecks++
    if !value
        throw Error(label)
}
'@
$source = [IO.File]::ReadAllText((Join-Path $release 'main.ahk'))
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText((Join-Path $fixture 'main.ahk'), $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $fixture 'main.ahk') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
$null = $run.Handle
if (!$run.WaitForExit(15000)) { Stop-Process -Id $run.Id; throw 'Search scheduling test timed out' }
Get-Content -LiteralPath (Join-Path $fixture 'stdout.txt'),(Join-Path $fixture 'stderr.txt')
if ($run.ExitCode -ne 0) { throw "Search scheduling test failed: $fixture" }
