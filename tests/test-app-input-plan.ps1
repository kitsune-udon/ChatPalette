# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    ; Resolve an assignment once and pin the resulting video/text for delivery.
    fixtureLibrary := {Profiles:[
        {Id:"input-a",Name:"A",Channel:"/channel/a",Items:[{Id:"fixture-a2",Name:"A2",Text:"A-two",Slot:2},{Id:"fixture-a1",Name:"A1",Text:"A-one",Slot:1}]},
        {Id:"input-b",Name:"B",Channel:"/channel/b",Items:[{Id:"fixture-b1",Name:"B1",Text:"B-one",Slot:1},{Id:"fixture-b2",Name:"B2",Text:"B-two",Slot:2}]}],SharedDanmakuItems:[]}
    CommitTestLibraryChange(fixtureLibrary,"input fixture")
    global FixtureResolveCount := 0, FixtureCurrentVideo := "aaaaaaaaaaa", FixtureSent := []
    RuntimePorts.ResolveChannel := ResolveInputPlanChannel
    RuntimePorts.VerifyInput := (hwnd,video) => video == FixtureCurrentVideo
    RuntimePorts.Text := (text) => FixtureSent.Push(text)
    AutoMode := true
    plan := ResolveShortcutInput("profile",1,123)
    Assert(FixtureResolveCount=1 && plan.Text="A-one" && plan.Video="aaaaaaaaaaa","shortcut resolves profile and slot exactly once")
    FixtureCurrentVideo := "bbbbbbbbbbb"
    Assert(DeliverDanmakuInput(plan).State="input_cancelled" && FixtureSent.Length=0,"video change after resolving prevents any input")
    Assert(FixtureResolveCount=1,"delivery never re-resolves profile or list index")
    FixtureCurrentVideo := "aaaaaaaaaaa"
    Assert(DeliverDanmakuInput(plan).State="inserted" && FixtureSent[1]="A-one","unchanged target delivers the frozen text")
    Assert(DeliverDanmakuInput(plan,true).State="input_cancelled" && FixtureSent.Length=1,"closed palette target returns input failure without typing")
    rejected := false
    try ResolveDanmakuInput({ProfileId:"input-b",ItemId:Profiles[2].Items[1].Id,ExpectedText:"B-one",Window:123,Origin:"palette"})
    catch
        rejected := true
    Assert(rejected,"palette selection refuses changed profile identity")

    context := {ProfileId:"input-a",Window:123,Video:"aaaaaaaaaaa"}
    request := {ProfileId:"input-a",ItemId:Profiles[1].Items[2].Id,ExpectedText:"A-one",Window:123,Origin:"palette"}
    ExecuteDanmakuCommand("up","input-a",request.ItemId)
    Assert(PlanDanmakuInput(request,context).Text="A-one","reordered rows resolve the selected identity")
    ExecuteDanmakuCommand("edit","input-a",request.ItemId,{Name:"A1",Text:"a-one",Slot:1})
    rejected := false
    try PlanDanmakuInput(request,context)
    catch
        rejected := true
    Assert(rejected,"even case-only text edits invalidate displayed content")
    ExecuteDanmakuCommand("delete","input-a",request.ItemId)
    ExecuteDanmakuCommand("add","input-a","",{Name:"A1",Text:"A-one",Slot:1})
    rejected := false
    try PlanDanmakuInput(request,context)
    catch
        rejected := true
    Assert(rejected,"a replacement with identical text cannot reuse the selected identity")
    plan := ResolveShortcutInput("profile",1,123)
    global PartialInputAttempts := 0
    RuntimePorts.Text := PartialInputFailure
    FixtureSent := [], escaped := false
    try RunDanmakuInput(() => plan,"shortcut")
    catch
        escaped := true
    Assert(!escaped && PartialInputAttempts=1 && FixtureSent.Length=1,"partial input failure is handled without replay")
    Assert(InStr(PaletteHint.Text,"結果を確認できません") && InStr(PaletteHint.Text,"自動では再実行しません"),"partial input failure is reported as unknown rather than not typed")
'@ -Helpers @'
ResolveInputPlanChannel(hwnd) {
    global FixtureResolveCount
    FixtureResolveCount++
    return {State:"ok",Author:"A",Channel:"/channel/a",Video:"aaaaaaaaaaa"}
}
PartialInputFailure(text) {
    global PartialInputAttempts
    PartialInputAttempts++
    FixtureSent.Push(SubStr(text,1,2))
    throw Error("Synthetic failure after partial input")
}
'@

# Resolution and final verification failures use one user-facing input boundary.
Invoke-AppFixture -Body @'
    global InputFailureMode := "", InputRequests := [], InputSent := []
    RuntimePorts.WorkerRequest := InputBoundaryRequest
    RuntimePorts.Text := (text) => InputSent.Push(text)
    BuildManagement()
    for mode in ["browser_context","verify_input"] {
        InputFailureMode := mode, InputRequests := [], InputSent := []
        PaletteHint.Text := "previous message", escaped := false
        try RequestShortcutInput("shared",1,123)
        catch
            escaped := true
        Assert(!escaped,"input boundary handles " mode " failure without an unhandled exception")
        Assert(InputSent.Length=0 && InputRequests.Length=(mode="browser_context" ? 1 : 2),mode ": failed verification does not type or retry")
        Assert(PaletteHint.Text="Synthetic input failure: " mode,mode ": the observed failure reaches the existing input guidance")
        Assert(!IsBrowserOperationBusy && OperationAllowed("input"),mode ": failed input releases the browser gate")
        Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),mode ": failed input restores both parent windows")
        InputFailureMode := "", InputRequests := []
        RequestShortcutInput("shared",1,123)
        Assert(InputRequests.Length=2 && InputSent.Length=1 && InputSent[1]==SharedDanmakuItems[1].Text,mode ": a new request succeeds once after recovery")
    }
'@ -Helpers @'
InputBoundaryRequest(hwnd,mode,video,extra) {
    InputRequests.Push(mode)
    if mode=InputFailureMode
        throw Error("Synthetic input failure: " mode)
    return {State:"ok",Video:"abcdefghijk"}
}
'@

# Native column sorting changes display positions while saved item identities stay fixed.
Invoke-AppFixture -Body @'
    fixtureLibrary := {Profiles:[{Id:"sort-profile",Name:"sort profile",Channel:"",Items:[
        {Id:"profile-z",Name:"Z",Text:"profile-z",Slot:1},
        {Id:"case-item",Name:"Same",Text:"same",Slot:2}]}],SharedDanmakuItems:[
        {Id:"shared-a",Name:"A",Text:"shared-a",Slot:2},
        {Id:"CASE-ITEM",Name:"Same",Text:"same",Slot:1}]}
    CommitTestLibraryChange(fixtureLibrary,"sorted palette fixture")
    AutoMode := false
    SaveInputProfileId("sort-profile")
    expected := Map(), expected.CaseSense := "On"
    for profile in fixtureLibrary.Profiles
        for index,item in profile.Items
            expected[item.Id] := {ProfileId:profile.Id,Index:index,Name:item.Name,Text:item.Text}
    for index,item in fixtureLibrary.SharedDanmakuItems
        expected[item.Id] := {ProfileId:"",Index:index,Name:item.Name,Text:item.Text}
    browser := Gui(,"isolated palette input target")
    browser.AddEdit("w320","fixture")
    PresentWindow(browser,"",0,false)
    TargetBrowserHwnd := browser.Hwnd
    sent := [], foregroundChecks := []
    RuntimePorts.BrowserIdentity := (hwnd) => hwnd=browser.Hwnd
    RuntimePorts.BrowserRequest := (hwnd,mode,video,extra) => {State:"ok",Video:"abcdefghijk"}
    RuntimePorts.VerifyInput := (hwnd,video) => hwnd=browser.Hwnd && video=="abcdefghijk"
    ; Retain the exact observation used by delivery; a later foreground read can differ.
    RuntimePorts.Foreground := (hwnd) => (foregroundChecks.Push(!!WinActive("ahk_id " hwnd)), foregroundChecks[-1])
    RuntimePorts.Text := (text) => sent.Push(text)
    RefreshPalette()
    for ordering in [[2,"Sort"],[2,"SortDesc"],[1,"Sort"],[3,"SortDesc"]] {
        PaletteList.ModifyCol(ordering[1],ordering[2])
        Loop PaletteList.GetCount() {
            index := A_Index, id := PaletteList.GetText(index,4), item := expected[id]
            PaletteList.Modify(0,"-Select"), PaletteList.Modify(index,"Select Focus")
            PreviewPaletteItem()
            Assert(PaletteList.GetText(index,1)==(item.ProfileId="" ? "共通" : "配信者")
                && PaletteList.GetText(index,2)==item.Name "　" item.Text,"sorted row displays the matching scope, name and text " id)
            Assert(PalettePreview.Text==item.Text,"sorted preview matches visible identity " id)
            OpenPaletteLibrary()
            Assert(GetEditingProfileId()==item.ProfileId && ManagedList.GetNext()=item.Index
                && ManagedList.GetText(ManagedList.GetNext(),4)==id,"sorted selection opens the matching library item " id)
            Assert(InputProfileId=="sort-profile","opening sorted shared/profile items preserves the input profile")
            before := sent.Length, foregroundChecks.Length := 0
            InsertPaletteItem()
            Assert(sent.Length=before+1 && sent[-1]==item.Text,"sorted input sends exactly the displayed item " id
                . " (sent=" (sent.Length-before) ", foreground_checks=" foregroundChecks.Length
                . ", last_foreground=" (foregroundChecks.Length ? foregroundChecks[-1] : "unobserved")
                . ", hint=" PaletteHint.Text ")")
        }
    }
    ; A visible row with no published backing identity must not use its position.
    PaletteList.Modify(0,"-Select"), PaletteList.Modify(1,"Select Focus")
    PaletteList.Modify(1,"Col4","unpublished-item")
    PreviewPaletteItem()
    Assert(!PaletteInsert.Enabled && PalettePreview.Text="","unknown displayed identity clears preview and disables input")
    before := sent.Length
    InsertPaletteItem()
    Assert(sent.Length=before,"unknown displayed identity never inputs a neighbouring item")
    Assert(GetPaletteLibraryTarget().Index=0,"unknown displayed identity does not open a neighbouring editor item")
    RuntimePorts.BrowserIdentity := 0, RuntimePorts.BrowserRequest := 0, RuntimePorts.VerifyInput := 0
    RuntimePorts.Foreground := 0, RuntimePorts.Text := 0
    browser.Destroy()
'@

# Delivery checks the real foreground, including a change during final identity validation.
Invoke-AppFixture -Body @'
    global DeliveryBrowser := Gui(,"isolated delivery target"), DeliveryOther := Gui(,"isolated other window")
    DeliveryBrowser.AddEdit("w240","fixture"), DeliveryOther.AddEdit("w240","fixture")
    DeliveryBrowser.Show(), DeliveryOther.Show()
    global DeliveryCase := "", DeliveryCalls := 0, DeliverySent := [], DeliveryValidationArmed := false
    RuntimePorts.Foreground := 0
    RuntimePorts.BrowserRequest := DeliveryRequest
    RuntimePorts.Text := (text) => DeliverySent.Push(text)
    ExecuteDanmakuCommand("add","","",{Name:"literal",Text:"literal 👏",Slot:1})
    for item in SharedDanmakuItems
        if item.Slot=1
            deliveryItem := item
    deliveryItem.DefineProp("Text",{Get:DeliveryItemText})
    for adapter in ["native","port"] {
        RuntimePorts.VerifyInput := adapter = "native" ? 0 : DeliveryVerify
        for scenario in ["before","during","validation","video","field","success","empty-expected"] {
            DeliveryCase := scenario, DeliveryCalls := 0, DeliverySent := [], DeliveryValidationArmed := false
            ActivateDeliveryWindow(scenario = "before" ? DeliveryOther.Hwnd : DeliveryBrowser.Hwnd)
            video := scenario = "empty-expected" ? "" : "abcdefghijk"
            plan := PlanDanmakuInput({ProfileId:"",ItemId:deliveryItem.Id,ExpectedText:deliveryItem.Text},
                {ProfileId:"",Window:DeliveryBrowser.Hwnd,Video:video})
            result := DeliverDanmakuInput(plan)
            succeeds := scenario = "success" || scenario = "empty-expected"
            Assert(result.State = (succeeds ? "inserted" : "input_cancelled") && DeliverySent.Length = (succeeds ? 1 : 0),adapter "/" scenario ": delivery honors foreground and verification")
            Assert(DeliveryCalls = (scenario = "before" ? 0 : 1),adapter "/" scenario ": no verification in background and no replay")
            if succeeds
                Assert(DeliverySent[1] == "literal 👏",adapter "/" scenario ": delivers the frozen literal text")
        }
    }
    DeliveryBrowser.Destroy(), DeliveryOther.Destroy()
'@ -Helpers @'
ActivateDeliveryWindow(hwnd) {
    WinActivate("ahk_id " hwnd)
    RequireTestWindowActive(hwnd)
}
DeliveryRequest(hwnd,mode,video,extra) {
    global DeliveryCalls, DeliveryValidationArmed
    if hwnd != DeliveryBrowser.Hwnd || mode != "verify_input"
        throw Error("Unexpected delivery verification request")
    DeliveryCalls++
    DeliveryValidationArmed := DeliveryCase="validation"
    if DeliveryCase = "during"
        ActivateDeliveryWindow(DeliveryOther.Hwnd)
    return {State:DeliveryCase = "field" ? "wrong_input" : "ok", Video:DeliveryCase = "video" ? "ABCDEFGHIJK" : "abcdefghijk"}
}
DeliveryItemText(item) {
    global DeliveryValidationArmed
    if DeliveryValidationArmed {
        DeliveryValidationArmed := false
        ActivateDeliveryWindow(DeliveryOther.Hwnd)
    }
    return "literal 👏"
}
DeliveryVerify(hwnd,video) {
    DeliveryRequest(hwnd,"verify_input",video,"")
    return DeliveryCase != "video" && DeliveryCase != "field"
}
'@

# Both input paths keep the selected identity through browser verification.
Invoke-AppFixture -Body @'
    global InputChange := "", InputScope := "", InputSelected := 0, InputSent := [], InputChecks := 0, InputForeground := true
    AutoMode := false
    RuntimePorts.BrowserRequest := IdentityRequest
    RuntimePorts.VerifyInput := IdentityVerify
    RuntimePorts.Foreground := (hwnd) => InputForeground && hwnd=123
    RuntimePorts.ShortcutRelease := (*) => true
    RuntimePorts.Text := (text) => InputSent.Push(text)
    fixture := {Profiles:[{Id:"delivery-profile",Name:"profile",Channel:"",Items:[
        {Id:"delivery-profile-first",Name:"first",Text:"Selected draft",Slot:1},
        {Id:"delivery-profile-other",Name:"other",Text:"Other draft",Slot:2}]}],SharedDanmakuItems:[
        {Id:"delivery-shared-first",Name:"first",Text:"Selected draft",Slot:1},
        {Id:"delivery-shared-other",Name:"other",Text:"Other draft",Slot:2}]}
    for route in ["shortcut","focused"] {
        for scope in ["shared","profile"] {
            InputScope := scope
            for change in ["text","delete","replace","move","reorder","rename","slot","slot_before_plan","validation_foreground"] {
                InputChange := change, InputSent := [], InputChecks := 0, InputForeground := true
                CommitTestLibraryChange(fixture,"input identity fixture")
                SaveInputProfileId("delivery-profile")
                profileId := scope="shared" ? "" : "delivery-profile"
                InputSelected := GetLibraryItems(fixture,profileId)[1]
                if route="shortcut"
                    RequestShortcutInput(scope,1,123)
                else
                    RunPageAction("chat_focus",123)
                succeeds := change="reorder" || change="rename" || change="slot" || change="slot_before_plan"
                label := route "/" scope "/" change
                Assert(InputChecks=1,label ": verifies the browser exactly once")
                Assert(InputSent.Length=(succeeds ? 1 : 0),label ": rejects changed identity or text without sending")
                if succeeds {
                    expected := route="shortcut" && change="slot_before_plan" ? "Other draft" : "Selected draft"
                    Assert(InputSent[1]==expected,label ": selection uses the intended library snapshot")
                }
            }
        }
    }
'@ -Helpers @'
IdentityRequest(hwnd,mode,video,extra) {
    if mode="chat_focus" {
        QueueFocusedDanmaku(InputScope,1,hwnd)
        return {State:"focused",Video:"abcdefghijk",Detail:"identity-proof"}
    }
    if mode="browser_context" {
        if InputChange="slot_before_plan" {
            profileId := InputScope="shared" ? "" : "delivery-profile"
            other := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},profileId)[2]
            SaveShortcutItemAssignments(profileId,other.Id,"")
        }
        return {State:"ok",Video:"abcdefghijk"}
    }
    if mode="verify_chat" {
        IdentityVerify(hwnd,video)
        return {State:"ok",Video:video}
    }
    throw Error("Unexpected input identity request")
}
IdentityItemText(item) {
    global InputForeground := false
    item.DefineProp("Text",{Value:InputSelected.Text})
    return InputSelected.Text
}
IdentityVerify(hwnd,video) {
    global InputChecks
    InputChecks++
    profileId := InputScope="shared" ? "" : "delivery-profile"
    switch InputChange {
        case "validation_foreground":
            items := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},profileId)
            items[1].DefineProp("Text",{Get:IdentityItemText})
        case "text":
            ExecuteDanmakuCommand("edit",profileId,InputSelected.Id,{Name:"first",Text:"selected draft",Slot:1})
        case "delete", "replace":
            ExecuteDanmakuCommand("delete",profileId,InputSelected.Id)
            if InputChange="replace"
                ExecuteDanmakuCommand("add",profileId,"",{Name:"first",Text:InputSelected.Text,Slot:1})
        case "move":
            ExecuteDanmakuCommand("move",profileId,InputSelected.Id,0,profileId="" ? "delivery-profile" : "")
        case "reorder":
            ExecuteDanmakuCommand("down",profileId,InputSelected.Id)
        case "rename":
            ExecuteDanmakuCommand("edit",profileId,InputSelected.Id,{Name:"renamed",Text:InputSelected.Text,Slot:1})
        case "slot":
            other := GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},profileId)[2]
            ExecuteDanmakuCommand("edit",profileId,other.Id,{Name:other.Name,Text:other.Text,Slot:1})
    }
    return true
}
'@

# Final delivery must respect operations that became active after planning.
Invoke-AppFixture -Body @'
    global InputGate := "", GateOwner := 0, GateSent := [], GateChecks := 0
    RuntimePorts.BrowserRequest := GateRequest
    RuntimePorts.VerifyInput := 0
    RuntimePorts.ShortcutRelease := (*) => true
    RuntimePorts.Text := (text) => GateSent.Push(text)
    for route in ["shortcut","focused"] {
        for gate in ["editor","reaction","page","busy"] {
            InputGate := gate, GateSent := [], GateChecks := 0, GateOwner := {Window:123,Label:"input gate fixture"}
            try {
                if route="shortcut"
                    RequestShortcutInput("shared",1,123)
                else
                    RunPageAction("chat_focus",123)
                label := route "/" gate
                Assert(GateChecks=1,label ": target verification actually reaches the competing operation")
                Assert(!GateSent.Length,label ": active operation prevents the planned send")
                Assert((gate="editor" && ActiveEditorDialog=GateOwner) || (gate="reaction" && ActiveReactionJob=GateOwner)
                    || (gate="page" && ActivePageAction=GateOwner) || (gate="busy" && IsBrowserOperationBusy),
                    label ": cancelled input preserves the competing owner")
            } finally {
                ActiveEditorDialog := 0, ActiveReactionJob := 0, ActivePageAction := 0, IsBrowserOperationBusy := false
            }
        }
    }
'@ -Helpers @'
GateRequest(hwnd,mode,video,extra) {
    global GateChecks, ActiveEditorDialog, ActiveReactionJob, ActivePageAction, IsBrowserOperationBusy
    if mode="chat_focus" {
        QueueFocusedDanmaku("shared",1,hwnd)
        return {State:"focused",Video:"abcdefghijk",Detail:"gate-proof"}
    }
    if mode="browser_context"
        return {State:"ok",Video:"abcdefghijk"}
    if mode!="verify_input" && mode!="verify_chat"
        throw Error("Unexpected input gate request")
    GateChecks++
    switch InputGate {
        case "editor": ActiveEditorDialog := GateOwner
        case "reaction": ActiveReactionJob := GateOwner
        case "page": ActivePageAction := GateOwner
        case "busy": IsBrowserOperationBusy := true
    }
    return {State:"ok",Video:"abcdefghijk"}
}
'@
