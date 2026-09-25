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
    choices := [{Id:"a",Name:"A"},{Id:"b",Name:"B"}]
    CheckChoice(SyncProfileChoices(PaletteProfile,choices),"changed names update")
    PaletteProfile.Choose(2)
    CheckChoice(!SyncProfileChoices(PaletteProfile,choices) && PaletteProfile.Value=2,"same names keep native selection")
    choices[1].Name := "caller mutation", choices[1].Id := "caller-id"
    CheckChoice(PaletteProfile.ProfileChoices[1].Name="A" && PaletteProfile.ProfileChoices[1].Id="a","displayed names and identities are detached from caller")
    for names in [["B","A"],["b","A"],["b"],[],["same","same"]] {
        choices := []
        for i, name in names
            choices.Push({Id:"choice-" i,Name:name})
        CheckChoice(SyncProfileChoices(PaletteProfile,choices),"order/case/count/empty/duplicates update")
        CheckChoice(!SyncProfileChoices(PaletteProfile,choices),"equal labels reuse native contents")
    }
    PaletteProfile.Choose(2)
    choices[2].Id := "replacement"
    CheckChoice(!SyncProfileChoices(PaletteProfile,choices) && PaletteProfile.Value=2 && PaletteProfile.ProfileChoices[2].Id="replacement","equal names publish changed identity without rebuilding native choices")
    p := ExecuteProfileCommand("add","","Original").ProfileId
    SaveInputProfileId(Profiles[1].Id)
    RefreshPalette()
    CheckChoice(PaletteProfile.Text="Original","profile initially displayed")
    InputProfileId := ""
    RefreshPalette()
    CheckChoice(PaletteProfile.Value=0,"unchanged options clear absent input selection")
    SaveInputProfileId(Profiles[1].Id)
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
    deadline := A_TickCount+2000
    while (PaletteSearchPending || PaletteRefresh.Active) && A_TickCount<deadline
        Sleep(10)
    CheckChoice(!PaletteSearchPending && !PaletteRefresh.Active && UiMessageProbe.Renders=before+1 && PaletteRows.Length=11,"one completed rebuild uses final query")
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
