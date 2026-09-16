$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. "$release\src\browser\reaction_automation.ps1"
function Test-ElementWindow($Element, [long]$WindowHandle) { return $WindowHandle -eq 123 }
$tokens = @(1..5 | ForEach-Object { @{name="reaction$_";id="id$_";class='reaction';type=50000} })
$saved = @{tokens=$tokens}
$elements = @(foreach ($i in 1..5) {
    $control = [pscustomobject]@{Id=$i;Current=[pscustomobject]@{
        Name="reaction$i";AutomationId="id$i";ClassName='reaction';ControlType=[pscustomobject]@{Id=50000};IsOffscreen=$false;IsEnabled=$true}}
    $control | Add-Member ScriptMethod GetUpdatedCache { param($request) return [pscustomobject]@{Cached=$this.Current} }
    $control | Add-Member ScriptMethod GetRuntimeId { return @($this.Id) }
    $control
})
$script:ReactionElementCache[123L] = @{Plan=(Get-ReactionPlan $saved);Checked=[DateTime]::UtcNow;Elements=$elements}
$result = Find-RegisteredReactions 123 $saved
if ($null -eq $result -or $result.Elements.Count -ne 5) { throw 'valid cache not reused' }
$elements[2].Current.IsOffscreen = $true
$records = @(foreach ($element in $elements) { Get-ReactionRecord $element })
if ($null -ne (Select-RegisteredReactions $records $saved)) { throw 'hidden cached control accepted' }
$elements[2].Current.IsOffscreen = $false
$elements[2].Current.Name = 'replaced'
$records = @(foreach ($element in $elements) { Get-ReactionRecord $element })
if ($null -ne (Select-RegisteredReactions $records $saved)) { throw 'changed cached identity accepted' }
'PASS: cached lookup, hidden control and changed identity checks'
$plan = Get-ReactionPlan $saved
if (![object]::ReferenceEquals($plan,(Get-ReactionPlan $saved))) { throw 'Registration plan not reused' }
$replacement = @{tokens=@($tokens | ForEach-Object { $_.Clone() })}
$replacement.tokens[0].name = 'new-name'
$nextPlan = Get-ReactionPlan $replacement
if ([object]::ReferenceEquals($plan,$nextPlan) -or $nextPlan.Tokens[0].name -ne 'new-name') { throw 'Re-registration reused old plan' }
if ($plan.Tokens[0].name -ne 'reaction1') { throw 'Prepared snapshot changed with new registration' }
foreach ($i in 1..20) { $null = Get-ReactionPlan @{tokens=@($tokens | ForEach-Object { $_.Clone() })} }
if ($script:ReactionPlans.Count -gt 8) { throw 'Registration plan cache unbounded' }
'PASS: reusable registration plans, replacement and bounded cache'

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
$plan = Get-ReactionPlan $saved
function Reset-TestCache {
    $script:ReactionElementCache[123L] = @{Plan=$plan; Checked=[DateTime]::UtcNow.AddDays(-1); Elements=$elements}
    $script:SearchCount = 0
}
Reset-TestCache
$result = Find-RegisteredReactions 123 $saved
if ($null -eq $result -or $script:SearchCount -ne 0) { throw 'Valid old references were rescanned' }
foreach ($property in 'IsOffscreen','IsEnabled','Name') {
    Reset-TestCache
    $old = $elements[2].Current.$property
    $elements[2].Current.$property = switch ($property) { 'IsOffscreen' {$true} 'IsEnabled' {$false} 'Name' {'changed'} }
    $result = Find-RegisteredReactions 123 $saved
    if ($null -ne $result -or $script:SearchCount -ne 1 -or $script:ReactionElementCache.ContainsKey(123L)) { throw "Invalid cache retained: $property" }
    $elements[2].Current.$property = $old
}
Reset-TestCache
$script:WrongElement = 5
$result = Find-RegisteredReactions 123 $saved
if ($null -ne $result -or $script:SearchCount -ne 1) { throw 'Wrong-window non-first element accepted' }
$script:WrongElement = 0
Reset-TestCache
$elements[2] | Add-Member ScriptMethod GetUpdatedCache { throw 'Stale element' } -Force
$result = Find-RegisteredReactions 123 $saved
if ($null -ne $result -or $script:SearchCount -ne 1) { throw 'Stale element not invalidated' }
$elements[2] | Add-Member ScriptMethod GetUpdatedCache { param($request) return [pscustomobject]@{Cached=$this.Current} } -Force
Reset-TestCache
$script:SearchResult = @{Elements=$elements}
$replacement = @{tokens=@($tokens | ForEach-Object {$_.Clone()})}
$result = Find-RegisteredReactions 123 $replacement
if ($null -eq $result -or $script:SearchCount -ne 1) { throw 'Re-registration did not refresh references' }
$null = Find-RegisteredReactions 123 $replacement
if ($script:SearchCount -ne 1) { throw 'Refreshed references not reused' }
'PASS: long-lived references, invalidation, full ownership and fallback refresh'
