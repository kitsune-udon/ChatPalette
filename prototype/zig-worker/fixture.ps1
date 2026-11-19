[CmdletBinding()]
param(
    [ValidateSet('Chat','Comment','Search','Address','Popout','Changed','NonYouTube')]
    [string[]]$Scenario = @('Chat'),
    [Parameter(Mandatory=$true)][scriptblock]$Run,
    [string]$BrowserPath
)
$ErrorActionPreference = 'Stop'
# Start a fresh Chromium profile. Its test page is fulfilled locally over DevTools.
# Nothing here attaches to the user's browser or reads an input field's value.
if (!$BrowserPath) {
    $BrowserPath = @(
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe"
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (!$BrowserPath) { throw 'A Chromium browser is required. Supply -BrowserPath.' }
$browserFile = Get-Item -LiteralPath $BrowserPath
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes

function Send-Command([string]$Method, [hashtable]$Parameters) {
    $id = ++$script:commandId
    $json = @{id=$id; method=$Method; params=$Parameters} | ConvertTo-Json -Compress -Depth 8
    $data = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($json))
    $null = $socket.SendAsync($data, 'Text', $true, $deadline.Token).GetAwaiter().GetResult()
    return $id
}

function Receive-Message {
    $chunk = [ArraySegment[byte]]::new([byte[]]::new(8192))
    $stream = [IO.MemoryStream]::new()
    try {
        do {
            $result = $socket.ReceiveAsync($chunk, $deadline.Token).GetAwaiter().GetResult()
            if ($result.MessageType -ne 'Text') { throw 'Test page disconnected' }
            $stream.Write($chunk.Array, 0, $result.Count)
            if ($stream.Length -gt 1048576) { throw 'Unexpected DevTools message size' }
        } until ($result.EndOfMessage)
        return ([Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json)
    } finally { $stream.Dispose() }
}

function Invoke-CommandOnPage([string]$Method, [hashtable]$Parameters) {
    $deadline.CancelAfter(10000)
    try {
        $id = Send-Command $Method $Parameters
        while ($true) {
            $reply = Receive-Message
            if ($reply.error) { throw "Fixture DevTools error ($Method): $($reply.error.message)" }
            if ($reply.id -eq $id) { return $reply.result }
            if ($reply.method -eq 'Fetch.requestPaused') {
                $request = $reply.params
                if ($request.resourceType -eq 'Document' -and $request.request.url -ceq $pageUrl) {
                    $null = Send-Command 'Fetch.fulfillRequest' @{
                        requestId=$request.requestId; responseCode=200; body=$pageBody
                        responseHeaders=@(@{name='Content-Type';value='text/html; charset=utf-8'},@{name='Cache-Control';value='no-store'})
                    }
                } else {
                    $null = Send-Command 'Fetch.failRequest' @{requestId=$request.requestId; errorReason='BlockedByClient'}
                }
            }
        }
    } finally { $deadline.CancelAfter(-1) }
}

function Wait-Fixture([scriptblock]$Predicate, [string]$What) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($browser.HasExited) { throw "Fixture browser exited while waiting for $What" }
        $value = & $Predicate
        if ($value) { return $value }
        Start-Sleep -Milliseconds 75
    } while ($timer.Elapsed.TotalSeconds -lt 15)
    throw "Timed out waiting for $What"
}

$template = @'
<!doctype html><html lang="en"><meta charset="utf-8"><title>ChatPalette offline fixture</title>
<main><h1>ChatPalette offline fixture</h1>
<div class="yt-live-chat-text-input-field-renderer"><input id="input" aria-label="Chat"></div>
<div class="ytd-comment-simplebox-renderer"><div id="contenteditable-root" contenteditable="true" role="textbox" aria-label="Add a comment"></div></div>
<input id="search" aria-label="Search"><link rel="icon" href="data:,"></main></html>
'@
$pageBody = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($template))
$scratch = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$profile = Join-Path $scratch ('chatpalette-zig-fixture-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($profile)
$script:commandId = 0
$deadline = [Threading.CancellationTokenSource]::new()
$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.Options.Proxy = $null
$browser = $null
try {
    $arguments = @(
        ('--user-data-dir="' + $profile + '"'), '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
        '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
        '--disable-sync', '--disable-component-update', '--disable-background-mode', '--force-renderer-accessibility',
        '--proxy-server=http://127.0.0.1:9', '--host-resolver-rules="MAP * ~NOTFOUND"', 'about:blank'
    )
    # A visible window provides the actual address bar, editable field and keyboard focus to UIA.
    $browser = Start-Process -FilePath $browserFile.FullName -ArgumentList $arguments -PassThru
    $portFile = Join-Path $profile 'DevToolsActivePort'
    $port = Wait-Fixture {
        if (Test-Path -LiteralPath $portFile) {
            $lines = [IO.File]::ReadAllLines($portFile)
            if ($lines.Length -ge 2) { return [int]$lines[0] }
        }
    } 'the private debugging port'
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 5
    $tab = @($response | Where-Object { $_.type -eq 'page' -and $_.url -eq 'about:blank' })
    if ($tab.Count -ne 1) { throw 'Could not identify the newly opened test tab' }
    $endpoint = [uri]$tab[0].webSocketDebuggerUrl
    if ($endpoint.Scheme -ne 'ws' -or $endpoint.Host -ne '127.0.0.1' -or $endpoint.Port -ne $port) {
        throw 'Unexpected test tab endpoint'
    }
    $deadline.CancelAfter(5000)
    $null = $socket.ConnectAsync($endpoint,$deadline.Token).GetAwaiter().GetResult()
    $deadline.CancelAfter(-1)
    $null = Invoke-CommandOnPage 'Fetch.enable' @{patterns=@(@{urlPattern='*';requestStage='Request'})}
    $hwnd = Wait-Fixture { $browser.Refresh(); $browser.MainWindowHandle.ToInt64() } 'the browser window'
    foreach ($case in $Scenario) {
        $video = if ($case -eq 'Changed') { 'ZigTest0002' } else { 'ZigTest0001' }
        $site = if ($case -eq 'NonYouTube') { 'example.invalid' } else { 'www.youtube.com' }
        $page = if ($case -eq 'Popout') { 'live_chat' } else { 'watch' }
        $pageUrl = "https://$site/${page}?v=$video&fixture=$case"
        $target = switch ($case) { 'Comment' {'contenteditable-root'} 'Search' {'search'} default {'input'} }
        $null = Invoke-CommandOnPage 'Page.bringToFront' @{}
        $navigation = Invoke-CommandOnPage 'Page.navigate' @{url=$pageUrl}
        if ($navigation.errorText) { throw "Could not load the local test page: $($navigation.errorText)" }
        $null = Wait-Fixture {
            $expression = "location.href === '$pageUrl' && !!document.getElementById('$target') && (document.getElementById('$target').focus(),document.activeElement.id === '$target')"
            $evaluated = Invoke-CommandOnPage 'Runtime.evaluate' @{expression=$expression;returnByValue=$true}
            $evaluated.result.value
        } 'the locally supplied document and focused field'
        if ($case -eq 'Address') {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
            $rootCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit)
            $address = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$rootCondition) |
                Where-Object { $_.Current.AutomationId -in @('addressEditBox','urlbar-input','urlbar') -or
                    $_.Current.Name -match '(?i)address|アドレス|検索または.*URL|search or enter' } | Select-Object -First 1
            if (!$address) { throw 'Could not focus the test address bar' }
            $address.SetFocus()
            $null = Wait-Fixture { $address.Current.HasKeyboardFocus } 'address-bar focus'
        }
        $detectsVideo = $case -notin @('Address','NonYouTube')
        $inputState = switch ($case) {
            'Search' {'wrong_input'} 'Changed' {'changed'} 'Address' {'unavailable'} 'NonYouTube' {'unavailable'}
            default {'ok'}
        }
        $metadata = [pscustomobject]@{
            Scenario=$case; Browser=$browserFile.Name; Version=$browserFile.VersionInfo.FileVersion
            ExpectedVideo='ZigTest0001'; ActualVideo=$video; PageKind=$page
            ContextState=$(if ($detectsVideo) { 'ok' } else { 'unavailable' })
            DetectedVideo=$(if ($detectsVideo) { $video } else { '' })
            InputState=$inputState
            InputDetail=$(switch ($case) { 'Comment' {'comment'} 'Chat' {'chat'} 'Popout' {'chat'} default {''} })
        }
        & $Run $hwnd $metadata
    }
} finally {
    $socket.Dispose()
    $deadline.Dispose()
    try {
        if ($browser -and !$browser.HasExited) {
            $null = $browser.CloseMainWindow()
            if (!$browser.WaitForExit(5000)) { $browser.Kill(); $browser.WaitForExit() }
        }
    } finally { if ($browser) { $browser.Dispose() } }
    # Cleanup is limited to the newly generated, direct child of the temporary directory.
    $checked = Get-Item -Force -LiteralPath $profile
    if ($checked.Parent.FullName.TrimEnd('\') -ne $scratch.TrimEnd('\') -or
        $checked.Name -cnotmatch '^chatpalette-zig-fixture-[a-f0-9]{32}$' -or
        ($checked.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected fixture cleanup path' }
    Remove-Item -LiteralPath $checked.FullName -Recurse -Force
}
