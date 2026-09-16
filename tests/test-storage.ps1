. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
. (Join-Path $release 'src\browser\reaction_store.ps1')
$tokens = @(1..5 | ForEach-Object { [pscustomobject]@{name="reaction$_"; id="id$_"; class='button'; type=50000} })
$script:BrowserReactionSelectors = @{fixture=[pscustomobject]@{browser='fixture'; groupClass='old'; tokens=$tokens}}
$old = $script:BrowserReactionSelectors['fixture']
$entry = [pscustomobject]@{browser='fixture'; groupClass='new'; tokens=$tokens}
$script:ReactionSelectorsPath = Join-Path $release 'missing\selectors.json'
$failed = $false
try { Save-ReactionSelectors 'fixture' $entry } catch { $failed = $true }
if (!$failed -or $script:BrowserReactionSelectors['fixture'] -ne $old) { throw 'Failed save published new selectors' }
$script:ReactionSelectorsPath = Join-Path $release 'selectors.json'
Save-ReactionSelectors 'fixture' $entry
if ($script:BrowserReactionSelectors['fixture'].groupClass -ne 'new') { throw 'Successful save not published' }
$saved = Get-Content -LiteralPath $script:ReactionSelectorsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($saved.profiles[0].groupClass -ne 'new' -or (Test-Path -LiteralPath ($script:ReactionSelectorsPath + '.new'))) { throw 'Bad persisted selector data' }
# File replacement failure must retain both old disk and memory state.
$locked = [IO.File]::Open($script:ReactionSelectorsPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $failed = $false
    try { Save-ReactionSelectors 'fixture' $old } catch { $failed = $true }
    if (!$failed -or $script:BrowserReactionSelectors['fixture'].groupClass -ne 'new') { throw 'Replacement failure changed memory' }
} finally { $locked.Dispose() }
if (Test-Path -LiteralPath ($script:ReactionSelectorsPath + '.new')) { throw 'Temporary selector file left behind' }
$loaded = Read-ReactionSelectors $script:ReactionSelectorsPath
if ($loaded.Count -ne 1 -or $loaded['fixture'].groupClass -ne 'new') { throw 'Valid selectors failed to load' }
$invalid = [pscustomobject]@{browser='invalid'; tokens=@($tokens[0],$tokens[0],$tokens[0],$tokens[0],$tokens[0])}
$failed = $false
try { Save-ReactionSelectors 'invalid' $invalid } catch { $failed = $true }
if (!$failed -or $script:BrowserReactionSelectors.ContainsKey('invalid')) { throw 'Invalid selectors saved' }
@{version=1; profiles=@($entry,$invalid)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ReactionSelectorsPath -Encoding UTF8
$loaded = Read-ReactionSelectors $script:ReactionSelectorsPath
if ($loaded.Count -ne 1 -or !$loaded.ContainsKey('fixture')) { throw 'Invalid entry affected valid registration' }
# Independently test video metadata caching with a fake fetch function.
$CachePath = Join-Path $release 'cache.json'
$script:Videos = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$script:Failures = [Collections.Generic.Dictionary[string,datetime]]::new([StringComparer]::Ordinal)
. (Join-Path $release 'src\browser\video_metadata.ps1')
$script:fetches = 0
function Fetch-Metadata($Video) { $script:fetches++; return @{Author='fixture'; Channel='/channel/test'; Time=[DateTime]::UtcNow} }
$null = Resolve-Video 'abcdefghijk'
$null = Resolve-Video 'abcdefghijk'
if ($script:fetches -ne 1 -or !(Test-Path -LiteralPath $CachePath)) { throw 'Metadata cache failed' }
$script:Videos.Clear()
Load-VideoCache
if (!$script:Videos.ContainsKey('abcdefghijk')) { throw 'Metadata reload failed' }
$cacheBefore = [IO.File]::ReadAllBytes($CachePath)
$locked = [IO.File]::Open($CachePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $metadata = Resolve-Video 'ABCDEFGHIJK'
    if (!$metadata -or !$script:Videos.ContainsKey('ABCDEFGHIJK')) { throw 'Cache write failure lost memory entry' }
    if (Test-Path -LiteralPath ($CachePath + '.' + $PID + '.new')) { throw 'Temporary metadata file left behind' }
} finally { $locked.Dispose() }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($CachePath)) -cne [Convert]::ToBase64String($cacheBefore)) { throw 'Cache failure changed disk contents' }
Write-Output 'PASS: selector write/replacement failures and independent metadata persistence.'
