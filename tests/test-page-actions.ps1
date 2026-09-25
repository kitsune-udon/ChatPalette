# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
# Inject ancestor property failures without querying the user's UIA tree.
$pageActions=Join-Path $release 'src\browser\page_actions.ps1'
$pageSource=[IO.File]::ReadAllText($pageActions)
$parentRead='[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($element)'
if (($pageSource.Split(@($parentRead),[StringSplitOptions]::None)).Count -ne 2) { throw 'Launcher ancestry boundary missing' }
[IO.File]::WriteAllText($pageActions,$pageSource.Replace($parentRead,'(Get-TestLauncherParent $element)'),[Text.UTF8Encoding]::new($true))
. (Join-Path $release 'src\browser\browser_worker.ps1') -Library
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$document=@{Id='';Class='';Type=50030}
$chat=@{Id='';Class='yt-live-chat-renderer';Type=50033}
function Launcher([string]$Id='',[string]$Name='') { return @{Id=$Id;Name=$Name;Class='';Type=50000;Enabled=$true;Hidden=$false} }
$script:AncestorAttributeReads=0
function Get-TestLauncherParent($Element) { return $Element.Parent }
function LauncherAncestor([int]$Type,[long]$Handle,$Parent) {
    $info=[pscustomobject]@{AutomationId='';ClassName='yt-live-chat-renderer';ControlType=[pscustomobject]@{Id=$Type};NativeWindowHandle=$Handle}
    foreach ($property in @('Name','IsEnabled','IsOffscreen')) {
        $info | Add-Member ScriptProperty $property { $script:AncestorAttributeReads++; throw 'Unused ancestor attribute is unavailable' }
    }
    return [pscustomobject]@{Current=$info;Parent=$Parent}
}
$ancestorDocument=LauncherAncestor 50030 0 $null
$ancestorChat=LauncherAncestor 50026 0 $ancestorDocument
$launcherTarget=[pscustomobject]@{Current=[pscustomobject]@{AutomationId='';ClassName='';ControlType=[pscustomobject]@{Id=50000};NativeWindowHandle=0;Name='Send a reaction';IsEnabled=$true;IsOffscreen=$false};Parent=$ancestorChat}
$observed=@(Get-ReactionLauncherRecords $launcherTarget 123)
Assert ($observed.Count -eq 3 -and (Test-ReactionLauncher $observed)) 'launcher remains recognizable when unused ancestor attributes are unavailable'
Assert ($script:AncestorAttributeReads -eq 0) 'launcher ancestry reads only structural attributes'
$ancestorChat.Parent=LauncherAncestor 50032 123 $null
$observed=@(Get-ReactionLauncherRecords $launcherTarget 123)
Assert ($observed.Count -eq 3 -and !(Test-ReactionLauncher $observed) -and $script:AncestorAttributeReads -eq 0) 'window boundary still rejects ancestry without a web document'
foreach ($field in @((Launcher 'reaction-control-panel'),(Launcher 'reaction-button'),(Launcher '' 'Send a reaction'),(Launcher '' 'リアクションを送信'))) {
    Assert (Test-ReactionLauncher @($field,$chat,$document)) 'recognized launcher in chat'
    Assert (!(Test-ReactionLauncher @($field,$document))) 'launcher outside chat rejected'
    Assert (!(Test-ReactionLauncher @($field,$chat))) 'browser chrome rejected'
    $field.Hidden=$true
    Assert (!(Test-ReactionLauncher @($field,$chat,$document))) 'hidden launcher rejected'
    $field.Hidden=$false; $field.Enabled=$false
    Assert (!(Test-ReactionLauncher @($field,$chat,$document))) 'disabled launcher rejected'
}
foreach ($name in @('Heart','ハート','いいね','送信','Send','😀','Show live chat')) {
    Assert (!(Test-ReactionLauncher @((Launcher '' $name),$chat,$document))) 'individual reaction/send/unrelated button rejected'
}
$heart=Launcher '' '❤'
$heart.Class='style-scope yt-reaction-control-panel-button-view-model'
$collapsed=@{Id='collapsed-button';Class='style-scope yt-reaction-control-panel-view-model';Type=50026}
Assert (Test-ReactionLauncher @($heart,$collapsed,$chat,$document)) 'observed Chromium collapsed launcher recognized structurally'
Assert (!(Test-ReactionLauncher @($heart,$chat,$document))) 'heart without collapsed launcher ancestry rejected'
$heart.Class='style-scope yt-reaction-button-view-model'
Assert (!(Test-ReactionLauncher @($heart,$collapsed,$chat,$document))) 'individual sending button never accepted as launcher'
# Selection uses validated field snapshots, without querying the live elements.
function Candidate($Field) {
    $element=[pscustomobject]@{}
    $element | Add-Member ScriptProperty Current { Assert $false 'Selection must not reread UI Automation properties' }
    return @{Element=$element;Field=$Field}
}
$collapsedField=Launcher '' '❤'
$collapsedField.Class='yt-reaction-control-panel-button-view-model'
$collapsedCandidate=Candidate $collapsedField
$panelCandidate=Candidate (Launcher 'reaction-control-panel')
$namedCandidate=Candidate (Launcher '' 'Send a reaction')
$buttonCandidate=Candidate (Launcher 'reaction-button')
foreach ($candidates in @(
    @($collapsedCandidate), @($panelCandidate,$collapsedCandidate,$namedCandidate),
    @($namedCandidate,$collapsedCandidate,$panelCandidate))) {
    Assert ([object]::ReferenceEquals((Select-ReactionLauncher $candidates),$collapsedCandidate.Element)) 'unique collapsed launcher takes precedence regardless of discovery order'
}
foreach ($candidates in @(@($panelCandidate),@($namedCandidate,$panelCandidate),@($panelCandidate,$buttonCandidate,$namedCandidate))) {
    Assert ([object]::ReferenceEquals((Select-ReactionLauncher $candidates),$panelCandidate.Element)) 'unique exact panel takes precedence over other launchers'
}
foreach ($candidate in @($namedCandidate,$buttonCandidate)) {
    Assert ([object]::ReferenceEquals((Select-ReactionLauncher @($candidate)),$candidate.Element)) 'single recognized fallback launcher is selected'
}
foreach ($candidates in @(
    @(), @($namedCandidate,$buttonCandidate),
    @($panelCandidate,(Candidate (Launcher 'reaction-control-panel')),$namedCandidate),
    @($collapsedCandidate,(Candidate $collapsedField),$panelCandidate))) {
    Assert ($null -eq (Select-ReactionLauncher $candidates)) 'missing or ambiguous preferred launchers have no fallback target'
}
$noPoint=[pscustomobject]@{}
$noPoint | Add-Member ScriptMethod TryGetClickablePoint { param($point) return $false }
Assert ($null -eq (Get-ReactionHoverPoint $noPoint)) 'unsupported hover point rejected without moving pointer'
# Exercise real discovery and classification with only UIA observations replaced.
$chatFinder=(Get-Command Find-ChatInput).ScriptBlock
$inputRecords=(Get-Command Get-YouTubeInputRecords).ScriptBlock
$elementWindow=(Get-Command Test-ElementWindow).ScriptBlock
$rootRead='[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)'
$discoverySource=$chatFinder.ToString()
if (($discoverySource.Split(@($rootRead),[StringSplitOptions]::None)).Count -ne 2) { throw 'Chat discovery root boundary missing' }
Set-Item Function:Find-ChatInput ([scriptblock]::Create($discoverySource.Replace($rootRead,'$script:ChatTestRoot')))
$script:ChatTestRoot=[pscustomobject]@{Candidates=@()}
$script:ChatTestRoot | Add-Member ScriptMethod FindAll { param($scope,$condition) return $this.Candidates }
function Test-ElementWindow($Element,$WindowHandle) { return $Element.Window -eq $WindowHandle }
function Get-YouTubeInputRecords($Target,$WindowHandle) {
    if ($Target.Detached) { throw 'Candidate detached during observation' }
    return $Target.Records
}
function ChatCandidate {
    return [pscustomobject]@{Window=123;Detached=$false;Records=@(
        @{Id='input';Name='';Class='yt-live-chat-text-input-field-renderer';Type=50004;Enabled=$true;Hidden=$false;Editable=$true},
        $document)}
}
try {
    $result=Find-ChatInput 123
    Assert ($result.State -eq 'chat_missing' -and $null -eq $result.Element) 'empty discovery reports missing without a target'
    $valid=ChatCandidate
    foreach ($invalidKind in @('hidden','disabled','read-only','comment','foreign','detached','no-document')) {
        $invalid=ChatCandidate
        switch ($invalidKind) {
            'hidden' { $invalid.Records[0].Hidden=$true }
            'disabled' { $invalid.Records[0].Enabled=$false }
            'read-only' { $invalid.Records[0].Editable=$false }
            'comment' { $invalid.Records[0].Id='contenteditable-root'; $invalid.Records[0].Class='ytd-comment-simplebox-renderer' }
            'foreign' { $invalid.Window=456 }
            'detached' { $invalid.Detached=$true }
            'no-document' { $invalid.Records=@($invalid.Records[0]) }
        }
        $script:ChatTestRoot.Candidates=@($invalid)
        $result=Find-ChatInput 123
        Assert ($result.State -eq 'chat_missing' -and $null -eq $result.Element) "$invalidKind candidate alone cannot become a chat target"
        $script:ChatTestRoot.Candidates=@($invalid,$valid)
        $result=Find-ChatInput 123
        Assert ($result.State -eq 'ok' -and [object]::ReferenceEquals($result.Element,$valid)) "$invalidKind candidate does not hide the unique valid chat"
    }
    $other=ChatCandidate
    foreach ($candidates in @(@($valid,$other),@($other,$valid))) {
        $script:ChatTestRoot.Candidates=$candidates
        $result=Find-ChatInput 123
        Assert ($result.State -eq 'chat_ambiguous' -and $null -eq $result.Element) 'multiple valid chats yield no target regardless of discovery order'
    }
} finally {
    Set-Item Function:Find-ChatInput $chatFinder
    Set-Item Function:Get-YouTubeInputRecords $inputRecords
    Set-Item Function:Test-ElementWindow $elementWindow
}
$script:target=[System.Windows.Automation.AutomationElement]::RootElement
$script:video='abcdefghijk'; $script:foreground=$true; $script:belongs=$true
$script:pendingFocus=0; $script:changeAfterFocus=$false; $script:blurAfterFocus=$false; $script:identity=$true
$script:chatFailure=''
$script:focusCalls=0; $script:hoverCalls=0; $script:missing=$false; $script:kind='chat'; $script:throwOnFocus=$false
$script:finalVideo='abcdefghijk'; $script:reads=0; $script:loseDuringPoint=$false
function Read-BrowserVideoId($WindowHandle) { $script:reads++; if ($script:reads -gt 1) { return $script:finalVideo }; return $script:video }
function Test-ReactionForeground($WindowHandle) { return $script:foreground }
function Test-ElementWindow($Element,$WindowHandle) { return $script:belongs }
function Find-ChatInput($WindowHandle) {
    if ($script:chatFailure) { return @{State=$script:chatFailure;Element=$null} }
    return @{State='ok';Element=$script:target}
}
function Find-ReactionLauncher($WindowHandle) { if (!$script:missing) { return $script:target } }
$script:chatField=@{Id='input';Name='';Class='yt-live-chat-text-input-field-renderer';Type=50004;Focused=$false;Enabled=$true;Hidden=$false;Editable=$true}
function Get-YouTubeInputRecords($Target,$WindowHandle) {
    return @($script:chatField,$document)
}
function Get-ReactionLauncherRecords($Target,$WindowHandle) { return @((Launcher 'reaction-control-panel'),$chat,$document) }
function Focus-ChatElement($Target) {
    $script:focusCalls++
    if ($script:throwOnFocus) { throw 'focus result unknown' }
    if ($script:changeAfterFocus) { $script:finalVideo='ABCDEFGHIJK' }
    if ($script:blurAfterFocus) { $script:foreground=$false }
}
function Get-FocusedYouTubeInput($WindowHandle) {
    if ($script:pendingFocus -gt 0) { $script:pendingFocus--; return $null }
    if ($script:kind) { return @{Kind=$script:kind;Element=$script:target} }
}
function Test-FocusedInputIdentity($Element,$WindowHandle) { return $script:belongs -and $script:identity }
function Get-ReactionHoverPoint($Target) {
    if ($script:loseDuringPoint) { $script:foreground=$false }
    return @{X=20;Y=30}
}
function Move-PagePointer($Point) { $script:hoverCalls++; return $true }
function Get-ReactionInvoker($Target) { Assert $false 'Page actions must never invoke a reaction' }
function Fetch-Metadata($Video) { Assert $false 'Page actions must never fetch metadata' }
function Request($Mode,$Expected='') {
    $script:reads=0
    return Invoke-WorkerRequest @{Mode=$Mode;Window=123;Seq=1;Video=$Expected}
}
Assert ((Request 'chat_focus').State -eq 'focused' -and $script:focusCalls -eq 1) 'chat focus succeeds once'
Assert (!$script:chatField.Focused) 'focus discovery preserves the observed input record'
Assert ((Request 'reactions_show').State -eq 'hovered' -and $script:hoverCalls -eq 1) 'launcher hovered without registration or invocation'
$script:missing=$true
foreach ($state in @('chat_missing','chat_ambiguous')) {
    $script:chatFailure=$state
    Assert ((Request 'chat_focus').State -eq $state -and $script:focusCalls -eq 1) "$state discovery prevents focus and preserves its reason"
}
$script:chatFailure=''
Assert ((Request 'reactions_show').State -eq 'unsupported') 'missing or ambiguous launcher rejected'
$script:missing=$false; $script:foreground=$false
foreach ($mode in @('chat_focus','reactions_show')) { Assert ((Request $mode).State -eq 'wrong_window') 'background browser rejected' }
$script:foreground=$true; $script:finalVideo='ABCDEFGHIJK'
foreach ($mode in @('chat_focus','reactions_show')) { Assert ((Request $mode).State -eq 'changed') 'navigation during discovery rejected' }
$script:finalVideo='abcdefghijk'; $script:belongs=$false
Assert ((Request 'chat_focus').State -eq 'wrong_window') 'wrong window chat rejected'
Assert ((Request 'reactions_show').State -eq 'unsupported') 'wrong window launcher rejected'
$script:belongs=$true; $script:video=''
foreach ($mode in @('chat_focus','reactions_show')) { Assert ((Request $mode).State -eq 'unavailable') 'unknown URL rejected' }
$script:video='abcdefghijk'; $script:loseDuringPoint=$true
Assert ((Request 'reactions_show').State -eq 'wrong_window' -and $script:hoverCalls -eq 1) 'foreground switch after geometry lookup prevents pointer movement'
$script:loseDuringPoint=$false; $script:foreground=$true
Assert ($script:focusCalls -eq 1 -and $script:hoverCalls -eq 1) 'all rejected requests have no page effects'
$script:throwOnFocus=$true
Assert ((Request 'chat_focus').State -eq 'unknown' -and $script:focusCalls -eq 2) 'uncertain focus never retries'
$script:throwOnFocus=$false; $script:pendingFocus=2
$before=$script:focusCalls
Assert ((Request 'chat_focus').State -eq 'focused' -and $script:focusCalls -eq ($before+1)) 'delayed focus observation succeeds with one focus operation'
$script:kind=''
$before=$script:focusCalls
Assert ((Request 'chat_focus').State -eq 'focus_failed' -and $script:focusCalls -eq ($before+1)) 'unconfirmed focus stops after bounded observation without retrying action'
$script:kind='comment'
Assert ((Request 'chat_focus').State -eq 'focus_failed') 'different editable field is never accepted'
$script:kind='chat'; $script:identity=$false
Assert ((Request 'chat_focus').State -eq 'focus_failed') 'identity lost during final URL read rejected'
$script:identity=$true; $script:changeAfterFocus=$true
Assert ((Request 'chat_focus').State -eq 'changed') 'navigation after focus is rejected'
$script:changeAfterFocus=$false; $script:finalVideo='abcdefghijk'; $script:blurAfterFocus=$true
Assert ((Request 'chat_focus').State -eq 'wrong_window') 'foreground loss after focus is rejected'
$script:blurAfterFocus=$false; $script:foreground=$true
$focused=Request 'chat_focus'
Assert (![string]::IsNullOrEmpty($focused.Detail)) 'successful focus returns an identity token'
$script:reads=0
$verified=Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=2;Video='abcdefghijk';FocusToken=$focused.Detail}
Assert ($verified.State -eq 'ok') 'focused element token is accepted once'
$script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=3;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'wrong_input') 'consumed token cannot be reused'
$focused=Request 'chat_focus'; $script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=4;Video='abcdefghijk';FocusToken='stale'}).State -eq 'wrong_input') 'stale or foreign token rejected'
$focused=Request 'chat_focus'
$script:FocusedChat.Window=999; $script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=5;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'wrong_input') 'token for another window rejected'
$focused=Request 'chat_focus'
$other=[System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
Assert ($null -ne $other) 'desktop supplies a distinct element for identity rejection'
$script:FocusedChat.Element=$other; $script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=6;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'wrong_input') 'another chat-kind element cannot substitute for the focused target'
$focused=Request 'chat_focus'; $script:kind='comment'; $script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=7;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'wrong_input') 'comment field rejects deferred delivery'
$script:kind='chat'; $script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=8;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'wrong_input') 'failed verification also consumes the token'
# Chat verification has one meaning: consume the exact focus proof, including failures.
foreach ($tokenForm in @('missing','empty')) {
    $focused=Request 'chat_focus'
    $request=@{Mode='verify_chat';Window=123;Seq=9;Video='abcdefghijk'}
    if ($tokenForm -eq 'empty') { $request.FocusToken='' }
    $script:reads=0
    Assert ((Invoke-WorkerRequest $request).State -eq 'wrong_input') "chat verification rejects $tokenForm proof instead of accepting any chat"
    Assert ($null -eq $script:FocusedChat -and $script:reads -eq 0) "invalid $tokenForm proof is consumed before browser inspection"
}
$focused=Request 'chat_focus'; $script:belongs=$false; $script:reads=0
Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=10;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'wrong_input') 'chat verification still rejects identity lost after a valid proof'
$script:belongs=$true
foreach ($mode in @('browser_context','verify_input')) {
    $focused=Request 'chat_focus'
    $ownedProof=$script:FocusedChat; $script:reads=0
    $reply=Invoke-WorkerRequest @{Mode=$mode;Window=123;Seq=11;Video='abcdefghijk';FocusToken='unrelated'}
    Assert ($reply.State -eq 'ok' -and [object]::ReferenceEquals($script:FocusedChat,$ownedProof)) "$mode does not consume another operation's focus proof"
    $script:reads=0
    Assert ((Invoke-WorkerRequest @{Mode='verify_chat';Window=123;Seq=12;Video='abcdefghijk';FocusToken=$focused.Detail}).State -eq 'ok') 'the owning chat verification can still consume its preserved proof'
}
Write-Output "PASS: $script:checks page action checks; no real typing, pointer movement or reactions."
