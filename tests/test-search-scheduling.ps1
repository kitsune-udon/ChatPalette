# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'fixtures\ui-message-probe.ahk') (Join-Path $release 'ui-message-probe.ahk')
$tests = @'
OnExit(StopBrowserWorker)
#Include %A_ScriptDir%\ui-message-probe.ahk
UiMessageProbe.Start()
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
    InputProfileId := ""
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
        SharedDanmakuItems.Push({Id:"search-" A_Index,Name:"row" A_Index,Text:"text" A_Index,Slot:0})
    RefreshPalette()
    PresentWindow(PaletteWindow,"w560 h740",ResizePalette,false)
    before := UiMessageProbe.Renders
    for query in ["t","te","text49"] {
        PaletteSearch.Value := query
        QueuePaletteSearch()
        Sleep(15)
    }
    CheckChoice(PaletteSearchPending && !PaletteInsert.Enabled && UiMessageProbe.Renders=before,"rapid changes defer full rebuild")
    Sleep(160)
    CheckChoice(!PaletteSearchPending && UiMessageProbe.Renders=before+1 && PaletteRows.Length=11,"one rebuild uses final query")
    PaletteSearch.Value := "text50"
    QueuePaletteSearch()
    before := UiMessageProbe.Renders
    InsertPaletteItem()
    CheckChoice(UiMessageProbe.Renders=before+1 && !PaletteSearchPending && !DanmakuEditorWindow,"pending insertion only refreshes")
    PaletteSearch.Value := "text40"
    QueuePaletteSearch()
    before := UiMessageProbe.Renders
    OpenPaletteLibrary()
    CheckChoice(UiMessageProbe.Renders=before+1 && !PaletteSearchPending,"pending editing only refreshes")
    QueuePaletteSearch()
    before := UiMessageProbe.Renders
    HidePalette()
    Sleep(160)
    CheckChoice(!PaletteSearchPending && UiMessageProbe.Renders=before,"closing cancels pending work")
    ReturnToPalette()
    CheckChoice(PaletteRows.Length=11,"return reflects current query")
    QueuePaletteSearch()
    RefreshPalette()
    before := UiMessageProbe.Renders
    Sleep(160)
    CheckChoice(UiMessageProbe.Renders=before && !PaletteSearchPending,"explicit refresh cancels duplicate timer")
    SharedDanmakuItems := [{Id:"search-small",Name:"small",Text:"small",Slot:0}]
    PaletteSearch.Value := "small"
    before := UiMessageProbe.Renders
    QueuePaletteSearch()
    CheckChoice(UiMessageProbe.Renders=before+1 && !PaletteSearchPending && PaletteRows.Length=1,"small library searches immediately")
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
Invoke-AppTest -Runtime $release -Body $tests
