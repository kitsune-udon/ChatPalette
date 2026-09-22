# Test-Session: Headless
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
. (Join-Path $release 'src\browser\reaction_automation.ps1')
$tokens = @(1..5 | ForEach-Object { [pscustomobject]@{name="reaction$_"; id="id$_"; class='button'; type=50000} })
$entry = [pscustomobject]@{browser='fixture'; tokens=$tokens}
$payload = @{version=1; profiles=@($entry)} | ConvertTo-Json -Depth 8 -Compress
Set-ReactionRegistrationSnapshot $payload
$old = $script:BrowserReactionSelectors
$oldPlan=Get-ReactionPlan $old['fixture']
$script:ReactionElementCache[123L]=@{Plan=$oldPlan;Elements=@()}
if ($old.Count -ne 1 -or !$old.ContainsKey('fixture')) { throw 'Snapshot not loaded' }
$invalid = [pscustomobject]@{browser='invalid'; tokens=@($tokens[0],$tokens[0],$tokens[0],$tokens[0],$tokens[0])}
foreach ($bad in @('{', (@{version=99;profiles=@($entry)} | ConvertTo-Json -Depth 8), (@{version=1;profiles=@($entry,$invalid)} | ConvertTo-Json -Depth 8))) {
    $failed=$false
    try { Set-ReactionRegistrationSnapshot $bad } catch { $failed=$true }
    if (!$failed -or ![object]::ReferenceEquals($old,$script:BrowserReactionSelectors)) { throw 'Invalid snapshot changed memory' }
    if (!$script:ReactionElementCache.ContainsKey(123L) -or ![object]::ReferenceEquals($oldPlan,(Get-ReactionPlan $old['fixture']))) { throw 'Failed snapshot invalidated valid runtime state' }
}
Set-ReactionRegistrationSnapshot '{"version":1,"profiles":[]}'
if ($script:BrowserReactionSelectors.Count -or $script:ReactionElementCache.Count) { throw 'Empty snapshot failed to clear registrations and references' }
# Memory cache reuses successful lookups, expires entries and bounds retries.
$script:Videos = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$script:Failures = [Collections.Generic.Dictionary[string,datetime]]::new([StringComparer]::Ordinal)
. (Join-Path $release 'src\browser\video_metadata.ps1')
$script:fetches = 0
function Fetch-Metadata($Video) {
    $script:fetches++
    if ($Video -ceq 'failure0000') { throw 'fake failure' }
    return @{Author='fixture'; Channel='/channel/test'; Time=[DateTime]::UtcNow}
}
function Get-RuntimeFileSnapshot {
    return @(Get-ChildItem -LiteralPath $release -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
}
$before = Get-RuntimeFileSnapshot
$null=Resolve-Video 'abcdefghijk'
$null=Resolve-Video 'abcdefghijk'
if ($script:fetches -ne 1) { throw 'Memory hit fetched again' }
$script:Videos['abcdefghijk'].Time=[DateTime]::UtcNow.AddHours(-12)
$null=Resolve-Video 'abcdefghijk'
if ($script:fetches -ne 2) { throw 'Expired entry not refetched' }
$script:Videos['abcdefghijk'].Time=[DateTime]::UtcNow.AddHours(1)
$null=Resolve-Video 'abcdefghijk'
if ($script:fetches -ne 3) { throw 'Future entry retained' }
$null=Resolve-Video 'failure0000'
$null=Resolve-Video 'failure0000'
if ($script:fetches -ne 4) { throw 'Failure retry not suppressed' }
$script:Failures['failure0000']=[DateTime]::UtcNow.AddSeconds(-6)
$null=Resolve-Video 'failure0000'
if ($script:fetches -ne 5) { throw 'Failure retry not released' }
foreach ($i in 1..140) { $null=Resolve-Video ('v{0:d10}' -f $i) }
if ($script:Videos.Count -ne 128 -or !$script:Videos.ContainsKey('v0000000140')) { throw 'Cache did not retain bounded recent entries' }
$script:Videos['expired0000']=@{Author='old';Channel='/channel/test';Time=[DateTime]::UtcNow.AddHours(-13)}
$script:Videos['abcdefghijk']=@{Author='recent';Channel='/channel/test';Time=[DateTime]::UtcNow}
Trim-Cache
if ($script:Videos.ContainsKey('expired0000') -or !$script:Videos.ContainsKey('abcdefghijk') -or $script:Videos.Count -ne 128) { throw 'Expiry removed fresh entries or retained stale entries' }
$script:Videos.Clear()
$prior=$script:fetches
$null=Resolve-Video 'abcdefghijk'
if ($script:fetches -ne $prior+1) { throw 'Empty cache failed to fetch' }
$after = Get-RuntimeFileSnapshot
if (Compare-Object $before $after) { throw 'Memory caching created or changed files' }
$video = $script:Videos['abcdefghijk']
$script:ReactionElementCache[123L]=@{Elements=@()}
Set-ReactionRegistrationSnapshot $payload
$plan=Get-ReactionPlan $script:BrowserReactionSelectors['fixture']
if ($script:ReactionElementCache.Count -ne 0 -or ![object]::ReferenceEquals($video,$script:Videos['abcdefghijk'])) { throw 'Registration sync did not preserve metadata or invalidate elements' }
Set-ReactionRegistrationSnapshot $payload
if ([object]::ReferenceEquals($plan,(Get-ReactionPlan $script:BrowserReactionSelectors['fixture']))) { throw 'Registration replacement reused stale plan' }
Write-Output 'PASS: registration invalidation and memory-only metadata caching.'
