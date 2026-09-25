# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. "$release\src\browser\reaction_automation.ps1"
function Test-ElementWindow($Element, [long]$WindowHandle) { return $WindowHandle -eq 123 }
$tokens = @(1..5 | ForEach-Object { @{name="reaction$_";id="id$_";class='reaction';type=50000} })
$plan = New-ReactionPlan $tokens
$elements = @(foreach ($i in 1..5) {
    $control = [pscustomobject]@{Id=$i;Current=[pscustomobject]@{
        Name="reaction$i";AutomationId="id$i";ClassName='reaction';ControlType=[pscustomobject]@{Id=50000};IsOffscreen=$false;IsEnabled=$true}}
    $control | Add-Member ScriptMethod GetUpdatedCache { param($request) return [pscustomobject]@{Cached=$this.Current} }
    $control | Add-Member ScriptMethod GetRuntimeId { return @($this.Id) }
    $control
})
$script:ReactionElementCache[123L] = @{Plan=$plan;Elements=$elements}
$result = Find-RegisteredReactions 123 $plan
if ($null -eq $result -or $result.Elements.Count -ne 5) { throw 'valid cache not reused' }
$elements[2].Current.IsOffscreen = $true
$records = @(foreach ($element in $elements) { Get-ReactionRecord $element })
if ($null -ne (Select-ReactionRecords $records $plan)) { throw 'hidden cached control accepted' }
$elements[2].Current.IsOffscreen = $false
$elements[2].Current.Name = 'replaced'
$records = @(foreach ($element in $elements) { Get-ReactionRecord $element })
if ($null -ne (Select-ReactionRecords $records $plan)) { throw 'changed cached identity accepted' }
'PASS: cached lookup, hidden control and changed identity checks'
$replacementTokens = @($tokens | ForEach-Object { $_.Clone() })
$replacementTokens[0].name = 'new-name'
$nextPlan = New-ReactionPlan $replacementTokens
if ([object]::ReferenceEquals($plan,$nextPlan) -or $nextPlan.Tokens[0].name -ne 'new-name') { throw 'Re-registration reused old plan' }
$replacementTokens[0].name = 'later edit'
if ($plan.Tokens[0].name -ne 'reaction1' -or $nextPlan.Tokens[0].name -ne 'new-name') { throw 'Lookup plan retained mutable input identities' }
'PASS: owned registration plans and independent replacement'

$script:SearchCount = 0
$script:SearchResult = $null
$script:WrongElement = 0
function Find-ReactionGroupInWindow([long]$WindowHandle, $plan) {
    $script:SearchCount++
    return $script:SearchResult
}
function Test-ElementWindow($Element, [long]$WindowHandle) {
    return $WindowHandle -eq 123 -and $Element.Id -ne $script:WrongElement
}
$elements[2].Current.Name = 'reaction3'
function Reset-TestCache {
    $script:ReactionElementCache[123L] = @{Plan=$plan; Elements=$elements}
    $script:SearchCount = 0
}
Reset-TestCache
$result = Find-RegisteredReactions 123 $plan
if ($null -eq $result -or $script:SearchCount -ne 0) { throw 'Valid references were rescanned' }
foreach ($property in 'IsOffscreen','IsEnabled','Name') {
    Reset-TestCache
    $old = $elements[2].Current.$property
    $elements[2].Current.$property = switch ($property) { 'IsOffscreen' {$true} 'IsEnabled' {$false} 'Name' {'changed'} }
    $result = Find-RegisteredReactions 123 $plan
    if ($null -ne $result -or $script:SearchCount -ne 1 -or $script:ReactionElementCache.ContainsKey(123L)) { throw "Invalid cache retained: $property" }
    $elements[2].Current.$property = $old
}
Reset-TestCache
$script:WrongElement = 5
$result = Find-RegisteredReactions 123 $plan
if ($null -ne $result -or $script:SearchCount -ne 1) { throw 'Wrong-window non-first element accepted' }
$script:WrongElement = 0
Reset-TestCache
$elements[2] | Add-Member ScriptMethod GetUpdatedCache { throw 'Stale element' } -Force
$result = Find-RegisteredReactions 123 $plan
if ($null -ne $result -or $script:SearchCount -ne 1) { throw 'Stale element not invalidated' }
$elements[2] | Add-Member ScriptMethod GetUpdatedCache { param($request) return [pscustomobject]@{Cached=$this.Current} } -Force
Reset-TestCache
$script:SearchResult = @{Elements=$elements}
$replacement = New-ReactionPlan $tokens
$result = Find-RegisteredReactions 123 $replacement
if ($null -eq $result -or $script:SearchCount -ne 1) { throw 'Re-registration did not refresh references' }
$null = Find-RegisteredReactions 123 $replacement
if ($script:SearchCount -ne 1) { throw 'Refreshed references not reused' }
'PASS: reference revalidation, invalidation, full ownership and fallback refresh'

# Invalid snapshots are rejected at publication, before lookup can see any partial plan.
$payload = @{version=1;profiles=@(@{browser='fixture';tokens=$tokens})} | ConvertTo-Json -Depth 8 -Compress
Set-ReactionRegistrationSnapshot $payload
$published = $script:BrowserReactionSelectors
$script:ReactionElementCache[123L] = @{Plan=$published['fixture'];Elements=$elements}
$cachedBefore = $script:ReactionElementCache[123L]
$duplicateTokens = @($tokens[0],$tokens[0],$tokens[0],$tokens[0],$tokens[0])
$extraTokens = @($tokens) + @(@{name='absent';id='absent';class='reaction';type=50000})
foreach ($invalid in @(@{tokens=$duplicateTokens},@{tokens=$extraTokens})) {
    $script:SearchCount = 0
    $badPayload = @{version=1;profiles=@(@{browser='first';tokens=$tokens},@{browser='invalid';tokens=$invalid.tokens})} | ConvertTo-Json -Depth 8 -Compress
    $rejected = $false
    try { Set-ReactionRegistrationSnapshot $badPayload } catch { $rejected = $true }
    if (!$rejected -or $script:SearchCount -ne 0) { throw 'Invalid snapshot reached UI discovery' }
    if (![object]::ReferenceEquals($published,$script:BrowserReactionSelectors)) { throw 'Invalid snapshot published partial plans' }
    if (![object]::ReferenceEquals($cachedBefore,$script:ReactionElementCache[123L])) { throw 'Invalid snapshot changed the valid reference cache' }
}
'PASS: invalid snapshots preserve published plans and valid reference caches'
