# Test-Session: Headless
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
. (Join-Path $release 'src\browser\reaction_automation.ps1')
$tokens = @(1..5 | ForEach-Object { [pscustomobject]@{name="reaction$_"; id="id$_"; class='button'; type=50000} })
$entry = [pscustomobject]@{browser='fixture'; tokens=$tokens}
$payload = @{version=1; profiles=@($entry)} | ConvertTo-Json -Depth 8 -Compress
Set-ReactionRegistrationSnapshot $payload
$old = $script:BrowserReactionSelectors
$oldPlan=$old['fixture']
$script:ReactionElementCache[123L]=@{Plan=$oldPlan;Elements=@()}
if ($old.Count -ne 1 -or !$old.ContainsKey('fixture')) { throw 'Snapshot not loaded' }
$invalid = [pscustomobject]@{browser='invalid'; tokens=@($tokens[0],$tokens[0],$tokens[0],$tokens[0],$tokens[0])}
foreach ($bad in @('{', (@{version=99;profiles=@($entry)} | ConvertTo-Json -Depth 8), (@{version=1;profiles=@($entry,$invalid)} | ConvertTo-Json -Depth 8))) {
    $failed=$false
    try { Set-ReactionRegistrationSnapshot $bad } catch { $failed=$true }
    if (!$failed -or ![object]::ReferenceEquals($old,$script:BrowserReactionSelectors)) { throw 'Invalid snapshot changed memory' }
    if (!$script:ReactionElementCache.ContainsKey(123L) -or ![object]::ReferenceEquals($oldPlan,($old['fixture']))) { throw 'Failed snapshot invalidated valid runtime state' }
}
Set-ReactionRegistrationSnapshot '{"version":1,"profiles":[]}'
if ($script:BrowserReactionSelectors.Count -or $script:ReactionElementCache.Count) { throw 'Empty snapshot failed to clear registrations and references' }
# Memory cache reuses successful lookups, expires entries and bounds retries.
. (Join-Path $release 'src\browser\video_metadata.ps1')
$script:fetches = 0
$script:metadataRecovered = $false
function Fetch-Metadata($Video) {
    $script:fetches++
    if ($Video -ceq 'failure0000' -and !$script:metadataRecovered) { throw 'fake failure' }
    return @{Author='fixture'; Channel='/channel/test'; Time=[DateTime]::UtcNow}
}
function Assert-MetadataFailure {
    $failure=$null
    try { $null=Resolve-Video 'failure0000' } catch { $failure=$_ }
    Assert ($null -ne $failure -and $failure.Exception.Message -eq 'fake failure') 'Metadata lookup retains the original failure, including during retry suppression'
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
Assert-MetadataFailure
Assert-MetadataFailure
if ($script:fetches -ne 4) { throw 'Failure retry not suppressed' }
$script:Failures['failure0000'].Time=[DateTime]::UtcNow.AddSeconds(-6)
Assert-MetadataFailure
if ($script:fetches -ne 5) { throw 'Failure retry not released' }
$script:Failures['failure0000'].Time=[DateTime]::UtcNow.AddHours(1)
Assert-MetadataFailure
if ($script:fetches -ne 6) { throw 'Clock rollback kept failure retry suppressed' }
$script:Failures['expired0000']=@{Time=[DateTime]::UtcNow.AddSeconds(-6)}
$script:Failures['future00000']=@{Time=[DateTime]::UtcNow.AddHours(1)}
$script:Failures['recent00000']=@{Time=[DateTime]::UtcNow}
$null=Resolve-Video 'abcdefghijk'
if ($script:fetches -ne 6 -or $script:Failures.ContainsKey('expired0000') -or $script:Failures.ContainsKey('future00000') -or !$script:Failures.ContainsKey('recent00000') -or !$script:Failures.ContainsKey('failure0000')) { throw 'Cache hit did not prune invalid retry records while preserving recent failures' }
$script:Failures['failure0000'].Time=[DateTime]::UtcNow.AddSeconds(-6)
$script:metadataRecovered = $true
$recovered=Resolve-Video 'failure0000'
$null=Resolve-Video 'failure0000'
if ($null -eq $recovered -or $script:fetches -ne 7 -or $script:Failures.ContainsKey('failure0000')) { throw 'Recovery did not replace retry suppression with a reusable success' }
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
$plan=$script:BrowserReactionSelectors['fixture']
if ($script:ReactionElementCache.Count -ne 0 -or ![object]::ReferenceEquals($video,$script:Videos['abcdefghijk'])) { throw 'Registration sync did not preserve metadata or invalidate elements' }
Set-ReactionRegistrationSnapshot $payload
if ([object]::ReferenceEquals($plan,($script:BrowserReactionSelectors['fixture']))) { throw 'Registration replacement reused stale plan' }
Write-Output 'PASS: registration invalidation and memory-only metadata caching.'
# The real pipe reply and existing palette explanation preserve that same cause.
$pipeRuntime=New-TestRuntime
Write-TestWorker -Runtime $pipeRuntime -Definitions @'
function Invoke-FixtureRequest($Request) { return Invoke-WorkerRequest $Request }
$script:MetadataAttempts=0
function Read-BrowserVideoId([long]$WindowHandle) { return 'failure0000' }
function Fetch-Metadata($Video) {
    $script:MetadataAttempts++
    throw "fixture metadata failure $script:MetadataAttempts 日本語"
}
'@
Invoke-AppTest -Runtime $pipeRuntime -Setup @'
RuntimePorts.WorkerScript := A_ScriptDir "\src\browser\fixture_worker.ps1"
RuntimePorts.BrowserProcessName := (hwnd) => (hwnd=123) ? "chrome.exe" : ""
'@ -Body @'
try {
    Loop 2 {
        selected := SelectProfileFromBrowser(123)
        Assert(!selected && DetectedChannel.State="unavailable" && DetectedChannel.Detail="fixture metadata failure 1 日本語",
            "first lookup and suppressed retry preserve the same failure through the real pipe: " DetectedChannel.State "/" DetectedChannel.Detail)
        Assert(InStr(DetectionMessage,DetectedChannel.Detail) && !DetectedChannel.Channel && !DetectedChannel.Author,
            "palette explanation includes the cause without stale channel metadata")
        Assert(!IsBrowserOperationBusy && !WorkerState.RequestActive && IsWorkerRunning(),
            "metadata failure releases the request while keeping the worker for retry suppression")
    }
} finally StopBrowserWorker()
FileAppend("PASS: " Checks " metadata failure reply and palette explanation checks; no network or browser operations`n","*")
ExitApp()
'@
# The common app fixture must resolve its synthetic profile without reaching HTTP.
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
$fixtureRuntime=New-TestRuntime
Edit-TestSource $fixtureRuntime 'src/browser/video_metadata.ps1' '    $data = Invoke-RestMethod -Uri $url -TimeoutSec 4 -UseBasicParsing' "    throw 'Unexpected HTTP request in app fixture'"
Invoke-AppFixture -Runtime $fixtureRuntime -Body @'
    reply := SendWorkerRequest(123,"resolve")
    Assert(reply.State="ok" && reply.Video="abcdefghijk",
        "default fixture resolves metadata with HTTP blocked: " reply.State "/" reply.Detail)
    Assert(reply.Author==Profiles[1].Name && reply.Channel==Profiles[1].Channel,
        "fixture metadata identifies the profile supplied by the same setup")
    selected := SelectProfileFromBrowser(123)
    Assert(selected && selected.ProfileId==Profiles[1].Id && selected.Video==reply.Video,
        "automatic selection uses the common fixture through the real pipe")
    Assert(!IsBrowserOperationBusy && !WorkerState.RequestActive,
        "fixture metadata resolution releases both request gates")
'@
