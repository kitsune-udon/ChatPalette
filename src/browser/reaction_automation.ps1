. (Join-Path $PSScriptRoot 'browser_uia.ps1')
. (Join-Path $PSScriptRoot 'reaction_registration.ps1')
# Reaction adapter: UI discovery and execution are separate from transport and UI.
# Registration is explicit and read-only with respect to the YouTube page.
$script:BrowserReactionSelectors = @{}
$script:ReactionPropertyRequest = $null
$script:ReactionElementCache = @{}
$script:ReactionAliases = @('heart|ハート|[❤♥]', 'smil|grin|happy|笑|😀|😁|😄|😊', 'party|celebrat|tada|お祝い|祝|🎉', 'surpris|shock|astonish|flushed|open[_ -]?mouth|\bwow\b|驚|びっくり|赤面|赤らめ|😮|😲|😯|😳', '100|hundred|perfect|💯')

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

function Get-ReactionTokens($Element) {
    $invokeCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsInvokePatternAvailableProperty, $true)
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $condition = New-Object System.Windows.Automation.OrCondition($invokeCondition, $buttonCondition)
    $records = @(
        foreach ($control in $Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
            $record = Get-ReactionRecord $control
            if (!$record.Hidden -and $record.Enabled) { $record }
        }
    )
    $selected = @()
    $tokens = @()
    $missing = @()
    $ambiguous = @()
    $labels = @('ハート','笑顔','お祝い','驚き','100点')
    for ($i = 0; $i -lt 5; $i++) {
        $matches = @($records | Where-Object {
            ($_.Name + ' ' + $_.Id) -match $script:ReactionAliases[$i]
        })
        if ($matches.Count -eq 0) { $missing += $labels[$i]; continue }
        if ($matches.Count -gt 1) { $ambiguous += $labels[$i]; continue }
        $record = $matches[0]
        $selected += ,$record
        $tokens += @{name=$record.Name; id=$record.Id; class=$record.Class; type=$record.Type}
    }
    $script:ReactionDiagnostic = "操作対象=$($records.Count)、識別=$($selected.Count)/5、不足=$($missing -join ',')、重複=$($ambiguous -join ',')"
    # Diagnostics only: inspect names near the already recognized controls.
    # Geometry is never used to select or click an unknown reaction.
    $nearby = @($records | Select-Object -First 40)
    if ($selected.Count -ge 2) {
        try {
            # One local observation per candidate; later geometry cannot change the filter.
            $bounds = @{}
            foreach ($record in $records) {
                $bounds[$record.RuntimeId] = $record.Element.Current.BoundingRectangle
                if ($null -eq $bounds[$record.RuntimeId]) { throw 'Candidate geometry is unavailable.' }
            }
            $rect = $bounds[$selected[0].RuntimeId]
            if ($rect.Width -gt 0) {
                $top = ($selected | ForEach-Object { $bounds[$_.RuntimeId].Top } | Measure-Object -Minimum).Minimum
                $bottom = ($selected | ForEach-Object { $bounds[$_.RuntimeId].Bottom } | Measure-Object -Maximum).Maximum
                $nearby = @($records | Where-Object {
                    $r = $bounds[$_.RuntimeId]
                    [Math]::Abs($r.Left - $rect.Left) -le $rect.Width -and $r.Top -ge ($top - $rect.Height) -and $r.Bottom -le ($bottom + $rect.Height)
                })
            }
        } catch {
            # Optional geometry must not discard identified buttons or candidate names.
        }
    }
    $names = @($nearby | ForEach-Object {
        $name = [string]$_.Name + ' {' + [string]$_.Id + '}'
        $name.Substring(0,[Math]::Min(80,$name.Length))
    })
    $nameText = $names -join ' | '
    $script:ReactionDiagnostic += '、近くのボタン名=[' + $nameText.Substring(0,[Math]::Min(700,$nameText.Length)) + ']'
    if (!(Test-ReactionTokens $tokens)) { return $null }
    return $tokens
}

function Select-ReactionRecords($Records, $Plan) {
    $selected = @()
    $selectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $diagnostics = @()
    foreach ($token in $Plan.Tokens) {
        $exactCount = 0
        # Runtime IDs deduplicate multiple references to the same actual control.
        $unique = @{}
        foreach ($record in $Records) {
            if ($record.Name -ceq $token.name -and $record.Id -ceq $token.id -and
                $record.Class -ceq $token.class -and $record.Type -eq $token.type) {
                $exactCount++
                if (!$record.Hidden -and $record.Enabled) { $unique[$record.RuntimeId] = $record }
            }
        }
        $diagnostics += "[$($token.name)] 一致=$exactCount、表示中=$($unique.Count)"
        if ($unique.Count -eq 1) {
            $record = @($unique.Values)[0]
            if ($record.RuntimeId -and $selectedIds.Add([string]$record.RuntimeId)) {
                $selected += ,$record.Element
            } else {
                # Finish this lookup's diagnostic even when identity cannot be trusted.
                $diagnostics += "[$($token.name)] 識別情報が不明または重複"
            }
        }
    }
    $script:ReactionLookupDiagnostic = '登録したボタンを直接検索: ' + ($diagnostics -join ' / ')
    if ($selected.Count -ne 5) { return $null }
    return @{Elements=$selected}
}

function New-ReactionLookupCondition($Plan) {
    # Capture accepts invokable Custom controls too. Lookup must preserve their types.
    $conditions = [System.Windows.Automation.Condition[]]@(
        foreach ($token in $Plan.Tokens) {
            $name = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, [string]$token.name)
            $type = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::LookupById([int]$token.type))
            [System.Windows.Automation.AndCondition]::new($name, $type)
        }
    )
    return [System.Windows.Automation.OrCondition]::new($conditions)
}

function Find-RegisteredReactions([long]$WindowHandle, $Plan) {
    # Revalidate live properties every time; rescan only when references or registration are invalid.
    if ($script:ReactionElementCache.ContainsKey($WindowHandle)) {
        $entry = $script:ReactionElementCache[$WindowHandle]
        if ([object]::ReferenceEquals($entry.Plan, $plan)) {
            try {
                $cachedRecords = @(foreach ($control in $entry.Elements) { Get-ReactionRecord $control })
                $cached = Select-ReactionRecords $cachedRecords $plan
                if ($null -ne $cached) {
                    $belongsToWindow = $true
                    foreach ($element in $cached.Elements) {
                        if (!(Test-ElementWindow $element $WindowHandle)) { $belongsToWindow = $false; break }
                    }
                    if ($belongsToWindow) { return $cached }
                }
            } catch { }
        }
        $script:ReactionElementCache.Remove($WindowHandle)
    }
    $group = Find-ReactionGroupInWindow $WindowHandle $plan
    if ($null -ne $group) {
        if ($script:ReactionElementCache.Count -ge 8) { $script:ReactionElementCache.Clear() }
        $script:ReactionElementCache[$WindowHandle] = @{Elements=$group.Elements; Plan=$plan}
    }
    return $group
}

function Find-ReactionGroupInWindow([long]$WindowHandle, $plan) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    # Filter inside the provider before fetching properties across process boundaries.
    if (!$plan.ContainsKey('Condition')) { $plan.Condition = New-ReactionLookupCondition $plan }
    $condition = $plan.Condition
    $records = @()
    foreach ($control in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        try {
            $records += Get-ReactionRecord $control
        } catch { }
    }
    return Select-ReactionRecords $records $plan
}

function Get-ReactionRecord($Control) {
    if ($null -eq $script:ReactionPropertyRequest) {
        $script:ReactionPropertyRequest = [System.Windows.Automation.CacheRequest]::new()
        foreach ($property in @('NameProperty','AutomationIdProperty','ClassNameProperty','ControlTypeProperty','IsOffscreenProperty','IsEnabledProperty')) {
            $script:ReactionPropertyRequest.Add([System.Windows.Automation.AutomationElement]::$property)
        }
    }
    # Refresh all attributes together; never reuse a previous property snapshot.
    $snapshot = $Control.GetUpdatedCache($script:ReactionPropertyRequest)
    $info = $snapshot.Cached
    return @{Element=$Control; Name=$info.Name; Id=$info.AutomationId; Class=$info.ClassName;
        Type=$info.ControlType.Id; Hidden=$info.IsOffscreen; Enabled=$info.IsEnabled;
        RuntimeId=($Control.GetRuntimeId() -join ',')}
}

function Register-ReactionSelectors($Request, $Reply) {
    Add-Type -AssemblyName WindowsBase
    $point = [System.Windows.Point]::new([double]$Request.X, [double]$Request.Y)
    $element = [System.Windows.Automation.AutomationElement]::FromPoint($point)
    if (-not (Test-ElementWindow $element ([long]$Request.Window))) { $Reply.State = 'wrong_window'; return $Reply }
    $tokens = $null
    $diagnostics = @()
    for ($depth = 0; $depth -lt 7 -and $null -ne $element; $depth++) {
        $tokens = Get-ReactionTokens $element
        $diagnostics += "階層${depth}: $script:ReactionDiagnostic"
        if ($null -ne $tokens) { break }
        $element = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
    }
    if ($null -eq $tokens) {
        $Reply.State = 'unsupported'
        $Reply.Detail = $diagnostics -join ' / '
        if ($Reply.Detail.Length -gt 5000) { $Reply.Detail = $Reply.Detail.Substring(0,5000) }
        return $Reply
    }
    if ((Read-BrowserVideoId ([long]$Request.Window)) -cne $Reply.Video) { $Reply.State = 'changed'; return $Reply }
    $browser = Get-BrowserProcessName ([long]$Request.Window)
    $entry = @{browser = $browser.ToLowerInvariant(); tokens = $tokens}
    $Reply.Detail = $entry | ConvertTo-Json -Depth 8 -Compress
    $Reply.State = 'captured'
    return $Reply
}

function Invoke-ReactionRequest($Request) {
    $reply = @{Seq = $Request.Seq; Window = $Request.Window; State = 'unavailable'; Video = ''; Author = ''; Channel = ''}
    try {
        $video = Read-BrowserVideoId ([long]$Request.Window)
        $reply.Video = $video
        if (-not $video) { return $reply }
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
        # UIA lookups may outlive a foreground switch. Check again at the action boundary.
        if (-not (Test-ReactionForeground ([long]$Request.Window))) {
            $reply.State = 'wrong_window'; return $reply
        }
        # Never retry after invocation, even if the provider throws or the pipe breaks.
        $reply.State = 'unknown'
        $pattern.Invoke()
        $reply.State = 'operated'
        return $reply
    } catch {
        $reply.Detail = '検出処理: ' + $_.Exception.Message
        return $reply
    }
}
