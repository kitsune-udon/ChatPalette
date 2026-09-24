param([string]$PipeName, [int]$ParentProcessId, [switch]$Library)
$ErrorActionPreference = 'Stop'
$script:AddressBarCache = @{}
$script:FocusedChat = $null
. (Join-Path $PSScriptRoot 'reaction_automation.ps1')
. (Join-Path $PSScriptRoot 'video_metadata.ps1')
. (Join-Path $PSScriptRoot 'input_target.ps1')
. (Join-Path $PSScriptRoot 'page_actions.ps1')

function Get-VideoId([string]$Address) {
    if ($Address -notmatch '^https?://') { $Address = 'https://' + $Address }
    $uri = $null
    if (-not [Uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri)) { return '' }
    if ($uri.Host -notin @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be')) { return '' }
    $id = ''
    if ($uri.Host -eq 'youtu.be') { $id = $uri.AbsolutePath.Trim('/') }
    elseif ($uri.AbsolutePath -match '^/(live|shorts|embed)/([^/]+)') { $id = $Matches[2] }
    elseif ($uri.AbsolutePath -in @('/watch', '/live_chat', '/live_chat_replay')) {
        foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
            if ($pair -cmatch '^v=([^&]+)$') { $id = $Matches[1]; break }
        }
    }
    if ($id -cmatch '^[A-Za-z0-9_-]{11}$') { return $id }
    return ''
}

function Read-AddressBarVideoId($Element) {
    $info = $Element.Current
    if ($info.IsOffscreen -or $info.HasKeyboardFocus) { return '' }
    $pattern = $null
    if (-not $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        throw 'Address element became unavailable'
    }
    return Get-VideoId $pattern.Current.Value
}

function Read-BrowserVideoId([long]$WindowHandle) {
    if ($WindowHandle -le 0) { return '' }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    $processId = $root.Current.ProcessId
    if ($script:AddressBarCache.ContainsKey($WindowHandle)) {
        $entry = $script:AddressBarCache[$WindowHandle]
        if ($entry.ProcessId -eq $processId) {
            try {
                if ($entry.Element.Current.IsOffscreen) { throw 'Address control was replaced or hidden' }
                return Read-AddressBarVideoId $entry.Element
            } catch { }
        }
        $script:AddressBarCache.Remove($WindowHandle)
    }
    # Cache the control, never its URL. Always read the CURRENT value.
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)
    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    foreach ($edit in $edits) {
        try {
            $info = $edit.Current
            if ($info.AutomationId -notin @('addressEditBox', 'urlbar-input', 'urlbar') -and
                $info.Name -notmatch '(?i)address|アドレス|検索または.*URL|search or enter') { continue }
            $ancestor = $edit
            $insideDocument = $false
            for ($depth = 0; $depth -lt 30 -and $null -ne $ancestor; $depth++) {
                if ($ancestor.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document) {
                    $insideDocument = $true; break
                }
                $ancestor = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
            }
            if ($insideDocument -or $info.IsOffscreen) { continue }
            $video = Read-AddressBarVideoId $edit
            if ($script:AddressBarCache.Count -ge 16) { $script:AddressBarCache.Clear() }
            $script:AddressBarCache[$WindowHandle] = @{ ProcessId = $processId; Element = $edit }
            return $video
        } catch { continue }
    }
    return ''
}

function Invoke-WorkerRequest($Request) {
    if ($Request.Mode -in @('chat_focus','reactions_show')) { return Invoke-PageAction $Request }
    if ($Request.Mode -eq 'reaction_configure') {
        Set-ReactionRegistrationSnapshot $Request.Payload
        return @{Seq=$Request.Seq; Window=$Request.Window; State='configured'}
    }
    if ($Request.Mode -eq 'reaction_status') {
        $browser = Get-BrowserProcessName ([long]$Request.Window)
        $state = if (-not $browser) { 'unavailable' } elseif ($script:BrowserReactionSelectors.ContainsKey($browser)) { 'configured' } else { 'not_registered' }
        return @{ Seq=$Request.Seq; Window=$Request.Window; State=$state }
    }
    if ($Request.Mode -in @('reaction_capture', 'reaction_check', 'reaction_send')) {
        return Invoke-ReactionRequest $Request
    }
    $reply = @{ Seq = $Request.Seq; State = 'unavailable'; Author = ''; Channel = ''; Video = ''; Window = $Request.Window }
    if ($Request.Mode -notin @('browser_context', 'resolve', 'verify', 'verify_input', 'verify_chat')) { return $reply }
    $focus = $null
    if ($Request.FocusToken) {
        $focus = $script:FocusedChat
        $script:FocusedChat = $null # Consume even when verification fails.
    }
    $video = Read-BrowserVideoId ([long]$Request.Window)
    $reply.Video = $video
    if (-not $video) { return $reply }
    if ($Request.Mode -eq 'browser_context') { $reply.State = 'ok'; return $reply }
    if ($Request.Mode -in @('verify_input','verify_chat')) {
        if ($Request.Video -and $video -cne $Request.Video) { $reply.State = 'changed'; return $reply }
        $verifiedElement = $null
        $kind = Get-FocusedYouTubeInput ([long]$Request.Window) ([ref]$verifiedElement)
        if (!$kind -or ($Request.Mode -eq 'verify_chat' -and $kind -ne 'chat')) { $reply.State = 'wrong_input'; return $reply }
        if ($Request.FocusToken) {
            if ($null -eq $focus -or $focus.Token -cne $Request.FocusToken -or
                $focus.Window -ne [long]$Request.Window -or $focus.Video -cne $video -or
                $kind -ne 'chat' -or !(Test-ReactionForeground ([long]$Request.Window)) -or
                ![System.Windows.Automation.Automation]::Compare($focus.Element,$verifiedElement)) {
                $reply.State = 'wrong_input'; return $reply
            }
        }
        if ((Read-BrowserVideoId ([long]$Request.Window)) -cne $video) { $reply.State = 'changed'; return $reply }
        if (!(Test-FocusedInputIdentity $verifiedElement ([long]$Request.Window))) { $reply.State = 'wrong_input'; return $reply }
        $reply.State = 'ok'
        $reply.Detail = $kind
        return $reply
    }
    if ($Request.Mode -eq 'verify') {
        $reply.State = if ($video -ceq $Request.Video) { 'ok' } else { 'changed' }
        return $reply # No metadata lookup or network in the verify path.
    }
    $metadata = Resolve-Video $video
    if ($null -eq $metadata) { return $reply }
    if ((Read-BrowserVideoId ([long]$Request.Window)) -cne $video) { $reply.State = 'changed'; return $reply }
    $reply.State = 'ok'
    $reply.Author = $metadata.Author
    $reply.Channel = $metadata.Channel
    return $reply
}

function Read-PipeRequest($Reader) {
    $length = $Reader.ReadInt32()
    if ($length -le 0 -or $length -gt 32768) { throw 'Invalid frame length' }
    $bytes = $Reader.ReadBytes($length)
    if ($bytes.Length -ne $length) { throw 'Incomplete request' }
    $request = @{}
    foreach ($line in [Text.Encoding]::UTF8.GetString($bytes).Split("`n")) {
        if ($line -match '^([A-Za-z]+)=(.*)$') { $request[$Matches[1]] = $Matches[2] }
    }
    if ($request.Seq -notmatch '^\d+$' -or $request.Window -notmatch '^\d+$') { throw 'Invalid request' }
    return $request
}

function Write-PipeReply($Writer, $Reply) {
    $lines = @()
    foreach ($key in @('Seq', 'State', 'Author', 'Channel', 'Video', 'Window', 'Detail')) {
        $lines += $key + '=' + ([string]$Reply[$key] -replace '[\r\n]', ' ')
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    if ($bytes.Length -gt 32768) { throw 'Reply too large' }
    $Writer.Write([int]$bytes.Length)
    $Writer.Write([byte[]]$bytes)
    $Writer.Flush()
}

function Start-BrowserWorker([string]$PipeName, [int]$ParentProcessId,
    [scriptblock]$Handler = { param($request) Invoke-WorkerRequest $request }) {
    $pipe = $null
    $signal = $null
    try {
        $parent = Get-Process -Id $ParentProcessId
        if ($parent.HasExited) { exit 1 }
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(5000)
        $signal = [Threading.EventWaitHandle]::OpenExisting($PipeName + '-ready')
        $null = $signal.Set()
        $reader = [IO.BinaryReader]::new($pipe, [Text.Encoding]::UTF8, $true)
        $writer = [IO.BinaryWriter]::new($pipe, [Text.Encoding]::UTF8, $true)
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        while ($true) {
            # Blocks without polling. Closing/crashing the AHK server breaks the read.
            $request = Read-PipeRequest $reader
            try { $reply = & $Handler $request }
            catch { $reply = @{ Seq = $request.Seq; Window = $request.Window; State = 'unavailable' } }
            Write-PipeReply $writer $reply
            $null = $signal.Set()
        }
    } catch { exit 1 }
    finally {
        if ($null -ne $pipe) { $pipe.Dispose() }
        if ($null -ne $signal) { $signal.Dispose() }
    }
}
if (!$Library) { Start-BrowserWorker $PipeName $ParentProcessId }
