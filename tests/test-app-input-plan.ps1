# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    ; Resolve an assignment once and pin the resulting video/text for delivery.
    fixtureLibrary := {Profiles:[
        {Id:"input-a",Name:"A",Channel:"/channel/a",Items:[{Name:"A2",Text:"A-two",Slot:2},{Name:"A1",Text:"A-one",Slot:1}]},
        {Id:"input-b",Name:"B",Channel:"/channel/b",Items:[{Name:"B1",Text:"B-one",Slot:1},{Name:"B2",Text:"B-two",Slot:2}]}],SharedDanmakuItems:[]}
    CommitLibraryChange(fixtureLibrary,"input fixture")
    global FixtureInputMode := true, FixtureResolveCount := 0, FixtureCurrentVideo := "aaaaaaaaaaa", FixtureSent := []
    AutoMode := true
    plan := ResolveShortcutInput("profile",1,123)
    Assert(FixtureResolveCount=1 && plan.Text="A-one" && plan.Video="aaaaaaaaaaa","shortcut resolves profile and slot exactly once")
    FixtureCurrentVideo := "bbbbbbbbbbb"
    Assert(!DeliverText(plan.Text,plan.Window,plan.Video) && FixtureSent.Length=0,"video change after resolving prevents any input")
    Assert(FixtureResolveCount=1,"delivery never re-resolves profile or list index")
    FixtureCurrentVideo := "aaaaaaaaaaa"
    Assert(DeliverText(plan.Text,plan.Window,plan.Video) && FixtureSent[1]="A-one","unchanged target delivers the frozen text")
    Assert(!DeliverText(plan.Text,plan.Window,plan.Video,true) && FixtureSent.Length=1,"closed palette target returns input failure without typing")
    rejected := false
    try ResolveDanmakuInput({ProfileId:"input-b",ItemId:Profiles[2].Items[1].Id,ExpectedText:"B-one",Window:123,Origin:"palette"})
    catch
        rejected := true
    Assert(rejected,"palette selection refuses changed profile identity")

    context := {ProfileId:"input-a",Window:123,Video:"aaaaaaaaaaa"}
    request := {ProfileId:"input-a",ItemId:Profiles[1].Items[2].Id,ExpectedText:"A-one",Window:123,Origin:"palette"}
    ExecuteDanmakuCommand("up","input-a",2)
    Assert(PlanDanmakuInput(request,context).Text="A-one","reordered rows resolve the selected identity")
    ExecuteDanmakuCommand("edit","input-a",1,{Name:"A1",Text:"a-one",Slot:1})
    rejected := false
    try PlanDanmakuInput(request,context)
    catch
        rejected := true
    Assert(rejected,"even case-only text edits invalidate displayed content")
    ExecuteDanmakuCommand("delete","input-a",1)
    ExecuteDanmakuCommand("add","input-a",0,{Name:"A1",Text:"A-one",Slot:1})
    rejected := false
    try PlanDanmakuInput(request,context)
    catch
        rejected := true
    Assert(rejected,"a replacement with identical text cannot reuse the selected identity")
    FixtureInputMode := false
'@
