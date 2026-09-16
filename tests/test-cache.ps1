$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. "$release\reaction_automation.ps1"
function Test-ElementWindow($Element, [long]$WindowHandle) { return $WindowHandle -eq 123 }
$tokens = @(1..5 | ForEach-Object { @{name="reaction$_";id="id$_";class='reaction';type=50000} })
$saved = @{tokens=$tokens}
$elements = @(foreach ($i in 1..5) {
    $control = [pscustomobject]@{Id=$i;Current=[pscustomobject]@{
        Name="reaction$i";AutomationId="id$i";ClassName='reaction';ControlType=[pscustomobject]@{Id=50000};IsOffscreen=$false;IsEnabled=$true}}
    $control | Add-Member ScriptMethod GetRuntimeId { return @($this.Id) }
    $control
})
$script:ReactionElementCache[123L] = @{Fingerprint=($tokens | ConvertTo-Json -Depth 4 -Compress);Checked=[DateTime]::UtcNow;Elements=$elements}
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
