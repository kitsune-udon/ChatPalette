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
function Find-RegisteredReactions([long]$WindowHandle, $Saved) {
    if (-not $script:menu) { return $null }
    return @{Elements = @($script:target, $script:target, $script:target, $script:target, $script:target)}
}
function Request([string]$Mode, [string]$Expected = 'abcdefghijk', [string]$Reaction = '1') {
    return Invoke-WorkerRequest @{Mode=$Mode; Video=$Expected; Reaction=$Reaction; Window='123'; Seq='1'}
}
Assert ((Request 'reaction_status').State -eq 'not_registered' -and $script:invocations -eq 0) 'status reports absent registration without invoking'
Assert ((Request 'browser_context').State -eq 'ok') 'context does not require channel mapping'
Assert ((Request 'reaction_send').State -eq 'not_registered') 'unregistered blocks'
$script:BrowserReactionSelectors['fixture'] = @{tokens=@()}
$script:menu = $false
Assert ((Request 'reaction_status').State -eq 'configured' -and $script:invocations -eq 0) 'saved registration status does not need open menu or invoke'
$script:menu = $true
Assert ((Request 'reaction_check').State -eq 'ready' -and $script:invocations -eq 0) 'check never invokes'
Assert ((Request 'reaction_capture' 'ABCDEFGHIJK').State -eq 'changed') 'capture rejects changed video'
Assert ((Request 'reaction_send' 'ABCDEFGHIJK').State -eq 'changed') 'send rejects changed video'
$script:foreground = $false
Assert ((Request 'reaction_send').State -eq 'wrong_window' -and $script:invocations -eq 0) 'focus change blocks'
$script:foreground = $true
$script:menu = $false
Assert ((Request 'reaction_send').State -eq 'menu_closed') 'closed menu blocks'
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
$script:fakeButtons = @()
$names = @('heart','grinning face','party popper','surprised face','100 points')
for ($i = 0; $i -lt 5; $i++) {
    $script:fakeButtons += [pscustomobject]@{Current=[pscustomobject]@{
        Name=$names[$i]; AutomationId="reaction$i"; ClassName='button'; IsOffscreen=$false; IsEnabled=$true;
        ControlType=[pscustomobject]@{Id=50000}; BoundingRectangle=[pscustomobject]@{Top=($i*36); Left=100}
    }}
}
$fakeGroup = [pscustomobject]@{Current=[pscustomobject]@{ClassName='reaction-group'; AutomationId='reactions'}}
$fakeGroup | Add-Member ScriptMethod FindAll { param($scope,$condition) return $script:fakeButtons }
Assert ($null -ne (Get-ReactionGroup $fakeGroup)) 'registered five-button structure is recognized'
$script:fakeButtons[3].Current.Name = 'flushed face reaction'
Assert ($null -ne (Get-ReactionGroup $fakeGroup)) 'flushed face alternative'
$script:fakeButtons[3].Current.Name = '😳'
Assert ($null -ne (Get-ReactionGroup $fakeGroup)) 'flushed emoji alternative'
$script:fakeButtons[3].Current.Name = 'unrecognized expression'
Assert ($null -eq (Get-ReactionGroup $fakeGroup)) 'unknown expression never guessed'
Assert ($script:ReactionDiagnostic -match 'unrecognized expression') 'unmatched button label visible in diagnostics'
$script:fakeButtons[3].Current.Name = 'surprised face'
$extra = [pscustomobject]@{Current=[pscustomobject]@{Name='Close'; AutomationId='close'; ClassName='button'; IsOffscreen=$false; IsEnabled=$true; ControlType=[pscustomobject]@{Id=50000}}}
$script:fakeButtons += $extra
Assert ($null -ne (Get-ReactionGroup $fakeGroup)) 'unrelated surrounding button ignored'
$script:fakeButtons = @($script:fakeButtons[4],$script:fakeButtons[2],$script:fakeButtons[0],$script:fakeButtons[3],$script:fakeButtons[1])
$reordered = Get-ReactionGroup $fakeGroup
Assert ($reordered.Tokens[0].name -eq 'heart' -and $reordered.Tokens[4].name -eq '100 points') 'semantic order independent of UI tree order'
$script:fakeButtons = @($script:fakeButtons | Sort-Object {$_.Current.BoundingRectangle.Top})
$script:fakeButtons[1].Current.Name = 'delete'
Assert ($null -eq (Get-ReactionGroup $fakeGroup)) 'unrelated five-button menu rejected'
$script:fakeButtons[1].Current.Name = 'grinning face'
$script:fakeButtons[1].Current.IsOffscreen = $true
Assert ($null -eq (Get-ReactionGroup $fakeGroup)) 'partially hidden group rejected'

# Regression: lookup must not depend on blank/transient ancestor containers.
$savedLookup = @{groupClass='old container'; groupId='old'; tokens=@(
    1..5 | ForEach-Object { @{name="reaction$_"; id="id$_"; class='real-reaction-button'; type=50000} }
)} | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$records = @(1..5 | ForEach-Object {
    @{Name="reaction$_"; Id="id$_"; Class='real-reaction-button'; Type=50000; Hidden=$false; Enabled=$true; RuntimeId="runtime$_"; Element="element$_"}
})
Assert ($null -ne (Select-RegisteredReactions $records $savedLookup)) 'lookup independent of ancestor identity'
$records += $records[0].Clone()
Assert ($null -ne (Select-RegisteredReactions $records $savedLookup)) 'duplicate reference to same control accepted once'
$other = $records[0].Clone()
$other.RuntimeId = 'different-control'
$records += $other
Assert ($null -eq (Select-RegisteredReactions $records $savedLookup)) 'two distinct matching controls blocked'
$records = @($records | Where-Object { $_.RuntimeId -ne 'different-control' })
$records[1].Hidden = $true
Assert ($null -eq (Select-RegisteredReactions $records $savedLookup)) 'closed menu blocked'
Assert ($script:ReactionLookupDiagnostic -match '表示中=0') 'lookup failure details'
Write-Output 'PASS: direct lookup regression checks'
$records[1].Hidden = $false
$duplicateTokens = @{tokens=@($savedLookup.tokens[0],$savedLookup.tokens[0],$savedLookup.tokens[0],$savedLookup.tokens[0],$savedLookup.tokens[0])}
Assert ($null -eq (Select-RegisteredReactions $records $duplicateTokens)) 'duplicate saved tokens rejected'
$extraToken = @{tokens=@($savedLookup.tokens) + @(@{name='absent'; id='absent'; class='button'; type=50000})}
Assert ($null -eq (Select-RegisteredReactions $records $extraToken)) 'six tokens cannot pass with five matches'
$records[1].RuntimeId = $records[0].RuntimeId
Assert ($null -eq (Select-RegisteredReactions $records $savedLookup)) 'one runtime control cannot fulfill multiple reactions'
$savedLookup.tokens[2].type = 50026
$condition = New-ReactionLookupCondition $savedLookup
$terms = $condition.GetConditions()
Assert ($terms.Count -eq 5) 'lookup has five registered alternatives'
$customTerms = $terms[2].GetConditions()
Assert ($customTerms[1].Value -eq 50026) 'lookup retains captured Custom control type'
Write-Output 'PASS: corrupt registration and Custom control lookup checks'

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
