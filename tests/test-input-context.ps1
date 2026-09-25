# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime = New-TestRuntime
$source = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
OnExit(CloseSettingsStore)
global SettingsDatabasePath := A_ScriptDir "\settings.db", ApplicationShortcutsInstalled := false, LibraryHistory := []
global ContextCalls := 0, ContextReentry := false
state := CreateDefaultSettings()
state.Profiles := [
    {Id:"context-a",Name:"A",Channel:"/channel/a",Items:[{Id:"item-a",Name:"A",Text:"first",Slot:1}]},
    {Id:"context-b",Name:"B",Channel:"/channel/b",Items:[{Id:"item-b",Name:"B",Text:"second",Slot:1}]}]
state.SharedDanmakuItems := [{Id:"item-shared",Name:"Shared",Text:"shared",Slot:1}]
state.InputProfileId := "context-a"
OpenSettingsRepository(SettingsDatabasePath).SaveAll(state)
ReloadAppSettings()
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.ResolveChannel := ResolveContextFixture
RuntimePorts.BrowserRequest := ReadContextFixture
global ContextReply := {State:"ok",Channel:"/channel/a",Author:"A",Video:"aaaaaaaaaaa"}
; No window is created. This property injects a replacement at the presentation boundary.
global PaletteWindow := {}
PaletteWindow.DefineProp("Hwnd",{Get:ContextPresentationBoundary})
for route in ["shortcut","palette"] {
    for reentry in [false,true] {
        SaveInputProfileId("context-a")
        ContextCalls := 0, ContextReentry := reentry
        plan := route="shortcut" ? ResolveShortcutInput("profile",1,123)
            : ResolveDanmakuInput({ProfileId:"context-a",ItemId:"item-a",ExpectedText:"first",Window:123})
        Assert(ContextCalls=1 && !ContextReentry,"automatic input resolves once before presentation")
        Assert(plan.ProfileId=="context-a" && plan.Video=="aaaaaaaaaaa" && plan.Window=123
            && plan.ItemId=="item-a" && plan.Text=="first","input retains the resolved profile, video and item across presentation")
        if reentry
            Assert(InputProfileId=="context-b" && DetectedChannel.Video=="bbbbbbbbbbb",
                "presentation actually replaces both shared selection and detection state")
    }
}
for reply in [{State:"unavailable",Channel:"",Author:"",Video:""},
    {State:"ok",Channel:"/channel/missing",Author:"Missing",Video:"mmmmmmmmmmm"},
    Error("lookup failed")] {
    ContextReply := reply, ContextCalls := 0
    SaveInputProfileId("context-a")
    Assert(!ResolveShortcutInput("profile",1,123) && ContextCalls=1 && InputProfileId=="context-a",
        "failed or unmatched automatic detection never creates a plan or changes saved selection")
    if reply is Error
        Assert(DetectedChannel.State="unavailable" && InStr(DetectionMessage,"lookup failed"),
            "lookup exception retains an unavailable display state and its cause")
}
ContextReply := {State:"ok",Channel:"/channel/b",Author:"B",Video:"bbbbbbbbbbb"}
SaveInputProfileId("context-a")
originalPath := SettingsDatabasePath
SettingsDatabasePath := A_ScriptDir "\missing\settings.db"
; Force a selection write to fail; an unsaved selection cannot become an input plan.
Assert(!ResolveShortcutInput("profile",1,123) && InputProfileId=="context-a"
    && InStr(DetectionMessage,"配信者を選択できません"),"failed selection save prevents an automatic input plan")
SettingsDatabasePath := originalPath
Assert(LoadSettings(SettingsDatabasePath).InputProfileId=="context-a","failed selection save preserves the stored selection")
ContextReply := {State:"ok",Video:"aaaaaaaaaaa"}
AutoMode := false, ContextCalls := 0
plan := ResolveShortcutInput("profile",1,123)
Assert(plan.ProfileId=="context-a" && plan.ItemId=="item-a" && plan.Video=="aaaaaaaaaaa" && ContextCalls=1,
    "manual selection resolves its video without requiring channel metadata")
AutoMode := true, ContextCalls := 0
plan := ResolveShortcutInput("shared",1,123)
Assert(plan.ProfileId=="" && plan.ItemId=="item-shared" && plan.Text=="shared" && ContextCalls=1,
    "shared input does not depend on an automatic profile match")
FileAppend("PASS: " Checks " input context checks; no windows, browser or input operations`n","*")
ExitApp()
ResolveContextFixture(hwnd) {
    global ContextCalls
    ContextCalls++
    if ContextReply is Error
        throw ContextReply
    return ContextReply
}
ReadContextFixture(hwnd,mode,video,extra) {
    Assert(mode="browser_context","manual and shared inputs request only the current video")
    return ResolveContextFixture(hwnd)
}
ContextPresentationBoundary(*) {
    global ContextReentry, DetectedChannel
    if ContextReentry {
        ContextReentry := false
        SaveInputProfileId("context-b")
        DetectedChannel := {State:"ok",Channel:"/channel/b",Author:"B",Video:"bbbbbbbbbbb"}
    }
    return 0
}
'@
Invoke-AhkTest -Runtime $runtime -Source $source
