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
    $temp = $CachePath + '.' + $PID + '.new'
    try {
        Trim-Cache
        $entries = @(foreach ($entry in $script:Videos.GetEnumerator()) {
            @{ video = $entry.Key; author = $entry.Value.Author; channel = $entry.Value.Channel; time = $entry.Value.Time.ToString('o') }
        })
        [IO.File]::WriteAllText($temp, (@{ version = 2; entries = $entries } | ConvertTo-Json -Depth 4), [Text.Encoding]::UTF8)
        Move-Item -LiteralPath $temp -Destination $CachePath -Force -ErrorAction Stop
    } catch { } # Memory caching still works if the file is not writable.
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
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
