$script:Videos = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$script:Failures = [Collections.Generic.Dictionary[string,datetime]]::new([StringComparer]::Ordinal)

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
    foreach ($key in @($script:Failures.Keys)) {
        $age = ($now - $script:Failures[$key]).TotalSeconds
        if ($age -ge 5 -or $age -lt 0) { $null = $script:Failures.Remove($key) }
    }
    if ($script:Videos.Count -gt 128) {
        $oldest = @($script:Videos.GetEnumerator() | Sort-Object { $_.Value.Time } | Select-Object -First ($script:Videos.Count - 128))
        foreach ($item in $oldest) { $null = $script:Videos.Remove($item.Key) }
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
    if ($script:Failures.ContainsKey($Video)) { return $null }
    try { $metadata = Fetch-Metadata $Video }
    catch {
        if ($script:Failures.Count -ge 128) { $script:Failures.Clear() }
        $script:Failures[$Video] = [DateTime]::UtcNow
        return $null
    }
    $script:Videos[$Video] = $metadata
    Trim-Cache
    return $metadata
}
