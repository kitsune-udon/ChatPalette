param([string]$PipeName, [int]$ParentProcessId, [string]$CachePath, [switch]$Library)
$ErrorActionPreference = 'Stop'
$script:Videos = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$script:Failures = [Collections.Generic.Dictionary[string,datetime]]::new([StringComparer]::Ordinal)
$script:AddressBarCache = @{}
. (Join-Path $PSScriptRoot 'reaction_automation.ps1')

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

function Get-ChannelKey([string]$AuthorUrl) {
    $uri = $null
    if (-not [Uri]::TryCreate($AuthorUrl, [UriKind]::Absolute, [ref]$uri)) { return '' }
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('youtube.com', 'www.youtube.com')) { return '' }
    $key = [Uri]::UnescapeDataString($uri.AbsolutePath).TrimEnd('/')
    if ($key -match '^/(@[^/\r\n]+|channel/[^/\r\n]+|user/[^/\r\n]+|c/[^/\r\n]+)$') { return $key }
    return ''
}

function Trim-Cache {
    $now = [DateTime]::UtcNow
    foreach ($key in @($script:Videos.Keys)) {
        $age = ($now - $script:Videos[$key].Time).TotalHours
        if ($age -ge 12 -or $age -lt 0) { $null = $script:Videos.Remove($key) }
    }
    if ($script:Videos.Count -gt 128) {
        $oldest = @($script:Videos.GetEnumerator() | Sort-Object { $_.Value.Time } | Select-Object -First ($script:Videos.Count - 128))
        foreach ($item in $oldest) { $null = $script:Videos.Remove($item.Key) }
    }
}

function Load-VideoCache {
    if (-not $CachePath -or -not (Test-Path -LiteralPath $CachePath)) { return }
    try {
        $data = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @($data.entries)) {
            if ($entry.video -cnotmatch '^[A-Za-z0-9_-]{11}$' -or -not $entry.author) { continue }
            $key = Get-ChannelKey ('https://www.youtube.com' + $entry.channel)
            if (-not $key) { continue }
            $script:Videos[$entry.video] = @{ Author = [string]$entry.author; Channel = $key; Time = [DateTime]::Parse($entry.time).ToUniversalTime() }
        }
        Trim-Cache
    } catch { $script:Videos.Clear() }
}

function Save-VideoCache {
    if (-not $CachePath) { return }
    try {
        Trim-Cache
        $entries = @(foreach ($entry in $script:Videos.GetEnumerator()) {
            @{ video = $entry.Key; author = $entry.Value.Author; channel = $entry.Value.Channel; time = $entry.Value.Time.ToString('o') }
        })
        $temp = $CachePath + '.' + $PID + '.new'
        [IO.File]::WriteAllText($temp, (@{ version = 2; entries = $entries } | ConvertTo-Json -Depth 4), [Text.Encoding]::UTF8)
        Move-Item -LiteralPath $temp -Destination $CachePath -Force
    } catch { } # Memory caching still works if the file is not writable.
}

function Fetch-Metadata([string]$Video) {
    $url = 'https://www.youtube.com/oembed?format=json&url=' + [Uri]::EscapeDataString('https://www.youtube.com/watch?v=' + $Video)
    $data = Invoke-RestMethod -Uri $url -TimeoutSec 4 -UseBasicParsing
    $key = Get-ChannelKey $data.author_url
    if (-not $key -or -not $data.author_name) { throw 'Missing author' }
    return @{ Author = [string]$data.author_name; Channel = $key; Time = [DateTime]::UtcNow }
}

function Resolve-Video([string]$Video) {
    Trim-Cache
    if ($script:Videos.ContainsKey($Video)) { return $script:Videos[$Video] }
    if ($script:Failures.ContainsKey($Video) -and ([DateTime]::UtcNow - $script:Failures[$Video]).TotalSeconds -lt 5) { return $null }
    try {
        $metadata = Fetch-Metadata $Video
        $script:Videos[$Video] = $metadata
        $null = $script:Failures.Remove($Video)
        Save-VideoCache
        return $metadata
    } catch {
        if ($script:Failures.Count -ge 128) { $script:Failures.Clear() }
        $script:Failures[$Video] = [DateTime]::UtcNow
        return $null
    }
}

function Invoke-WorkerRequest($Request) {
    if ($Request.Mode -in @('reaction_context', 'reaction_capture', 'reaction_check', 'reaction_send')) {
        return Invoke-ReactionRequest $Request
    }
    $reply = @{ Seq = $Request.Seq; State = 'unavailable'; Author = ''; Channel = ''; Video = ''; Window = $Request.Window }
    if ($Request.Mode -notin @('resolve', 'verify')) { return $reply }
    $video = Read-BrowserVideoId ([long]$Request.Window)
    $reply.Video = $video
    if (-not $video) { return $reply }
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

if ($Library) { return }
$pipe = $null
try {
    $parent = Get-Process -Id $ParentProcessId
    if ($parent.HasExited) { exit 1 }
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $reader = [IO.BinaryReader]::new($pipe, [Text.Encoding]::UTF8, $true)
    $writer = [IO.BinaryWriter]::new($pipe, [Text.Encoding]::UTF8, $true)
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Load-VideoCache
    while ($true) {
        # Blocks without polling. Closing/crashing the AHK server breaks the read.
        $request = Read-PipeRequest $reader
        try { $reply = Invoke-WorkerRequest $request }
        catch { $reply = @{ Seq = $request.Seq; Window = $request.Window; State = 'unavailable' } }
        Write-PipeReply $writer $reply
    }
} catch { exit 1 }
finally { if ($null -ne $pipe) { $pipe.Dispose() } }
