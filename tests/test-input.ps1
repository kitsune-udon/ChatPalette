# Test-Session: Headless
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
 . (Join-Path $release 'src\browser\input_target.ps1')
if (!(Get-Command Test-ElementWindow -ErrorAction SilentlyContinue)) { throw 'Standalone input target lacks window validation' }
if (Get-Variable BrowserReactionSelectors -Scope Script -ErrorAction SilentlyContinue) { throw 'Input target initialized reaction registration' }
. (Join-Path $release 'src\browser\browser_worker.ps1') -Library
$script:checks = 0
function Assert($value, $label) { if (!$value) { throw $label }; $script:checks++ }
function Field([string]$Id, [string]$Name = '') {
    return @{Id=$Id; Name=$Name; Class=''; Type=50004; Focused=$true; Enabled=$true; Hidden=$false; Editable=$true}
}
$document = @{Id=''; Name=''; Class=''; Type=50030}
$chatParent = @{Id=''; Class='style-scope yt-live-chat-text-input-field-renderer'; Type=50033}
$commentParent = @{Id=''; Class='style-scope ytd-comment-simplebox-renderer'; Type=50033}
Assert ((Get-YouTubeInputKind @((Field 'input'),$chatParent,$document)) -eq 'chat') 'chat recognized'
Assert ((Get-YouTubeInputKind @((Field 'contenteditable-root'),$commentParent,$document)) -eq 'comment') 'comment recognized'
foreach ($spec in @(@('input',$chatParent,'chat'),@('contenteditable-root',$commentParent,'comment'))) {
    $field = Field $spec[0]
    $field.Focused = $false
    Assert ((Get-YouTubeInputKind @($field,$spec[1],$document)) -eq $spec[2]) 'kind is recognized before focus moves'
    Assert (!$field.Focused) 'classification preserves the observed focus state'
}
foreach ($name in @('コメントを追加…','Add a comment...','返信を入力','Add a reply…')) {
    Assert ((Get-YouTubeInputKind @((Field '' $name),$document)) -eq 'comment') "named comment: $name"
}
Assert (!(Get-YouTubeInputKind @((Field 'search' 'Search'),$document))) 'search rejected'
Assert (!(Get-YouTubeInputKind @((Field 'urlbar' 'コメントを追加…'),$document))) 'address bar rejected'
Assert (!(Get-YouTubeInputKind @((Field 'contenteditable-root'),$document))) 'ambiguous editor rejected'
Assert (!(Get-YouTubeInputKind @((Field 'input'),$chatParent))) 'outside web document rejected'
foreach ($change in @('Hidden','Enabled','Editable')) {
    $field = Field 'input'
    $field[$change] = $change -eq 'Hidden'
    Assert (!(Get-YouTubeInputKind @($field,$chatParent,$document))) "invalid field state: $change"
}
# Exercise actual pattern extraction with Chromium's observed Custom/TextPattern
# representation, without reading text or interacting with a browser.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
function TextField($ReadOnly, [string]$Id, [string]$Class) {
    $range = [pscustomobject]@{ReadOnly=$ReadOnly}
    $range | Add-Member ScriptMethod GetAttributeValue { param($attribute) return $this.ReadOnly }
    $element = [pscustomobject]@{
        Current=[pscustomobject]@{AutomationId=$Id; Name=''; ClassName=$Class;
            ControlType=[pscustomobject]@{Id=50026}; HasKeyboardFocus=$true; IsEnabled=$true; IsOffscreen=$false}
        Pattern=[pscustomobject]@{DocumentRange=$range}
    }
    $element | Add-Member ScriptMethod TryGetCurrentPattern {
        param($kind, $result)
        if ($kind -eq [System.Windows.Automation.TextPattern]::Pattern) {
            $result.Value=$this.Pattern; return $true
        }
        return $false
    }
    return $element
}
foreach ($spec in @(
    @('input','style-scope yt-live-chat-text-input-field-renderer','chat'),
    @('contenteditable-root','style-scope ytd-comment-simplebox-renderer','comment')
)) {
    foreach ($focused in @($true,$false)) {
        $element = TextField $false $spec[0] $spec[1]
        $element.Current.HasKeyboardFocus = $focused
        $record = Get-InputRecord $element $true
        Assert ((Get-YouTubeInputKind @($record,$document)) -eq $spec[2]) "editable Custom/TextPattern: $($spec[2]) focus=$focused"
        Assert ($record.Focused -eq $focused) 'pattern extraction retains actual focus separately from kind'
    }
    foreach ($readOnly in @($true,[System.Windows.Automation.AutomationElement]::NotSupported,[System.Windows.Automation.TextPattern]::MixedAttributeValue)) {
        $record = Get-InputRecord (TextField $readOnly $spec[0] $spec[1]) $true
        Assert (!(Get-YouTubeInputKind @($record,$document))) 'read-only or unknown TextPattern rejected'
    }
}
$record = Get-InputRecord (TextField $false 'search' '') $true
Assert (!(Get-YouTubeInputKind @($record,$document))) 'editable Custom search rejected'
$record = Get-InputRecord (TextField $false 'other-editor' '') $true
Assert (!(Get-YouTubeInputKind @($record,$document))) 'unknown Custom editor rejected'
$patternless = TextField $false 'input' 'style-scope yt-live-chat-text-input-field-renderer'
$patternless.Current.ControlType.Id = 50004
$patternless | Add-Member ScriptMethod TryGetCurrentPattern { param($kind,$result) return $false } -Force
$record = Get-InputRecord $patternless $true
Assert (!(Get-YouTubeInputKind @($record,$document))) 'Edit without evidence of writability rejected'
$ancestor = TextField $false 'parent' 'style-scope ytd-comment-simplebox-renderer'
$ancestor.Current.PSObject.Properties.Remove('Name')
$ancestor.Current | Add-Member ScriptProperty Name { throw 'Ancestor text must not be queried' }
$ancestor | Add-Member ScriptMethod TryGetCurrentPattern { throw 'Ancestor edit patterns must not be queried' } -Force
$structural = Get-InputRecord $ancestor $false
Assert ($structural.Id -eq 'parent' -and !$structural.ContainsKey('Name')) 'ancestry fetches structure only'
$record = Get-InputRecord (TextField $false 'contenteditable-root' 'style-scope yt-formatted-string') $true
Assert ((Get-YouTubeInputKind @($record,
    @{Id='contenteditable-textarea'; Class='style-scope ytd-commentbox'; Type=50026},
    @{Id='commentbox'; Class='style-scope ytd-comment-dialog-renderer'; Type=50026},
    $document)) -eq 'comment') 'observed comment ancestry without a label'
# Invalid targets must be rejected before querying a live ancestry. These stand-ins
# cannot be passed to the native TreeWalker, so traversing them fails the test.
foreach ($condition in @('readonly','disabled','hidden')) {
    $element = TextField ($condition -eq 'readonly') 'input' 'yt-live-chat-text-input-field-renderer'
    $element.Current.IsEnabled = $condition -ne 'disabled'
    $element.Current.IsOffscreen = $condition -eq 'hidden'
    $records = @(Get-YouTubeInputRecords $element 123)
    Assert ($records.Count -eq 1 -and !(Get-YouTubeInputKind $records)) "invalid target stops before ancestor traversal: $condition"
}
foreach ($boundary in @('document','window')) {
    $element = TextField $false 'input' 'yt-live-chat-text-input-field-renderer'
    $element.Current.ControlType.Id = if ($boundary -eq 'document') { 50030 } else { 50026 }
    $element.Current | Add-Member NoteProperty NativeWindowHandle 0
    if ($boundary -eq 'window') { $element.Current.NativeWindowHandle = 123 }
    $records = @(Get-YouTubeInputRecords $element 123)
    Assert ($records.Count -eq 1 -and $records[0].Editable) "ancestry stops at its boundary without walking above it: $boundary"
}
# Address reads distinguish invalid controls from a valid address being edited.
$address=[pscustomobject]@{
    Current=[pscustomobject]@{IsOffscreen=$false;HasKeyboardFocus=$false}
    Pattern=[pscustomobject]@{Current=[pscustomobject]@{Value='https://www.youtube.com/watch?v=abcdefghijk'}}
    Available=$true; Reads=0
}
$address | Add-Member ScriptMethod TryGetCurrentPattern {
    param($kind,$result)
    $this.Reads++
    if (!$this.Available) { return $false }
    $result.Value=$this.Pattern
    return $true
}
Assert ((Read-AddressBarVideoId $address) -ceq 'abcdefghijk') 'address reads the current video'
$address.Pattern.Current.Value='https://youtu.be/ABCDEFGHIJK'
Assert ((Read-AddressBarVideoId $address) -ceq 'ABCDEFGHIJK') 'navigation is read afresh and preserves video case'
$address.Pattern.Current.Value='https://example.com/watch?v=abcdefghijk'
Assert ((Read-AddressBarVideoId $address) -eq '') 'visible non-YouTube address is unresolved rather than stale'
$address.Current.HasKeyboardFocus=$true
$reads=$address.Reads
Assert ((Read-AddressBarVideoId $address) -eq '' -and $address.Reads -eq $reads) 'editing the address returns no video without reading its value'
$address.Current.HasKeyboardFocus=$false
$address.Current.IsOffscreen=$true
$rejected=$false
try { $null=Read-AddressBarVideoId $address } catch { $rejected=$true }
Assert ($rejected -and $address.Reads -eq $reads) 'hidden control is invalidated without reading its value'
$address.Current.IsOffscreen=$false; $address.Available=$false
$rejected=$false
try { $null=Read-AddressBarVideoId $address } catch { $rejected=$true }
Assert $rejected 'missing value pattern invalidates the address control'
$address.Available=$true; $address.Pattern.Current.Value='https://www.youtube.com/watch?v=abcdefghijk'
Assert ((Read-AddressBarVideoId $address) -ceq 'abcdefghijk') 'valid address can be read after a rejected attempt'
# Substitute only native tree access; run the actual discovery and cache logic.
$addressReader=(Get-Command Read-BrowserVideoId).ScriptBlock
$discovery=$addressReader.ToString()
$rootRead='[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)'
$parentRead='[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)'
if (!$discovery.Contains($rootRead) -or !$discovery.Contains($parentRead)) { throw 'Address discovery boundary missing' }
Set-Item Function:Read-BrowserVideoId ([scriptblock]::Create($discovery.Replace($rootRead,'$script:AddressTestRoot').Replace($parentRead,'(Get-AddressTestParent $ancestor)')))
function AddressNode($Type, [int]$Handle, $Parent=$null) {
    return [pscustomobject]@{Current=[pscustomobject]@{ControlType=$Type;NativeWindowHandle=$Handle};Parent=$Parent}
}
function Get-AddressTestParent($Element) { return $Element.Parent }
$root=AddressNode ([System.Windows.Automation.ControlType]::Window) 123
$root.Current | Add-Member NoteProperty ProcessId 17
$root | Add-Member NoteProperty Elements @($address)
$root | Add-Member ScriptMethod FindAll { param($scope,$condition) return $this.Elements }
$script:AddressTestRoot=$root
$address.Current | Add-Member NoteProperty ControlType ([System.Windows.Automation.ControlType]::Edit)
$address.Current | Add-Member NoteProperty NativeWindowHandle 0
$address.Current | Add-Member NoteProperty AutomationId 'urlbar'
$address.Current | Add-Member NoteProperty Name 'Address'
$address | Add-Member NoteProperty Parent $null
try {
    foreach ($scenario in @('chrome','document','detached','different-window','deep-document','boundary','over-limit')) {
        $script:AddressBarCache.Clear()
        $parent=$root
        switch ($scenario) {
            'document' { $parent=AddressNode ([System.Windows.Automation.ControlType]::Document) 0 $root }
            'detached' { $parent=$null }
            'different-window' { $parent=AddressNode ([System.Windows.Automation.ControlType]::Window) 456 }
            'deep-document' {
                $parent=AddressNode ([System.Windows.Automation.ControlType]::Document) 0 $root
                foreach ($depth in 1..30) { $parent=AddressNode ([System.Windows.Automation.ControlType]::Pane) 0 $parent }
            }
            'boundary' { foreach ($depth in 1..28) { $parent=AddressNode ([System.Windows.Automation.ControlType]::Pane) 0 $parent } }
            'over-limit' { foreach ($depth in 1..29) { $parent=AddressNode ([System.Windows.Automation.ControlType]::Pane) 0 $parent } }
        }
        $address.Parent=$parent; $address.Reads=0
        $found=Read-BrowserVideoId 123
        $accepted=$scenario -in @('chrome','boundary')
        Assert (($found -ceq 'abcdefghijk') -eq $accepted) "address discovery requires proven browser chrome ancestry: $scenario"
        Assert ($script:AddressBarCache.ContainsKey([long]123) -eq $accepted -and $address.Reads -eq [int]$accepted) "unverified address candidates are neither read nor cached: $scenario"
    }
} finally {
    Set-Item Function:Read-BrowserVideoId $addressReader
    $script:AddressBarCache.Clear()
}
# Exercise focused-input publication while substituting only native observations.
$focusReader=(Get-Command Get-FocusedYouTubeInput).ScriptBlock
$recordReader=(Get-Command Get-YouTubeInputRecords).ScriptBlock
$windowCheck=(Get-Command Test-ElementWindow).ScriptBlock
$focusSource=$focusReader.ToString()
$focusRead='[System.Windows.Automation.AutomationElement]::FocusedElement'
$focusCompare='[System.Windows.Automation.Automation]::Compare($focused, $latest)'
if (!$focusSource.Contains($focusRead) -or !$focusSource.Contains($focusCompare)) { throw 'Focused input boundary missing' }
Set-Item Function:Get-FocusedYouTubeInput ([scriptblock]::Create($focusSource.Replace($focusRead,'(Get-TestFocusedElement)').Replace($focusCompare,'[object]::ReferenceEquals($focused, $latest)')))
function Get-TestFocusedElement {
    $script:FocusTestReads++
    if ($script:FocusTestScenario -eq 'missing') { return $null }
    if ($script:FocusTestScenario -eq 'changed' -and $script:FocusTestReads -eq 2) { return [pscustomobject]@{} }
    return $script:FocusTestTarget
}
function Test-ElementWindow($Element,$WindowHandle) {
    return $WindowHandle -eq 123 -and $script:FocusTestScenario -ne 'outside' -and
        !($script:FocusTestScenario -eq 'detached' -and $script:FocusTestReads -eq 2)
}
function Get-YouTubeInputRecords($Target,$WindowHandle) { return $Target.Records }
try {
    foreach ($scenario in @('chat','comment','missing','changed','outside','detached','unfocused','unknown')) {
        $script:FocusTestScenario=$scenario; $script:FocusTestReads=0
        $field=if ($scenario -eq 'comment') { Field 'contenteditable-root' } else { Field 'input' }
        $parent=if ($scenario -eq 'comment') { $commentParent } else { $chatParent }
        if ($scenario -eq 'unfocused') { $field.Focused=$false }
        if ($scenario -eq 'unknown') { $field.Id='unrecognized' }
        $script:FocusTestTarget=[pscustomobject]@{Records=@($field,$parent,$document)}
        $found=Get-FocusedYouTubeInput 123
        if ($scenario -in @('chat','comment')) {
            Assert ($found.Kind -eq $scenario -and [object]::ReferenceEquals($found.Element,$script:FocusTestTarget)) "focused result pairs classification with its verified element: $scenario"
        } else {
            Assert ($null -eq $found) "rejected focus publishes no partial result: $scenario"
        }
    }
} finally {
    Set-Item Function:Get-FocusedYouTubeInput $focusReader
    Set-Item Function:Get-YouTubeInputRecords $recordReader
    Set-Item Function:Test-ElementWindow $windowCheck
}
# Exercise the worker route without any UI, keystrokes or network.
$script:video = 'abcdefghijk'
$script:kind = 'comment'
function Read-BrowserVideoId($WindowHandle) { return $script:video }
function Get-FocusedYouTubeInput($WindowHandle) { if ($script:kind) { return @{Kind=$script:kind;Element="original"} } }
function Test-FocusedInputIdentity($VerifiedElement, $WindowHandle) { return $VerifiedElement -eq $script:focusedId -and !!$script:kind }
$script:focusedId = "original"
function Fetch-Metadata($Video) { throw 'Input verification must not fetch metadata' }
function Verify($video) { Invoke-WorkerRequest @{Mode='verify_input'; Seq=1; Window=123; Video=$video} }
Assert ((Verify '').State -eq 'ok') 'manual mode still verifies target'
Assert ((Verify 'abcdefghijk').Detail -eq 'comment') 'comment verification result'
Assert ((Verify 'ABCDEFGHIJK').State -eq 'changed') 'video mismatch rejected'
$script:kind = ''
Assert ((Verify '').State -eq 'wrong_input') 'unknown focus rejected'
$script:video = ''
Assert ((Verify '').State -eq 'unavailable') 'non YouTube target rejected'
$script:video = 'abcdefghijk'
$script:kind = 'chat'
$script:reads = 0
function Read-BrowserVideoId($WindowHandle) {
    $script:reads++
    if ($script:reads -eq 2) { $script:focusedId = 'another-editable-field' }
    return $script:video
}
Assert ((Verify '').State -eq 'wrong_input') 'focus changed during final URL read is rejected even if new field is editable'
$script:focusedId='original'
function Read-BrowserVideoId($WindowHandle) { return 'abcdefghijk' }
Assert ((Verify 'abcdefghijk').State -eq 'ok' -and (Verify 'abcdefghijk').Detail -eq 'chat') 'chat worker route succeeds'
$script:reads=0
function Read-BrowserVideoId($WindowHandle) {
    $script:reads++
    if ($script:reads -eq 1) { return 'abcdefghijk' }
    return 'ABCDEFGHIJK'
}
Assert ((Verify 'abcdefghijk').State -eq 'changed') 'video changes during input verification block input'
Write-Output "PASS: $script:checks input checks; no real UI or network used."
