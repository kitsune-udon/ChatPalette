# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
. "$release\src\browser\browser_worker.ps1" -Library
$script:checks = 0
function Assert($condition, $label) { if (-not $condition) { throw "FAIL: $label" }; $script:checks++ }
$script:video = 'abcdefghijk'
$script:foreground = $true
$script:menu = $true
$script:invocations = 0
$script:throwOnInvoke = $false
$script:target = [pscustomobject]@{Current = [pscustomobject]@{IsOffscreen = $false; IsEnabled = $true}}
$script:invoker = [pscustomobject]@{}
$script:invoker | Add-Member ScriptMethod Invoke {
    $script:invocations++
    if ($script:throwOnInvoke) { throw 'unknown completion' }
}
function Read-BrowserVideoId([long]$WindowHandle) { return $script:video }
function Get-BrowserProcessName([long]$WindowHandle) { return 'fixture' }
function Test-ReactionForeground([long]$WindowHandle) { return $script:foreground }
function Get-ReactionInvoker($Target) { return $script:invoker }
function Find-RegisteredReactions([long]$WindowHandle, $Plan) {
    if (-not $script:menu) { return @{Elements=$null; Detail='fixture menu closed'} }
    return @{Elements = @($script:target, $script:target, $script:target, $script:target, $script:target); Detail='fixture menu found'}
}
function Request([string]$Mode, [string]$Expected = 'abcdefghijk', [string]$Reaction = '1') {
    return Invoke-WorkerRequest @{Mode=$Mode; Video=$Expected; Reaction=$Reaction; Window='123'; Seq='1'}
}
Assert ((Request 'browser_context').State -eq 'ok') 'context does not require channel mapping'
Assert ((Request 'reaction_send').State -eq 'not_registered') 'unregistered blocks'
$script:BrowserReactionSelectors['fixture'] = @{tokens=@()}
Assert ((Request 'reaction_check').State -eq 'ready' -and $script:invocations -eq 0) 'check never invokes'
Assert ((Request 'reaction_capture' 'ABCDEFGHIJK').State -eq 'changed') 'capture rejects changed video'
Assert ((Request 'reaction_send' 'ABCDEFGHIJK').State -eq 'changed') 'send rejects changed video'
$script:foreground = $false
Assert ((Request 'reaction_send').State -eq 'wrong_window' -and $script:invocations -eq 0) 'focus change blocks'
$script:foreground = $true
$script:menu = $false
$closedReply = Request 'reaction_send'
Assert ($closedReply.State -eq 'menu_closed' -and $closedReply.Detail -eq 'fixture menu closed') 'closed menu carries this lookup reason without invoking'
$script:menu = $true
$script:target.Current.IsEnabled = $false
Assert ((Request 'reaction_send').State -eq 'menu_closed') 'disabled target blocks'
$script:target.Current.IsEnabled = $true
Assert ((Request 'reaction_send' 'abcdefghijk' '6').State -eq 'unavailable') 'unknown reaction blocks'
Assert ($script:invocations -eq 0) 'all rejected requests leave invocation count unchanged'
Assert ((Request 'reaction_send').State -eq 'operated' -and $script:invocations -eq 1) 'one operation'
Assert ((Request 'reaction_send').State -eq 'operated' -and $script:invocations -eq 2) '待機なし does not impose hidden cooldown'
# A focus switch while obtaining the invoker must also block the action.
function Get-ReactionInvoker($Target) { $script:foreground = $false; return $script:invoker }
Assert ((Request 'reaction_send').State -eq 'wrong_window' -and $script:invocations -eq 2) 'focus change immediately before invoke blocks'
$script:foreground = $true
function Get-ReactionInvoker($Target) { return $script:invoker }
$script:throwOnInvoke = $true
Assert ((Request 'reaction_send').State -eq 'unknown' -and $script:invocations -eq 3) 'uncertain completion never retries'
$script:video = ''
Assert ((Request 'reaction_send').State -eq 'unavailable' -and $script:invocations -eq 3) 'unreadable URL blocks'
$script:video='abcdefghijk'
$script:throwOnInvoke=$false
$script:reads=0
function Read-BrowserVideoId([long]$WindowHandle) {
    $script:reads++
    if ($script:reads -eq 1) { return 'abcdefghijk' }
    return 'ABCDEFGHIJK'
}
Assert ((Request 'reaction_send').State -eq 'changed' -and $script:invocations -eq 3) 'video change during lookup never invokes'
function Read-BrowserVideoId([long]$WindowHandle) { return $script:video }
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$script:changeCapturedIdentity = $false
function CaptureButton($Info) {
    $element = [pscustomobject]@{Current=$Info; SnapshotReads=0}
    $element | Add-Member ScriptMethod GetUpdatedCache {
        param($request)
        $this.SnapshotReads++
        $snapshot = $this.Current.PSObject.Copy()
        if ($script:changeCapturedIdentity -and $this.Current.AutomationId -eq 'reaction0') {
            $this.Current.Name = 'changed after capture'
        }
        return [pscustomobject]@{Cached=$snapshot}
    }
    $element | Add-Member ScriptMethod GetRuntimeId { return @($this.Current.AutomationId) }
    return $element
}
$script:fakeButtons = @()
$names = @('heart','grinning face','party popper','surprised face','100 points')
for ($i = 0; $i -lt 5; $i++) {
    $script:fakeButtons += CaptureButton ([pscustomobject]@{
        Name=$names[$i]; AutomationId="reaction$i"; ClassName='button'; IsOffscreen=$false; IsEnabled=$true;
        ControlType=[pscustomobject]@{Id=50000}; BoundingRectangle=[pscustomobject]@{Top=($i*36); Bottom=($i*36+30); Left=100; Width=30; Height=30}
    })
}
$script:containerPropertyReads = 0
$fakeGroup = [pscustomobject]@{}
$fakeGroup | Add-Member ScriptProperty Current {
    $script:containerPropertyReads++
    throw 'Capture must not read unused container properties'
}
$fakeGroup | Add-Member ScriptMethod FindAll { param($scope,$condition) return $script:fakeButtons }
Assert ($null -ne (Get-ReactionCapture $fakeGroup).Tokens) 'registered five-button structure is recognized'
Assert ($script:containerPropertyReads -eq 0) 'capture reads only the required button identities'
Assert (@($script:fakeButtons | Where-Object { $_.SnapshotReads -ne 1 }).Count -eq 0) 'capture fetches one property snapshot per candidate'
$script:changeCapturedIdentity = $true
$stableCapture = Get-ReactionCapture $fakeGroup
Assert ($stableCapture.Tokens.Count -eq 5 -and $stableCapture.Tokens[0].name -ceq 'heart' -and $script:fakeButtons[0].Current.Name -ceq 'changed after capture') 'classification and registered identity use the same observation'
Assert ($stableCapture.Detail -match 'heart \{reaction0\}' -and $stableCapture.Detail -notmatch 'changed after capture') 'diagnostic names describe the same observed candidates'
$script:changeCapturedIdentity = $false
$changedCapture = Get-ReactionCapture $fakeGroup
Assert ($null -eq $changedCapture.Tokens -and $changedCapture.Detail -match '不足=ハート') 'next capture reports the missing heart after its identity changes'
Assert ($stableCapture.Tokens[0].name -ceq 'heart' -and $stableCapture.Detail -notmatch 'changed after capture') 'later capture does not overwrite an earlier result or its diagnostic'
$script:fakeButtons[0].Current.Name = $names[0]

$captured = Get-ReactionCapture $fakeGroup
Assert ((Test-ReactionTokens $captured.Tokens) -and $captured.Tokens.Count -eq 5) 'captured identities satisfy the registration contract'
# Geometry is diagnostic only: failure must not invalidate complete button identities.
$script:CaptureBoundsReads = 0
$script:CaptureBoundsFailure = $true
foreach ($button in $script:fakeButtons) {
    $info = $button.Current
    $info | Add-Member NoteProperty FixtureBounds $info.BoundingRectangle
    $info.PSObject.Properties.Remove('BoundingRectangle')
    $info | Add-Member ScriptProperty BoundingRectangle {
        $script:CaptureBoundsReads++
        if ($script:CaptureBoundsFailure -and $this.AutomationId -eq 'reaction3') { throw 'Diagnostic bounds unavailable' }
        return $this.FixtureBounds
    }
}
$withoutBounds = Get-ReactionCapture $fakeGroup
Assert ((Test-ReactionTokens $withoutBounds.Tokens) -and $withoutBounds.Tokens.Count -eq 5) 'diagnostic geometry failure does not discard complete registration identities'
Assert ($withoutBounds.Detail -match 'heart \{reaction0\}' -and $withoutBounds.Detail -match '100 points \{reaction4\}' -and $withoutBounds.Detail -match 'surprised face \{reaction3\}') 'diagnostics retain the candidate whose geometry is unavailable'
$script:CaptureBoundsFailure = $false
$script:CaptureBoundsReads = 0
$withBounds = Get-ReactionCapture $fakeGroup
Assert ((Test-ReactionTokens $withBounds.Tokens) -and $script:CaptureBoundsReads -eq 5) 'diagnostic geometry is read once per candidate'
$payload = @{version=1;profiles=@(@{browser='fixture';tokens=$captured.Tokens})} | ConvertTo-Json -Depth 8 -Compress
Set-ReactionRegistrationSnapshot $payload
$capturedPlan = $script:BrowserReactionSelectors['fixture']
Assert ($capturedPlan.Tokens.Count -eq 5 -and $capturedPlan.Tokens[0].name -ceq $names[0] -and $capturedPlan.Tokens[4].name -ceq $names[4]) 'captured identities survive serialization and become the lookup plan'
foreach ($invalidType in @(49999,50041,'50000')) {
    $script:fakeButtons[0].Current.ControlType.Id = $invalidType
    Assert ($null -eq (Get-ReactionCapture $fakeGroup).Tokens) 'capture rejects types that cannot be registered'
}
$script:fakeButtons[0].Current.ControlType.Id = 50000
$script:fakeButtons[0].Current.ClassName = $null
Assert ($null -eq (Get-ReactionCapture $fakeGroup).Tokens) 'capture rejects incomplete button identities'
$script:fakeButtons[0].Current.ClassName = 'button'
$originalButtons = $script:fakeButtons
$originalButtons[0].Current.Name = 'heart grinning face'
$script:fakeButtons = @($originalButtons[0],$originalButtons[2],$originalButtons[3],$originalButtons[4])
Assert ($null -eq (Get-ReactionCapture $fakeGroup).Tokens) 'one button cannot supply two captured reaction identities'
$script:fakeButtons = $originalButtons
$script:fakeButtons[0].Current.Name = $names[0]

$script:fakeButtons[3].Current.Name = 'flushed face reaction'
Assert ($null -ne (Get-ReactionCapture $fakeGroup).Tokens) 'flushed face alternative'
$script:fakeButtons[3].Current.Name = '😳'
Assert ($null -ne (Get-ReactionCapture $fakeGroup).Tokens) 'flushed emoji alternative'
$script:fakeButtons[3].Current.Name = 'unrecognized expression'
$unknownCapture = Get-ReactionCapture $fakeGroup
Assert ($null -eq $unknownCapture.Tokens) 'unknown expression never guessed'
Assert ($unknownCapture.Detail -match 'unrecognized expression') 'unmatched button label visible in diagnostics'
$script:fakeButtons[3].Current.Name = 'surprised face'
$extra = CaptureButton ([pscustomobject]@{Name='Close'; AutomationId='close'; ClassName='button'; IsOffscreen=$false; IsEnabled=$true; ControlType=[pscustomobject]@{Id=50000}; BoundingRectangle=[pscustomobject]@{Top=0;Bottom=30;Left=500;Width=30;Height=30}})
$script:fakeButtons += $extra
$surroundedCapture = Get-ReactionCapture $fakeGroup
Assert ($surroundedCapture.Tokens.Count -eq 5) 'unrelated surrounding button ignored'
Assert ($surroundedCapture.Detail -notmatch 'Close \{close\}') 'diagnostic geometry still excludes distant buttons'
$script:fakeButtons = @($script:fakeButtons[4],$script:fakeButtons[2],$script:fakeButtons[0],$script:fakeButtons[3],$script:fakeButtons[1])
$reordered = Get-ReactionCapture $fakeGroup
Assert ($reordered.Tokens[0].name -eq 'heart' -and $reordered.Tokens[4].name -eq '100 points') 'semantic order independent of UI tree order'
$script:fakeButtons = @($script:fakeButtons | Sort-Object {$_.Current.BoundingRectangle.Top})
$script:fakeButtons[1].Current.Name = 'delete'
Assert ($null -eq (Get-ReactionCapture $fakeGroup).Tokens) 'unrelated five-button menu rejected'
$script:fakeButtons[1].Current.Name = 'grinning face'
$script:fakeButtons[1].Current.IsOffscreen = $true
Assert ($null -eq (Get-ReactionCapture $fakeGroup).Tokens) 'partially hidden group rejected'

# Regression: lookup must not depend on blank/transient ancestor containers.
$savedLookup = @{tokens=@(
    1..5 | ForEach-Object { @{name="reaction$_"; id="id$_"; class='real-reaction-button'; type=50000} }
)}
$lookupPlan = New-ReactionPlan $savedLookup.tokens
$records = @(1..5 | ForEach-Object {
    @{Name="reaction$_"; Id="id$_"; Class='real-reaction-button'; Type=50000; Hidden=$false; Enabled=$true; RuntimeId="runtime$_"; Element="element$_"}
})
Assert ($null -ne (Select-ReactionRecords $records $lookupPlan).Elements) 'lookup independent of ancestor identity'
$records += $records[0].Clone()
Assert ($null -ne (Select-ReactionRecords $records $lookupPlan).Elements) 'duplicate reference to same control accepted once'
$other = $records[0].Clone()
$other.RuntimeId = 'different-control'
$records += $other
Assert ($null -eq (Select-ReactionRecords $records $lookupPlan).Elements) 'two distinct matching controls blocked'
$records = @($records | Where-Object { $_.RuntimeId -ne 'different-control' })
$records[1].Hidden = $true
$closedLookup = Select-ReactionRecords $records $lookupPlan
Assert ($null -eq $closedLookup.Elements) 'closed menu blocked'
Assert ($closedLookup.Detail -match '表示中=0') 'lookup failure details'
Write-Output 'PASS: direct lookup regression checks'
$records[1].Hidden = $false
foreach ($invalidIdentity in @('', $records[0].RuntimeId)) {
    $records[1].RuntimeId = $invalidIdentity
    $invalidLookup = Select-ReactionRecords $records $lookupPlan
    Assert ($null -eq $invalidLookup.Elements) 'missing or duplicate runtime identity prevents selecting a reaction group'
    Assert ($invalidLookup.Detail.Contains('[reaction2] 識別情報が不明または重複') -and $closedLookup.Detail -match '表示中=0' -and
        $closedLookup.Detail -notmatch '識別情報が不明または重複') 'each rejected lookup retains its own reason and affected reaction'
}
$customRegistration = @{tokens=@($savedLookup.tokens | ForEach-Object { $_.Clone() })}
$customRegistration.tokens[2].type = 50026
$condition = New-ReactionLookupCondition (New-ReactionPlan $customRegistration.tokens)
$terms = $condition.GetConditions()
Assert ($terms.Count -eq 5) 'lookup has five registered alternatives'
$customTerms = $terms[2].GetConditions()
Assert ($customTerms[1].Value -eq 50026) 'lookup retains captured Custom control type'
Write-Output 'PASS: unique runtime identity and Custom control lookup checks'

# Generic context must not dispatch into reaction automation or metadata lookup.
$script:video = 'abcdefghijk'
$oldReactionHandler = ${function:Invoke-ReactionRequest}
$oldResolver = ${function:Resolve-Video}
try {
    function Invoke-ReactionRequest($Request) { throw 'Context entered reaction handler' }
    function Resolve-Video($Video) { throw 'Context fetched metadata' }
    $context = Invoke-WorkerRequest @{Mode='browser_context'; Window=123; Seq=7}
    Assert ($context.State -eq 'ok' -and $context.Video -ceq $script:video) 'generic context bypasses reactions and metadata'
} finally {
    Set-Item Function:Invoke-ReactionRequest $oldReactionHandler
    Set-Item Function:Resolve-Video $oldResolver
}
Write-Output 'PASS: generic browser context is independent of reactions and metadata'

Write-Output "PASS: $script:checks reaction checks; no real UI or network used"
