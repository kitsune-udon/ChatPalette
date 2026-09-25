# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'fixtures\ui-message-probe.ahk') (Join-Path $release 'ui-message-probe.ahk')
$tests = @'
#Include %A_ScriptDir%\ui-message-probe.ahk
UiMessageProbe.Start()
AutoMode := false
BuildManagement()
choices := [{Id:"a",Name:"A"},{Id:"b",Name:"B"}]
Assert(SyncProfileChoices(PaletteProfile,choices),"changed names update")
PaletteProfile.Choose(2)
Assert(!SyncProfileChoices(PaletteProfile,choices) && PaletteProfile.Value=2,"same names keep native selection")
choices[1].Name := "caller mutation", choices[1].Id := "caller-id"
Assert(PaletteProfile.ProfileChoices[1].Name="A" && PaletteProfile.ProfileChoices[1].Id="a","displayed names and identities are detached from caller")
for names in [["B","A"],["b","A"],["b"],[],["same","same"]] {
    choices := []
    for i, name in names
        choices.Push({Id:"choice-" i,Name:name})
    Assert(SyncProfileChoices(PaletteProfile,choices),"order/case/count/empty/duplicates update")
    Assert(!SyncProfileChoices(PaletteProfile,choices),"equal labels reuse native contents")
}
PaletteProfile.Choose(2)
choices[2].Id := "replacement"
Assert(!SyncProfileChoices(PaletteProfile,choices) && PaletteProfile.Value=2 && PaletteProfile.ProfileChoices[2].Id="replacement","equal names publish changed identity without rebuilding native choices")
p := ExecuteProfileCommand("add","","Original").ProfileId
SaveInputProfileId(Profiles[1].Id)
RefreshPalette()
Assert(PaletteProfile.Text="Original","profile initially displayed")
InputProfileId := ""
RefreshPalette()
Assert(PaletteProfile.Value=0,"unchanged options clear absent input selection")
SaveInputProfileId(Profiles[1].Id)
ExecuteProfileCommand("rename",p,"Renamed")
RefreshPalette()
Assert(PaletteProfile.Text="Renamed","rename reflected")
ExecuteProfileCommand("delete",p)
RefreshPalette()
Assert(PaletteProfile.Value=0,"delete clears selection")
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
Assert(PaletteSearchPending && !PaletteInsert.Enabled && UiMessageProbe.Renders=before,"rapid changes defer full rebuild")
deadline := A_TickCount+2000
while (PaletteSearchPending || PaletteRefresh.Active) && A_TickCount<deadline
    Sleep(10)
Assert(!PaletteSearchPending && !PaletteRefresh.Active && UiMessageProbe.Renders=before+1 && PaletteRows.Length=11,"one completed rebuild uses final query")
PaletteSearch.Value := "text50"
QueuePaletteSearch()
before := UiMessageProbe.Renders
InsertPaletteItem()
Assert(UiMessageProbe.Renders=before+1 && !PaletteSearchPending && !ActiveEditorDialog,"pending insertion only refreshes")
PaletteSearch.Value := "text40"
QueuePaletteSearch()
before := UiMessageProbe.Renders
OpenPaletteLibrary()
Assert(UiMessageProbe.Renders=before+1 && !PaletteSearchPending,"pending editing only refreshes")
QueuePaletteSearch()
before := UiMessageProbe.Renders
HidePalette()
Sleep(160)
Assert(!PaletteSearchPending && UiMessageProbe.Renders=before,"closing cancels pending work")
ReturnToPalette()
Assert(PaletteRows.Length=11,"return reflects current query")
QueuePaletteSearch()
RefreshPalette()
before := UiMessageProbe.Renders
Sleep(160)
Assert(UiMessageProbe.Renders=before && !PaletteSearchPending,"explicit refresh cancels duplicate timer")
SharedDanmakuItems := [{Id:"search-small",Name:"small",Text:"small",Slot:0}]
PaletteSearch.Value := "small"
before := UiMessageProbe.Renders
QueuePaletteSearch()
Assert(UiMessageProbe.Renders=before+1 && !PaletteSearchPending && PaletteRows.Length=1,"small library searches immediately")
; Only the valid input profile contributes to the deferred-search threshold.
Profiles := [{Id:"search-profile",Name:"search profile",Channel:"/channel/search",Items:[]}]
Loop 201
    Profiles[1].Items.Push({Id:"profile-" A_Index,Name:"profile item",Text:"profile body " A_Index,Slot:0})
InputProfileId := "search-profile"
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
PaletteSearch.Value := "profile body"
for mode in ["matched","unmatched","manual"] {
    AutoMode := mode!="manual", TargetBrowserHwnd := mode="manual" ? 0 : 123
    DetectedChannel := {State:"ok",Channel:mode="matched" ? "/channel/search" : "/channel/other",Author:"fixture"}
    RefreshPalette()
    previousCritical := A_IsCritical
    Critical("On")
    try {
        before := UiMessageProbe.Renders
        QueuePaletteSearch()
        deferred := mode!="unmatched"
        Assert(PaletteSearchPending=deferred && UiMessageProbe.Renders=before+(deferred ? 0 : 1),"search scheduling counts only a valid profile: " mode)
        FlushPendingPaletteSearch()
        Assert(PaletteRows.Length=(deferred ? 201 : 0) && !PaletteSearchPending,"search rows use the same valid profile as scheduling: " mode)
    } finally Critical(previousCritical)
}
FileAppend("PASS: " Checks " choice cache and search scheduling checks`n","*")
ExitApp()
'@
Invoke-AppTest -Runtime $release -Body $tests
