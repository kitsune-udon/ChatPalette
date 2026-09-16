# Reaction adapter: UI discovery and execution are separate from transport and UI.
# Registration is explicit and read-only with respect to the YouTube page.
$script:ReactionSelectorsPath = Join-Path $PSScriptRoot 'reaction_selectors.json'
$script:BrowserReactionSelectors = @{}
$script:LastReactionInvocationAt = [DateTime]::MinValue
$script:ReactionElementCache = @{}
$script:ReactionAliases = @('heart|ハート|[❤♥]', 'smil|grin|happy|笑|😀|😁|😄|😊', 'party|celebrat|tada|お祝い|祝|🎉', 'surpris|shock|astonish|flushed|open[_ -]?mouth|\bwow\b|驚|びっくり|赤面|赤らめ|😮|😲|😯|😳', '100|hundred|perfect|💯')
if (Test-Path -LiteralPath $script:ReactionSelectorsPath) {
    try {
        $saved = Get-Content -LiteralPath $script:ReactionSelectorsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in $saved.profiles) { $script:BrowserReactionSelectors[$entry.browser] = $entry }
    } catch { }
}

function Get-BrowserProcessName([long]$WindowHandle) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    return (Get-Process -Id $root.Current.ProcessId).ProcessName
}

function Test-ElementWindow($Element, [long]$WindowHandle) {
    for ($depth = 0; $depth -lt 45 -and $null -ne $Element; $depth++) {
        if ($Element.Current.NativeWindowHandle -eq $WindowHandle) { return $true }
        $Element = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($Element)
    }
    return $false
}

function Test-ReactionForeground([long]$WindowHandle) {
    return Test-ElementWindow ([System.Windows.Automation.AutomationElement]::FocusedElement) $WindowHandle
}

function Get-ReactionInvoker($Target) {
    $pattern = $null
    if ($Target.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { return $pattern }
    $legacy = $null
    if ($Target.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$legacy) -and $legacy.Current.Role -eq 43) {
        $adapter = [pscustomobject]@{Pattern = $legacy}
        $adapter | Add-Member ScriptMethod Invoke { $this.Pattern.DoDefaultAction() }
        return $adapter
    }
    return $null
}

function Get-ReactionGroup($Element) {
    $invokeCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsInvokePatternAvailableProperty, $true)
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $condition = New-Object System.Windows.Automation.OrCondition($invokeCondition, $buttonCondition)
    $controls = @($Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) |
        Where-Object { -not $_.Current.IsOffscreen -and $_.Current.IsEnabled })
    $selected = @()
    $tokens = @()
    $missing = @()
    $ambiguous = @()
    $labels = @('ハート','笑顔','お祝い','驚き','100点')
    for ($i = 0; $i -lt 5; $i++) {
        $matches = @($controls | Where-Object {
            ($_.Current.Name + ' ' + $_.Current.AutomationId) -match $script:ReactionAliases[$i]
        })
        if ($matches.Count -eq 0) { $missing += $labels[$i]; continue }
        if ($matches.Count -gt 1) { $ambiguous += $labels[$i]; continue }
        $control = $matches[0]
        $info = $control.Current
        $selected += ,$control
        $tokens += @{name=$info.Name; id=$info.AutomationId; class=$info.ClassName; type=$info.ControlType.Id}
    }
    $script:ReactionDiagnostic = "操作対象=$($controls.Count)、識別=$($selected.Count)/5、不足=$($missing -join ',')、重複=$($ambiguous -join ',')"
    # Diagnostics only: inspect names near the already recognized controls.
    # Geometry is never used to select or click an unknown reaction.
    $nearby = @($controls | Select-Object -First 40)
    if ($selected.Count -ge 2) {
        $rect = $selected[0].Current.BoundingRectangle
        if ($rect.Width -gt 0) {
            $top = ($selected | ForEach-Object { $_.Current.BoundingRectangle.Top } | Measure-Object -Minimum).Minimum
            $bottom = ($selected | ForEach-Object { $_.Current.BoundingRectangle.Bottom } | Measure-Object -Maximum).Maximum
            $nearby = @($controls | Where-Object {
                $r = $_.Current.BoundingRectangle
                [Math]::Abs($r.Left - $rect.Left) -le $rect.Width -and $r.Top -ge ($top - $rect.Height) -and $r.Bottom -le ($bottom + $rect.Height)
            })
        }
    }
    $names = @($nearby | ForEach-Object {
        $name = [string]$_.Current.Name + ' {' + [string]$_.Current.AutomationId + '}'
        $name.Substring(0,[Math]::Min(80,$name.Length))
    })
    $nameText = $names -join ' | '
    $script:ReactionDiagnostic += '、近くのボタン名=[' + $nameText.Substring(0,[Math]::Min(700,$nameText.Length)) + ']'
    if ($selected.Count -ne 5) { return $null }
    $signatures = @($tokens | ForEach-Object { $_ | ConvertTo-Json -Compress })
    if (@($signatures | Select-Object -Unique).Count -ne 5) { return $null }
    return @{Elements=$selected; Tokens=$tokens; Class=$Element.Current.ClassName; Id=$Element.Current.AutomationId}
}

function Select-RegisteredReactions($Records, $Saved) {
    $selected = @()
    $diagnostics = @()
    foreach ($token in $Saved.tokens) {
        $exact = @($Records | Where-Object {
            $_.Name -ceq [string]$token.name -and $_.Id -ceq [string]$token.id -and
            $_.Class -ceq [string]$token.class -and $_.Type -eq [int]$token.type
        })
        $visible = @($exact | Where-Object { -not $_.Hidden -and $_.Enabled })
        # Runtime IDs deduplicate multiple references to the same actual control.
        $unique = @{}
        foreach ($record in $visible) { $unique[$record.RuntimeId] = $record }
        $diagnostics += "[$($token.name)] 一致=$($exact.Count)、表示中=$($unique.Count)"
        if ($unique.Count -eq 1) { $selected += ,@($unique.Values)[0].Element }
    }
    $script:ReactionLookupDiagnostic = '登録したボタンを直接検索: ' + ($diagnostics -join ' / ')
    if ($selected.Count -ne 5) { return $null }
    return @{Elements=$selected}
}

function Find-RegisteredReactions([long]$WindowHandle, $Saved) {
    $fingerprint = ($Saved.tokens | ConvertTo-Json -Depth 4 -Compress)
    if ($script:ReactionElementCache.ContainsKey($WindowHandle)) {
        $entry = $script:ReactionElementCache[$WindowHandle]
        if ($entry.Fingerprint -ceq $fingerprint -and ([DateTime]::UtcNow - $entry.Checked).TotalMilliseconds -lt 1000) {
            try {
                $cachedRecords = @(foreach ($control in $entry.Elements) { Get-ReactionRecord $control })
                $cached = Select-RegisteredReactions $cachedRecords $Saved
                if ($null -ne $cached -and (Test-ElementWindow $cached.Elements[0] $WindowHandle)) { return $cached }
            } catch { }
        }
        $script:ReactionElementCache.Remove($WindowHandle)
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    # Filter inside the provider before fetching properties across process boundaries.
    $nameConditions = [System.Windows.Automation.Condition[]]@(
        foreach ($token in $Saved.tokens) {
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, [string]$token.name)
        }
    )
    if ($nameConditions.Count -ne 5) { return $null }
    $condition = [System.Windows.Automation.AndCondition]::new($buttonCondition,
        [System.Windows.Automation.OrCondition]::new($nameConditions))
    $records = @()
    foreach ($control in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        try {
            $records += Get-ReactionRecord $control
        } catch { }
    }
    $group = Select-RegisteredReactions $records $Saved
    if ($null -ne $group) {
        if ($script:ReactionElementCache.Count -ge 8) { $script:ReactionElementCache.Clear() }
        $script:ReactionElementCache[$WindowHandle] = @{Elements=$group.Elements; Checked=[DateTime]::UtcNow; Fingerprint=$fingerprint}
    }
    return $group
}

function Get-ReactionRecord($Control) {
    $info = $Control.Current
    return @{Element=$Control; Name=$info.Name; Id=$info.AutomationId; Class=$info.ClassName;
        Type=$info.ControlType.Id; Hidden=$info.IsOffscreen; Enabled=$info.IsEnabled;
        RuntimeId=($Control.GetRuntimeId() -join ',')}
}

function Register-ReactionSelectors($Request, $Reply) {
    Add-Type -AssemblyName WindowsBase
    $point = [System.Windows.Point]::new([double]$Request.X, [double]$Request.Y)
    $element = [System.Windows.Automation.AutomationElement]::FromPoint($point)
    if (-not (Test-ElementWindow $element ([long]$Request.Window))) { $Reply.State = 'wrong_window'; return $Reply }
    $group = $null
    $diagnostics = @()
    for ($depth = 0; $depth -lt 7 -and $null -ne $element; $depth++) {
        $group = Get-ReactionGroup $element
        $diagnostics += "階層${depth}: $script:ReactionDiagnostic"
        if ($null -ne $group) { break }
        $element = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
    }
    if ($null -eq $group) {
        $Reply.State = 'unsupported'
        $Reply.Detail = $diagnostics -join ' / '
        if ($Reply.Detail.Length -gt 5000) { $Reply.Detail = $Reply.Detail.Substring(0,5000) }
        return $Reply
    }
    if ((Read-BrowserVideoId ([long]$Request.Window)) -cne $Reply.Video) { $Reply.State = 'changed'; return $Reply }
    $browser = Get-BrowserProcessName ([long]$Request.Window)
    $entry = @{browser = $browser; groupClass = $group.Class; groupId = $group.Id; tokens = $group.Tokens}
    # Normalize to the same object shape used when loading JSON.
    $entry = $entry | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $script:BrowserReactionSelectors[$browser] = $entry
    $json = @{version = 1; profiles = @($script:BrowserReactionSelectors.Values)} | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(($script:ReactionSelectorsPath + '.new'), $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath ($script:ReactionSelectorsPath + '.new') -Destination $script:ReactionSelectorsPath -Force
    $Reply.State = 'registered'
    return $Reply
}

function Invoke-ReactionRequest($Request) {
    $reply = @{Seq = $Request.Seq; Window = $Request.Window; State = 'unavailable'; Video = ''; Author = ''; Channel = ''}
    try {
        $video = Read-BrowserVideoId ([long]$Request.Window)
        $reply.Video = $video
        if (-not $video) { return $reply }
        if ($Request.Mode -eq 'reaction_context') { $reply.State = 'ok'; return $reply }
        if ($video -cne $Request.Video) { $reply.State = 'changed'; return $reply }
        if ($Request.Mode -eq 'reaction_capture') { return Register-ReactionSelectors $Request $reply }
        $browser = Get-BrowserProcessName ([long]$Request.Window)
        if (-not $script:BrowserReactionSelectors.ContainsKey($browser)) { $reply.State = 'not_registered'; return $reply }
        $group = Find-RegisteredReactions ([long]$Request.Window) $script:BrowserReactionSelectors[$browser]
        if ($null -eq $group) {
            $reply.State = 'menu_closed'
            $reply.Detail = $script:ReactionLookupDiagnostic
            return $reply
        }
        if ($Request.Mode -eq 'reaction_check') { $reply.State = 'ready'; return $reply }
        if ($Request.Mode -ne 'reaction_send' -or $Request.Reaction -notmatch '^[1-5]$') { return $reply }
        if (([DateTime]::UtcNow - $script:LastReactionInvocationAt).TotalMilliseconds -lt 25) { $reply.State = 'cooldown'; return $reply }
        $target = $group.Elements[([int]$Request.Reaction - 1)]
        if (-not (Test-ReactionForeground ([long]$Request.Window))) {
            $reply.State = 'wrong_window'; return $reply
        }
        if ((Read-BrowserVideoId ([long]$Request.Window)) -cne $video) { $reply.State = 'changed'; return $reply }
        if ($target.Current.IsOffscreen -or -not $target.Current.IsEnabled) { $reply.State = 'menu_closed'; return $reply }
        $pattern = Get-ReactionInvoker $target
        if ($null -eq $pattern) {
            $reply.State = 'unsupported'; return $reply
        }
        # Never retry after invocation, even if the provider throws or the pipe breaks.
        $script:LastReactionInvocationAt = [DateTime]::UtcNow
        $reply.State = 'unknown'
        $pattern.Invoke()
        $reply.State = 'operated'
        return $reply
    } catch {
        $reply.Detail = '検出処理: ' + $_.Exception.Message
        return $reply
    }
}
