# Validate and publish committed registrations in worker memory. No disk access.
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

# Own only validated lookup fields; decoded input objects are never retained.
function New-ReactionPlan($Tokens) {
    if (!(Test-ReactionTokens $Tokens)) { throw 'Invalid registration tokens' }
    return @{Tokens=@(foreach ($token in $Tokens) {
        @{name=$token.name; id=$token.id; class=$token.class; type=$token.type}
    })}
}

# Replace the in-memory snapshot only after every registration validates.
function Set-ReactionRegistrationSnapshot([string]$Payload) {
    $saved = $Payload | ConvertFrom-Json
    if ($saved.version -ne 1 -or $saved.profiles -isnot [array]) { throw 'Invalid registration snapshot' }
    $candidate = @{}
    foreach ($entry in $saved.profiles) {
        if ($entry.browser -isnot [string] -or $entry.browser -cnotmatch '^[a-z][a-z0-9_-]{0,63}$' -or $candidate.ContainsKey($entry.browser)) { throw 'Invalid registration entry' }
        # Accept only persisted fields, never caller-provided runtime plans.
        $candidate[$entry.browser] = New-ReactionPlan $entry.tokens
    }
    $script:BrowserReactionSelectors = $candidate
    $script:ReactionElementCache.Clear()
}
