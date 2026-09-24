# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
. (Join-Path $release 'src\browser\browser_worker.ps1') -Library
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$script:checks=0
function Assert($value,$label) { if (!$value) { throw "FAIL: $label" }; $script:checks++ }
$document=@{Id='';Class='';Type=50030}
$chat=@{Id='';Class='yt-live-chat-renderer';Type=50033}
function Launcher([string]$Id='',[string]$Name='') { return @{Id=$Id;Name=$Name;Class='';Type=50000;Enabled=$true;Hidden=$false} }
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
$noPoint=[pscustomobject]@{}
$noPoint | Add-Member ScriptMethod TryGetClickablePoint { param($point) return $false }
Assert ($null -eq (Get-ReactionHoverPoint $noPoint)) 'unsupported hover point rejected without moving pointer'
$script:target=[System.Windows.Automation.AutomationElement]::RootElement
$script:video='abcdefghijk'; $script:foreground=$true; $script:belongs=$true
$script:pendingFocus=0; $script:changeAfterFocus=$false; $script:blurAfterFocus=$false; $script:identity=$true
$script:focusCalls=0; $script:hoverCalls=0; $script:missing=$false; $script:kind='chat'; $script:throwOnFocus=$false
$script:finalVideo='abcdefghijk'; $script:reads=0; $script:loseDuringPoint=$false
function Read-BrowserVideoId($WindowHandle) { $script:reads++; if ($script:reads -gt 1) { return $script:finalVideo }; return $script:video }
function Test-ReactionForeground($WindowHandle) { return $script:foreground }
function Test-ElementWindow($Element,$WindowHandle) { return $script:belongs }
function Find-ChatInput($WindowHandle) { if (!$script:missing) { return $script:target } }
function Find-ReactionLauncher($WindowHandle) { if (!$script:missing) { return $script:target } }
function Get-YouTubeInputRecords($Target,$WindowHandle) {
    return @(@{Id='input';Name='';Class='yt-live-chat-text-input-field-renderer';Type=50004;Focused=$false;Enabled=$true;Hidden=$false;Editable=$true},$document)
}
function Get-ReactionLauncherRecords($Target,$WindowHandle) { return @((Launcher 'reaction-control-panel'),$chat,$document) }
function Focus-ChatElement($Target) {
    $script:focusCalls++
    if ($script:throwOnFocus) { throw 'focus result unknown' }
    if ($script:changeAfterFocus) { $script:finalVideo='ABCDEFGHIJK' }
    if ($script:blurAfterFocus) { $script:foreground=$false }
}
function Get-FocusedYouTubeInput($WindowHandle,[ref]$VerifiedElement) {
    if ($script:pendingFocus -gt 0) { $script:pendingFocus--; return '' }
    $VerifiedElement.Value=$script:target; return $script:kind
}
function Test-FocusedInputIdentity($Element,$WindowHandle) { return $script:belongs -and $script:identity }
function Get-ReactionHoverPoint($Target) {
    if ($script:loseDuringPoint) { $script:foreground=$false }
    return @{X=20;Y=30}
}
function Move-PagePointer($Point) { $script:hoverCalls++; return $true }
function Get-ReactionInvoker($Target) { throw 'Page actions must never invoke a reaction' }
function Fetch-Metadata($Video) { throw 'Page actions must never fetch metadata' }
function Request($Mode,$Expected='') {
    $script:reads=0
    return Invoke-WorkerRequest @{Mode=$Mode;Window=123;Seq=1;Video=$Expected}
}
Assert ((Request 'chat_focus').State -eq 'focused' -and $script:focusCalls -eq 1) 'chat focus succeeds once'
Assert ((Request 'reactions_show').State -eq 'hovered' -and $script:hoverCalls -eq 1) 'launcher hovered without registration or invocation'
$script:missing=$true
Assert ((Request 'chat_focus').State -eq 'chat_missing') 'missing chat is distinguished from focus failure'
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
$script:kind='comment'
Assert ((Request 'verify_chat' 'abcdefghijk').State -eq 'wrong_input') 'clear validation never accepts comments'
$script:kind='chat'
Assert ((Request 'verify_chat' 'abcdefghijk').State -eq 'ok') 'clear validation accepts chat'
$script:belongs=$false
Assert ((Request 'verify_chat' 'abcdefghijk').State -eq 'wrong_input') 'clear validation requires exact focused identity'
$script:belongs=$true; $script:throwOnFocus=$true
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
Write-Output "PASS: $script:checks page action checks; no real typing, pointer movement or reactions."
