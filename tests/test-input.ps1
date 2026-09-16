. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
. (Join-Path $release 'browser_worker.ps1') -Library
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
foreach ($name in @('コメントを追加…','Add a comment...','返信を入力','Add a reply…')) {
    Assert ((Get-YouTubeInputKind @((Field '' $name),$document)) -eq 'comment') "named comment: $name"
}
Assert (!(Get-YouTubeInputKind @((Field 'search' 'Search'),$document))) 'search rejected'
Assert (!(Get-YouTubeInputKind @((Field 'urlbar' 'コメントを追加…'),$document))) 'address bar rejected'
Assert (!(Get-YouTubeInputKind @((Field 'contenteditable-root'),$document))) 'ambiguous editor rejected'
Assert (!(Get-YouTubeInputKind @((Field 'input'),$chatParent))) 'outside web document rejected'
foreach ($change in @('Hidden','Enabled','Editable','Focused')) {
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
    $record = Get-InputRecord (TextField $false $spec[0] $spec[1]) $true
    Assert ((Get-YouTubeInputKind @($record,$document)) -eq $spec[2]) "editable Custom/TextPattern: $($spec[2])"
    foreach ($readOnly in @($true,[System.Windows.Automation.AutomationElement]::NotSupported,[System.Windows.Automation.TextPattern]::MixedAttributeValue)) {
        $record = Get-InputRecord (TextField $readOnly $spec[0] $spec[1]) $true
        Assert (!(Get-YouTubeInputKind @($record,$document))) 'read-only or unknown TextPattern rejected'
    }
}
$record = Get-InputRecord (TextField $false 'search' '') $true
Assert (!(Get-YouTubeInputKind @($record,$document))) 'editable Custom search rejected'
$record = Get-InputRecord (TextField $false 'other-editor' '') $true
Assert (!(Get-YouTubeInputKind @($record,$document))) 'unknown Custom editor rejected'
$record = Get-InputRecord (TextField $false 'contenteditable-root' 'style-scope yt-formatted-string') $true
Assert ((Get-YouTubeInputKind @($record,
    @{Id='contenteditable-textarea'; Class='style-scope ytd-commentbox'; Type=50026},
    @{Id='commentbox'; Class='style-scope ytd-comment-dialog-renderer'; Type=50026},
    $document)) -eq 'comment') 'observed comment ancestry without a label'
# Exercise the worker route without any UI, keystrokes or network.
$script:video = 'abcdefghijk'
$script:kind = 'comment'
function Read-BrowserVideoId($WindowHandle) { return $script:video }
function Get-FocusedYouTubeInput($WindowHandle) { return $script:kind }
function Fetch-Metadata($Video) { throw 'Input verification must not fetch metadata' }
function Verify($video) { Invoke-WorkerRequest @{Mode='verify_input'; Seq=1; Window=123; Video=$video} }
Assert ((Verify '').State -eq 'ok') 'manual mode still verifies target'
Assert ((Verify 'abcdefghijk').Detail -eq 'comment') 'comment verification result'
Assert ((Verify 'ABCDEFGHIJK').State -eq 'changed') 'video mismatch rejected'
$script:kind = ''
Assert ((Verify '').State -eq 'wrong_input') 'unknown focus rejected'
$script:video = ''
Assert ((Verify '').State -eq 'unavailable') 'non YouTube target rejected'
Write-Output "PASS: $script:checks input checks; no real UI or network used."
