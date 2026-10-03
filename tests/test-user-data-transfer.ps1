# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
$jsonRuntime = New-TestRuntime
Invoke-AppFixture -Runtime $jsonRuntime -Body @'
    repository := OpenSettingsRepository(SettingsDatabasePath), db := repository.Db
    tokens := "["
    Loop 5
        tokens .= (A_Index>1 ? "," : "") '{"name":"👏' A_Index '","id":"id' A_Index '","class":"button","type":50000}'
    tokens .= "]"
    SaveReactionRegistration('{"browser":"fixture","tokens":' tokens '}')
    original := ReadStoredUserData(SettingsDatabasePath)
    exportPath := A_ScriptDir "\日本語 export.json"
    ExportUserData(exportPath)
    exported := ReadUserData(exportPath)
    VerifySettingsRoundTrip(original.State,exported.State)
    Assert(exported.Registrations.Length=1 && exported.Registrations[1]==original.Registrations[1],"export includes exact registration tokens")
    bytes := FileRead(exportPath,"RAW")
    rejected := false
    try ExportUserData(exportPath)
    catch
        rejected := true
    Assert(rejected && SameBytes(bytes,FileRead(exportPath,"RAW")),"existing export is never overwritten")
    FileSetAttrib("+R",exportPath)
    try ReadUserData(exportPath)
    finally FileSetAttrib("-R",exportPath)
    Assert(SameBytes(bytes,FileRead(exportPath,"RAW")),"reading a readonly export preserves source bytes")

    ; Import must replace all categories and be reversible using the automatic backup.
    changed := CreateDefaultSettings()
    changed.AutoMode := 0, changed.DefaultReactionCount := 100, changed.DefaultReactionKind := 3
    changed.DefaultReactionIntervalMs := 0, changed.ShortcutKeys["reaction"] := "^+r"
    changed.Profiles := [{Id:"other",Name:"別の配信者",Channel:"/channel/other",Items:[]}]
    changed.InputProfileId := "other"
    changed.SharedDanmakuItems := [{Id:"new",Name:"日本語 🎉",Text:"引用 `" と \\ と 👏",Slot:2}]
    source := SettingsRepository(A_ScriptDir "\other.db",true)
    source.SaveAll(changed), source.Close()
    incoming := ReadStoredUserData(A_ScriptDir "\other.db")
    LibraryHistory.Push({Label:"old history"})
    WorkerState.RegistrationsSynchronized := true
    backup := A_ScriptDir "\before.db"
    ImportUserData(incoming,backup)
    VerifySettingsRoundTrip(changed,ReadStoredUserData(SettingsDatabasePath).State)
    VerifySettingsRoundTrip(original.State,ReadUserData(backup).State)
    Assert(Profiles[1].Id="other" && SharedDanmakuItems[1].Slot=2 && GetShortcutKey("reaction")="^+r" && AutoMode=0,"import publishes library, keys and preferences")
    Assert(!LibraryHistory.Length && !WorkerState.RegistrationsSynchronized && !HasReactionRegistration("fixture"),"import clears undo and obsolete registration cache/data")
    BuildManagement()
    PaletteSearch.Value := "stale search", EditingProfileId := "fixture-profile"
    RefreshImportedUserData(), RefreshPalette()
    Assert(PaletteSearch.Value="" && EditingProfileId="" && PaletteList.GetCount()=1 && PaletteChoice.Value=3,"import refreshes actual controls and resets stale selections")
    Assert(ReactionDefaultCountControl.Text="100回","management defaults refreshed")
    ImportUserData(ReadUserData(backup),A_ScriptDir "\before-restore.db")
    VerifySettingsRoundTrip(original.State,ReadStoredUserData(SettingsDatabasePath).State)
    Assert(HasReactionRegistration("fixture"),"automatic backup restores removed registrations")
    ImportUserData(ReadStoredUserData(SettingsDatabasePath),A_ScriptDir "\same-file.db")
    VerifySettingsRoundTrip(original.State,ReadStoredUserData(SettingsDatabasePath).State)
    Assert(true,"same-file snapshot imports safely")

    ; A failed backup, key registration or database commit preserves all live/durable state.
    LibraryHistory.Push({Label:"must survive"}), WorkerState.RegistrationsSynchronized := true
    before := ReadStoredUserData(SettingsDatabasePath), live := Profiles, baseline := repository.Saved
    rejected := false
    try ImportUserData(incoming,A_ScriptDir "\missing\backup.db")
    catch
        rejected := true
    Assert(rejected,"failed backup aborts import")
    global ImportBindingCalls := []
    RuntimePorts.ShortcutKey := RejectImportedKey
    rejected := false
    try ImportUserData(incoming,A_ScriptDir "\key-failure.db")
    catch
        rejected := true
    Assert(rejected && GetShortcutKey("reaction")==before.State.ShortcutKeys["reaction"],"key registration failure preserves published keys")
    Assert(ImportBindingCalls.Length=3 && !ImportBindingCalls[1].Enabled && ImportBindingCalls[2].Key="^+r"
        && ImportBindingCalls[3].Enabled && ImportBindingCalls[3].Key==before.State.ShortcutKeys["reaction"],"failed imported key registration restores the previous native binding")
    ImportBindingCalls := []
    RuntimePorts.ShortcutKey := (action,key,enabled) => ImportBindingCalls.Push({Key:key,Enabled:enabled})
    db.Exec("CREATE TRIGGER fail_import BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT,'fixture import failure'); END")
    rejected := false
    try ImportUserData(incoming,A_ScriptDir "\save-failure.db")
    catch
        rejected := true
    db.Exec("DROP TRIGGER fail_import")
    Assert(ImportBindingCalls.Length=4 && !ImportBindingCalls[1].Enabled && ImportBindingCalls[2].Enabled
        && ImportBindingCalls[2].Key="^+r" && !ImportBindingCalls[3].Enabled && ImportBindingCalls[3].Key="^+r"
        && ImportBindingCalls[4].Enabled && ImportBindingCalls[4].Key==before.State.ShortcutKeys["reaction"],"failed import persistence removes the new native binding and restores the old binding")
    RuntimePorts.ShortcutKey := (*) => 0
    Assert(rejected && Profiles=live && repository.Saved=baseline && LibraryHistory.Length=1 && WorkerState.RegistrationsSynchronized,"failed transaction preserves live state and saved baseline/history/cache")
    after := ReadStoredUserData(SettingsDatabasePath)
    VerifySettingsRoundTrip(before.State,after.State)
    Assert(after.Registrations[1]==before.Registrations[1],"failed transaction rolls back deleted registrations")
    contender := SqliteConnection(SettingsDatabasePath)
    contender.Exec("UPDATE preferences SET auto_mode=0"), contender.Close()
    rejected := false
    try ImportUserData(incoming,A_ScriptDir "\conflict.db")
    catch
        rejected := true
    Assert(rejected && !FileExist(A_ScriptDir "\conflict.db"),"external writer conflict stops import before backup")
    ReloadAppSettings()

    ; Reject bad input without any source or target modification.
    for sql in ["PRAGMA user_version=3", "PRAGMA application_id=0", "DELETE FROM preferences",
        "UPDATE reaction_registrations SET browser='Fixture'",
        "UPDATE reaction_registrations SET payload='{}'",
        "UPDATE items SET body=char(0)||'hidden'",
        "UPDATE reaction_registrations SET payload=json_set(payload,'$.tokens[0].type',1)"] {
        invalidPath := A_ScriptDir "\invalid-" A_Index ".db"
        seed := SettingsRepository(invalidPath,true)
        ReplaceStoredUserData(seed,original), seed.Close()
        invalid := SqliteConnection(invalidPath)
        invalid.Exec(sql), invalid.Close()
        invalidBytes := FileRead(invalidPath,"RAW"), rejected := false
        try ReadStoredUserData(invalidPath)
        catch
            rejected := true
        Assert(rejected && SameBytes(invalidBytes,FileRead(invalidPath,"RAW")),"invalid source rejected unchanged: " sql)
    }
    FileAppend("not a database",A_ScriptDir "\corrupt.db")
    for path in [A_ScriptDir "\corrupt.db",A_ScriptDir "\absent.db"] {
        rejected := false
        try ReadUserData(path)
        catch
            rejected := true
        Assert(rejected,"corrupt or absent source rejected")
    }
    Assert(!FileExist(A_ScriptDir "\absent.db"),"import never creates missing source")
    empty := SettingsRepository(A_ScriptDir "\empty.db",true)
    empty.SaveAll(CreateDefaultSettings()), empty.Close()
    ImportUserData(ReadStoredUserData(A_ScriptDir "\empty.db"),A_ScriptDir "\before-empty.db")
    Assert(!Profiles.Length && !SharedDanmakuItems.Length && !HasReactionRegistration("fixture"),"empty export intentionally replaces existing data")
    Assert(BeginSettingsTransfer() && !OperationAllowed("edit") && !OperationAllowed("preferences") && !OperationAllowed("reaction") && !OperationAllowed("input"),"transfer gate prevents edits and browser operations")
    Assert(!BeginSettingsTransfer(),"nested transfer refused")
    EndSettingsTransfer()
    Assert(OperationAllowed("edit"),"gate releases after transfer")
    ActiveEditorDialog := {Label:"draft"}
    Assert(!BeginSettingsTransfer() && !SettingsTransferActive,"open editor blocks transfer")
    ActiveEditorDialog := 0
'@ -Helpers @'
SameBytes(a,b) {
    return a.Size=b.Size && DllCall("msvcrt\memcmp","Ptr",a,"Ptr",b,"UPtr",a.Size,"CDecl Int")=0
}
RejectImportedKey(action,key,enabled) {
    ImportBindingCalls.Push({Key:key,Enabled:enabled})
    if enabled && key="^+r"
        throw Error("fixture key failure")
}
'@
$externalJson = [IO.File]::ReadAllText((Join-Path $jsonRuntime '日本語 export.json')) | ConvertFrom-Json
Assert ($externalJson.format -ceq 'ChatPalette' -and $externalJson.version -eq 2) 'External JSON parser recognizes format/version'
Assert ($externalJson.profiles[0].items.Count -eq 2 -and $externalJson.sharedItems[0].text -eq '👏👏👏👏👏👏') 'External JSON parser reads ordered items and Unicode'
Write-Output 'PASS: 2 external JSON interoperability checks'

# Exercise the menu callbacks with native dialogs replaced; real persistence and GUI controls remain.
$runtime = New-TestRuntime
Edit-TestSource $runtime 'src/app/app_lifecycle.ahk' 'FileSelect(' 'SelectTransferFixture('
Edit-TestSource $runtime 'src/app/app_lifecycle.ahk' 'MsgBox(' 'MessageTransferFixture('
Edit-TestSource $runtime 'src/app/app_lifecycle.ahk' 'try RefreshImportedUserData()' 'try RefreshTransferFixture()'
Invoke-AppFixture -Runtime $runtime -Body @'
    global TransferSelection := "", TransferAnswer := "No", TransferMessages := [], FailTransferRefresh := false
    original := ReadStoredUserData(SettingsDatabasePath)
    ImportSettingsBackup()
    Assert(!SettingsTransferActive && !TransferMessages.Length,"file picker cancellation releases gate silently")
    TransferSelection := A_ScriptDir "\menu-export"
    ExportSettingsBackup()
    Assert(FileExist(TransferSelection ".json") && !SettingsTransferActive,"export callback appends extension and releases gate")
    TransferSelection .= ".json"
    VerifySettingsRoundTrip(original.State,ReadUserData(TransferSelection).State)
    empty := SettingsRepository(A_ScriptDir "\menu-empty.db",true)
    empty.SaveAll(CreateDefaultSettings()), empty.Close()
    WriteUserData(ReadStoredUserData(A_ScriptDir "\menu-empty.db"),A_ScriptDir "\menu-empty.json")
    TransferSelection := A_ScriptDir "\menu-empty.json"
    ImportSettingsBackup()
    VerifySettingsRoundTrip(original.State,ReadStoredUserData(SettingsDatabasePath).State)
    Assert(!SettingsTransferActive && InStr(TransferMessages[-1],"すべて置き換え") && InStr(TransferMessages[-1],"弾幕：0件"),"cancel confirmation preserves data and describes empty whole replacement")
    TransferAnswer := "Yes"
    ImportSettingsBackup()
    Assert(!Profiles.Length && !SettingsTransferActive && InStr(TransferMessages[-1],"インポートしました"),"confirmed menu import succeeds")
    backups := []
    Loop Files SettingsDatabasePath ".before-import-*.json"
        backups.Push(A_LoopFileFullPath)
    Assert(backups.Length=1,"cancelled imports create no backup; successful import creates one")
    VerifySettingsRoundTrip(original.State,ReadUserData(backups[1]).State)
    TransferSelection := backups[1]
    ; Fail only the post-commit display refresh.
    FailTransferRefresh := true
    ImportSettingsBackup()
    VerifySettingsRoundTrip(original.State,ReadStoredUserData(SettingsDatabasePath).State)
    Assert(InStr(TransferMessages[-1],"データは保存済み") && !SettingsTransferActive,"post-commit UI failure reports successful data save")
    TransferSelection := A_ScriptDir "\no-such-file.db"
    ImportSettingsBackup()
    Assert(InStr(TransferMessages[-1],"インポートできませんでした") && !SettingsTransferActive,"source failure reports error and releases gate")
'@ -Helpers @'
SelectTransferFixture(*) {
    Assert(SettingsTransferActive && !OperationAllowed("edit"),"file dialog owns transfer gate")
    return TransferSelection
}
MessageTransferFixture(text,title := "",options := "") {
    TransferMessages.Push(text)
    return InStr(options,"YesNo") ? TransferAnswer : "OK"
}
RefreshTransferFixture() {
    if FailTransferRefresh
        throw Error("fixture display failure")
    RefreshImportedUserData()
}
'@

Invoke-AppFixture -TimeoutMs 60000 -Body @'
    path := A_ScriptDir "\strict.json", db := SqliteConnection(":memory:",true)
    original := ReadStoredUserData(SettingsDatabasePath)
    original.State.SharedDanmakuItems[1].Text := "payload"
    WriteUserData(original,path)
    json := FileRead(path,"UTF-8"), before := ReadStoredUserData(SettingsDatabasePath)
    invalids := ["{}", "[]", "null", json " extra",
        db.Scalar("SELECT json_set(?,'$.format','other')",json),
        db.Scalar("SELECT json_set(?,'$.version',99)",json),
        db.Scalar("SELECT json_set(?,'$.version','1')",json),
        db.Scalar("SELECT json_set(?,'$.preferences.autoMode',1.0)",json),
        db.Scalar("SELECT json_set(?,'$.preferences.autoMode',json('true'))",json),
        db.Scalar("SELECT json_set(?,'$.preferences.shortcutKeys.reaction',NULL)",json),
        db.Scalar("SELECT json_set(?,'$.profiles[0].items[0].slot','1')",json),
        db.Scalar("SELECT json_set(?,'$.profiles[0].items[0].slot',1e30)",json),
        db.Scalar("SELECT json_set(?,'$.sharedItems[0].id','fixture-one')",json),
        db.Scalar("SELECT json_set(?,'$.preferences.inputProfileId','missing')",json),
        db.Scalar("SELECT json_remove(?,'$.preferences.shortcutKeys.reaction')",json),
        db.Scalar("SELECT json_set(?,'$.extra',0)",json),
        '{"version":1,' SubStr(json,2), '{"\u0076ersion":1,' SubStr(json,2),
        StrReplace(json,'"format"','"Format"'),
        StrReplace(json,'"payload"','"\u0000"'),
        StrReplace(json,'"payload"','"\ud800"'),
        StrReplace(json,'"payload"','"\udc00"'),
        StrReplace(json,'"payload"','"\ud800\u0041"')]
    for index,text in invalids {
        bad := A_ScriptDir "\bad-" index ".json", rejected := false
        FileAppend(text,bad,"UTF-8-RAW")
        try ReadUserData(bad)
        catch
            rejected := true
        Assert(rejected && FileRead(bad,"UTF-8")==text,"invalid JSON rejected unchanged: " index)
    }
    raw := Buffer(2), NumPut("UChar",0xC0,"UChar",0xAF,raw)
    stream := FileOpen(A_ScriptDir "\bad-utf8.json","w"), stream.RawWrite(raw), stream.Close()
    rejected := false
    try ReadUserData(A_ScriptDir "\bad-utf8.json")
    catch
        rejected := true
    Assert(rejected,"invalid UTF-8 rejected before replacement decoding")
    FileAppend(Chr(0xFEFF) StrReplace(json,'"payload"','"\ud83d\udc4f"'),A_ScriptDir "\bom.json","UTF-8-RAW")
    Assert(ReadUserData(A_ScriptDir "\bom.json").State.SharedDanmakuItems[1].Text="👏","UTF-8 BOM and paired Unicode escapes accepted")
    raw := Buffer(3,0), NumPut("UChar",123,raw,0), NumPut("UChar",125,raw,2)
    stream := FileOpen(A_ScriptDir "\nul.json","w"), stream.RawWrite(raw), stream.Close()
    rejected := false
    try ReadUserData(A_ScriptDir "\nul.json")
    catch
        rejected := true
    Assert(rejected,"literal NUL rejected without truncation")
    tokens := "["
    Loop 5
        tokens .= (A_Index>1 ? "," : "") '{"name":"👏' A_Index '","id":"id' A_Index '","class":"button","type":50000,"extra":"kept"}'
    tokens .= "]"
    payload := '{"browser":"fixture","tokens":' tokens ',"extra":"preserved"}'
    SaveReactionRegistration(payload)
    ExportUserData(A_ScriptDir "\registration.json")
    registrationJson := FileRead(A_ScriptDir "\registration.json","UTF-8")
    imported := ReadUserData(A_ScriptDir "\registration.json")
    Assert(InStr(imported.Registrations[1],'"extra":"preserved"') && InStr(imported.Registrations[1],'"extra":"kept"'),"additional registration and token fields preserved")
    canonical := imported.Registrations[1], exactBytes := StrPut(canonical,"UTF-8")-1
    SettingsLimits.DefineProp("RegistrationsBytes",{Get:(*) => exactBytes})
    SaveReactionRegistration(canonical)
    Assert(ReadStoredUserData(SettingsDatabasePath).Registrations[1]==canonical
        && ReadUserData(A_ScriptDir "\registration.json").Registrations[1]==canonical,"registration aggregate exact boundary accepted by save, snapshot and JSON")
    larger := db.Scalar("SELECT json_set(?,'$.tokens[0].name',json_extract(?,'$.tokens[0].name')||'x')",canonical,canonical)
    rejected := false
    try SaveReactionRegistration(larger)
    catch
        rejected := true
    Assert(rejected && ReadStoredUserData(SettingsDatabasePath).Registrations[1]==canonical,"oversize registration update rolls back complete previous payload")
    exactBytes -= 1
    for read in [ReadStoredUserData.Bind(SettingsDatabasePath),ReadUserData.Bind(A_ScriptDir "\registration.json")] {
        rejected := false
        try read.Call()
        catch
            rejected := true
        Assert(rejected,"snapshot and JSON use the same aggregate bound")
    }
    SettingsLimits.DefineProp("RegistrationsBytes",{Get:(*) => 24000})
    individualBytes := StrPut(canonical,"UTF-8")
    SettingsLimits.DefineProp("RegistrationBytes",{Get:(*) => individualBytes})
    Assert(ValidateReactionRegistration(db,canonical)="fixture","individual size boundary includes its existing NUL allowance")
    rejected := false
    try ValidateReactionRegistration(db,larger)
    catch
        rejected := true
    Assert(rejected,"individual registration one byte over limit is rejected")
    SettingsLimits.DefineProp("RegistrationBytes",{Get:(*) => 8192})
    duplicate := db.Scalar("SELECT json_set(?,'$.reactionRegistrations[1]',json(?))",registrationJson,payload)
    FileAppend(duplicate,A_ScriptDir "\duplicate-browser.json","UTF-8-RAW")
    rejected := false
    try ReadUserData(A_ScriptDir "\duplicate-browser.json")
    catch
        rejected := true
    Assert(rejected,"duplicate browser rejected before UPSERT")
    limit := UserDataJson.MaxBytes
    UserDataJson.MaxBytes := FileGetSize(path)
    VerifySettingsRoundTrip(original.State,ReadUserData(path).State)
    UserDataJson.MaxBytes -= 1
    rejected := false
    try ReadUserData(path)
    catch
        rejected := true
    Assert(rejected,"file size cap enforced before parse")
    rejected := false
    try WriteUserData(original,A_ScriptDir "\too-large.json")
    catch
        rejected := true
    Assert(rejected && !FileExist(A_ScriptDir "\too-large.json"),"oversize export never publishes unreadable file")
    UserDataJson.MaxBytes := limit
    invalidData := ReadStoredUserData(SettingsDatabasePath)
    invalidData.State.SharedDanmakuItems[1].Id := "fixture-one"
    rejected := false
    try WriteUserData(invalidData,A_ScriptDir "\invalid-export.json")
    catch
        rejected := true
    Assert(rejected && !FileExist(A_ScriptDir "\invalid-export.json"),"roundtrip failure does not publish invalid export")
    leftovers := 0
    Loop Files A_ScriptDir "\*.creating-*"
        leftovers++
    Assert(leftovers=0,"failed export removes its temporary file")
    VerifySettingsRoundTrip(before.State,ReadStoredUserData(SettingsDatabasePath).State)
    SettingsLimits.DefineProp("Items",{Get:(*) => 3})
    VerifySettingsRoundTrip(original.State,ReadUserData(path).State)
    tooMany := db.Scalar("SELECT json_insert(?,'$.sharedItems[#]',json(?))",json,'{"id":"fourth","name":"extra","text":"extra","slot":0}')
    FileAppend(tooMany,A_ScriptDir "\item-limit.json","UTF-8-RAW")
    rejected := false
    try ReadUserData(A_ScriptDir "\item-limit.json")
    catch
        rejected := true
    Assert(rejected,"combined shared and profile item limit enforced")
    SettingsLimits.DefineProp("Items",{Get:(*) => 100000})
    SettingsLimits.DefineProp("Profiles",{Get:(*) => 1})
    tooMany := db.Scalar("SELECT json_insert(?,'$.profiles[#]',json(?))",json,'{"id":"second","name":"extra","channel":"","items":[]}')
    FileAppend(tooMany,A_ScriptDir "\profile-limit.json","UTF-8-RAW")
    rejected := false
    try ReadUserData(A_ScriptDir "\profile-limit.json")
    catch
        rejected := true
    Assert(rejected,"profile count limit enforced")
    SettingsLimits.DefineProp("Profiles",{Get:(*) => 10000})
    large := ReadStoredUserData(SettingsDatabasePath)
    large.State.SharedDanmakuItems := []
    Loop 1000
        large.State.SharedDanmakuItems.Push({Id:"scale-" A_Index,Name:"引用 `" と \",Text:"👏 日本語 \ud800 \u0000 " Chr(9) Chr(1),Slot:0})
    WriteUserData(large,A_ScriptDir "\scale.json")
    VerifySettingsRoundTrip(large.State,ReadUserData(A_ScriptDir "\scale.json").State)
    Assert(true,"1000 item JSON preserves escaped controls, quotes, backslashes, literal escapes and emoji")
    db.Close()
'@
