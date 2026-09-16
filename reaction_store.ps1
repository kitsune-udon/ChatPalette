# Persistence of browser selectors. Publish only after the file is saved.
function Test-ReactionTokens($Tokens) {
    if (@($Tokens).Count -ne 5) { return $false }
    $signatures = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($token in $Tokens) {
        if ($null -eq $token -or $token.name -isnot [string] -or $token.id -isnot [string] -or $token.class -isnot [string]) { return $false }
        if (($token.type -isnot [int] -and $token.type -isnot [long]) -or $token.type -lt 50000 -or $token.type -gt 50040) { return $false }
        $signature = @($token.name, $token.id, $token.class, $token.type) | ConvertTo-Json -Compress
        if (!$signatures.Add($signature)) { return $false }
    }
    return $true
}

function Read-ReactionSelectors([string]$Path) {
    $result = @{}
    if (!(Test-Path -LiteralPath $Path)) { return $result }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.version -ne 1) { return $result }
        foreach ($entry in $saved.profiles) {
            if ($entry.browser -is [string] -and $entry.browser -and (Test-ReactionTokens $entry.tokens)) {
                $result[$entry.browser] = $entry
            }
        }
    } catch { $result.Clear() }
    return $result
}

function Save-ReactionSelectors([string]$Browser, $Entry) {
    if (!$Browser -or $Entry.browser -cne $Browser -or !(Test-ReactionTokens $Entry.tokens)) {
        throw 'Invalid reaction registration'
    }
    $candidate = @{}
    foreach ($key in $script:BrowserReactionSelectors.Keys) {
        $candidate[$key] = $script:BrowserReactionSelectors[$key]
    }
    $candidate[$Browser] = $Entry
    $temporary = $script:ReactionSelectorsPath + '.new'
    try {
        $json = @{version = 1; profiles = @($candidate.Values)} | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $script:ReactionSelectorsPath -Force -ErrorAction Stop
        $script:BrowserReactionSelectors = $candidate
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}
