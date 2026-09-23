# Page actions never invoke a reaction button or send a chat message.
function Find-ChatInput([long]$WindowHandle, [ref]$Failure = ([ref]$null)) {
    if ($null -ne $Failure) { $Failure.Value = 'chat_missing' }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    $focusable = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty, $true)
    $value = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::IsValuePatternAvailableProperty, $true)
    $text = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty, $true)
    $editable = [System.Windows.Automation.OrCondition]::new($value,$text)
    $condition = [System.Windows.Automation.AndCondition]::new($focusable,$editable)
    $matches = @(
        foreach ($element in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
            try {
                if (!(Test-ElementWindow $element $WindowHandle)) { continue }
                # Links can also expose TextPattern; discard non-editable elements
                # before walking their ancestry through a long live chat.
                $field = Get-InputRecord $element $true
                if (!$field.Enabled -or $field.Hidden -or !$field.Editable) { continue }
                $records = @(Get-YouTubeInputRecords $element $WindowHandle)
                # Discovery checks the same editable/chat ancestry before moving focus.
                $records[0].Focused = $true
                if ((Get-YouTubeInputKind $records) -eq 'chat') { $element }
            } catch { }
        }
    )
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1 -and $null -ne $Failure) { $Failure.Value = 'chat_ambiguous' }
    return $null
}

function Get-ReactionLauncherKind($Field) {
    if ($Field.Class -match '\byt-reaction-control-panel-button-view-model\b') { return 'collapsed' }
    if ($Field.Id -in @('reaction-control-panel','reaction-button')) { return 'panel' }
    if ($Field.Name -match '^(リアクション(を送信|を表示)?|Send a reaction|Show reactions|React)$') { return 'named' }
    return ''
}
function Test-ReactionLauncher($Records) {
    if (!$Records -or $Records.Count -eq 0) { return $false }
    $field = $Records[0]
    if (!$field.Enabled -or $field.Hidden) { return $false }
    if (!@($Records | Where-Object { $_.Type -eq 50030 }).Count) { return $false }
    $context = ($Records | ForEach-Object { $_.Id + ' ' + $_.Class }) -join ' '
    if ($context -notmatch 'yt-live-chat|yt-reaction-control-panel') { return $false }
    $kind = Get-ReactionLauncherKind $field
    return $kind -eq 'panel' -or $kind -eq 'named' -or
        ($kind -eq 'collapsed' -and $context -match '\bcollapsed-button\b')
}
function Get-ReactionLauncherRecords($Target, [long]$WindowHandle) {
    $records = @()
    $element = $Target
    for ($depth = 0; $depth -lt 45 -and $null -ne $element; $depth++) {
        $info = $element.Current
        $records += @{Id=$info.AutomationId; Class=$info.ClassName; Type=$info.ControlType.Id;
            Name=$info.Name; Enabled=$info.IsEnabled; Hidden=$info.IsOffscreen}
        if ($info.ControlType.Id -eq 50030 -or $info.NativeWindowHandle -eq $WindowHandle) { break }
        $element = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($element)
    }
    return $records
}
function Find-ReactionLauncher([long]$WindowHandle) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    $button = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $panel = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'reaction-control-panel')
    $condition = [System.Windows.Automation.OrCondition]::new($button,$panel)
    $matches = @(
        foreach ($element in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)) {
            try {
                $info = $element.Current
                if ($info.IsOffscreen -or !$info.IsEnabled -or
                    !(Get-ReactionLauncherKind @{Id=$info.AutomationId;Class=$info.ClassName;Name=$info.Name})) { continue }
                if ((Test-ElementWindow $element $WindowHandle) -and
                    (Test-ReactionLauncher @(Get-ReactionLauncherRecords $element $WindowHandle))) { $element }
            } catch { }
        }
    )
    # Chromium exposes the collapsed launcher as a heart-labelled Button. Its
    # model class and collapsed ancestor distinguish it from sending buttons.
    $buttons = @($matches | Where-Object { $_.Current.ClassName -match '\byt-reaction-control-panel-button-view-model\b' })
    if ($buttons.Count -gt 1) { return $null }
    if ($buttons.Count -eq 1) { return $buttons[0] }
    # Prefer the exact panel ID if a labelled child button is also exposed.
    $panels = @($matches | Where-Object { $_.Current.AutomationId -eq 'reaction-control-panel' })
    if ($panels.Count -eq 1) { return $panels[0] }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}
function Focus-ChatElement($Target) { $Target.SetFocus() }
# SetFocus is issued once. Chromium can publish keyboard focus asynchronously;
# only observation is retried, and success must refer to the exact target.
function Wait-ChatFocus($Target, [long]$WindowHandle, [string]$Video) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (!(Test-ReactionForeground $WindowHandle)) { return 'wrong_window' }
        $verified = $null
        $kind = Get-FocusedYouTubeInput $WindowHandle ([ref]$verified)
        if ($kind -eq 'chat' -and [System.Windows.Automation.Automation]::Compare($Target,$verified)) {
            if ((Read-BrowserVideoId $WindowHandle) -cne $Video) { return 'changed' }
            if (!(Test-ReactionForeground $WindowHandle)) { return 'wrong_window' }
            if (Test-FocusedInputIdentity $Target $WindowHandle) { return 'focused' }
            return 'focus_failed'
        }
        # Do not override a user moving to another identified input.
        if ($kind) { return 'focus_failed' }
        if ($timer.ElapsedMilliseconds -ge 350) { break }
        Start-Sleep -Milliseconds 25
    } while ($true)
    if ((Read-BrowserVideoId $WindowHandle) -cne $Video) { return 'changed' }
    return 'focus_failed'
}
function Get-ReactionHoverPoint($Target, [long]$WindowHandle) {
    Add-Type -AssemblyName WindowsBase
    $point = [System.Windows.Point]::new(0,0)
    if (!$Target.TryGetClickablePoint([ref]$point)) { return $null }
    # Only use a point that still belongs to this identified launcher (or its child).
    $hit = [System.Windows.Automation.AutomationElement]::FromPoint($point)
    for ($depth=0; $depth -lt 12 -and $null -ne $hit; $depth++) {
        if ([System.Windows.Automation.Automation]::Compare($Target,$hit)) { return $point }
        $hit = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)
    }
    return $null
}
function Move-PagePointer($Point) {
    if (!('ChatPalettePagePointer' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class ChatPalettePagePointer { [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); }'
    }
    return [ChatPalettePagePointer]::SetCursorPos([int]$Point.X,[int]$Point.Y)
}
function Invoke-PageAction($Request) {
    $reply = @{Seq=$Request.Seq; Window=$Request.Window; State='unavailable'; Video=''}
    $window = [long]$Request.Window
    try {
        if (!(Test-ReactionForeground $window)) { $reply.State='wrong_window'; return $reply }
        $video = Read-BrowserVideoId $window
        $reply.Video = $video
        if (!$video) { return $reply }
        if ($Request.Video -and $Request.Video -cne $video) { $reply.State='changed'; return $reply }
        if ($Request.Mode -eq 'chat_focus') {
            $failure = 'chat_missing'
            $target = Find-ChatInput $window ([ref]$failure)
            if ($null -eq $target) { $reply.State=$failure; return $reply }
            if (!(Test-ElementWindow $target $window)) { $reply.State='wrong_window'; return $reply }
            $records = @(Get-YouTubeInputRecords $target $window)
            $records[0].Focused=$true
            if ((Get-YouTubeInputKind $records) -ne 'chat') { $reply.State='chat_missing'; return $reply }
            if ((Read-BrowserVideoId $window) -cne $video) { $reply.State='changed'; return $reply }
            if (!(Test-ReactionForeground $window)) { $reply.State='wrong_window'; return $reply }
            $reply.State='unknown'
            Focus-ChatElement $target
            $reply.State = Wait-ChatFocus $target $window $video
            return $reply
        }
        if ($Request.Mode -ne 'reactions_show') { return $reply }
        $target = Find-ReactionLauncher $window
        if ($null -eq $target) { $reply.State='unsupported'; return $reply }
        $point = Get-ReactionHoverPoint $target $window
        if ($null -eq $point) { $reply.State='unsupported'; return $reply }
        if (!(Test-ElementWindow $target $window) -or !(Test-ReactionLauncher @(Get-ReactionLauncherRecords $target $window))) {
            $reply.State='unsupported'; return $reply
        }
        if ((Read-BrowserVideoId $window) -cne $video) { $reply.State='changed'; return $reply }
        if (!(Test-ReactionForeground $window)) { $reply.State='wrong_window'; return $reply }
        $reply.State='unknown'
        # Hover only: clicking a heart can itself send a reaction.
        if (Move-PagePointer $point) { $reply.State='hovered' }
        return $reply
    } catch { $reply.Detail=$_.Exception.Message; return $reply }
}
