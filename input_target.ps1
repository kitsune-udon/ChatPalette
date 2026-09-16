# Pure classification of a focused editable element and its bounded ancestry.
function Get-YouTubeInputKind($Records) {
    if (!$Records -or $Records.Count -eq 0) { return '' }
    $field = $Records[0]
    if (!$field.Focused -or !$field.Enabled -or $field.Hidden -or !$field.Editable) { return '' }
    if ($field.Id -match '(?i)search|urlbar|address' -or $field.Name -match '^(検索|Search)(\s|$)') { return '' }
    if (!@($Records | Where-Object { $_.Type -eq 50030 }).Count) { return '' } # Document
    $context = ($Records | ForEach-Object { $_.Id + ' ' + $_.Class }) -join ' '
    if (($field.Id -eq 'input' -and $context -match 'yt-live-chat-text-input-field-renderer') -or
        $field.Name -match '^(チャット(を入力)?[\.。…]*|メッセージを入力[\.。…]*|Chat[\.…]*|Say something[\.…]*|Type a message[\.…]*)$') {
        return 'chat'
    }
    if (($field.Id -eq 'contenteditable-root' -and $context -match 'ytd-comment-(simplebox|reply|dialog)-renderer') -or
        $field.Name -match '^(コメントを追加|公開コメントを入力|返信を追加|返信を入力|Add a comment|Add a public comment|Add a reply|Write a reply)[\.。…]*$') {
        return 'comment'
    }
    return ''
}

function Get-InputRecord($Element, [bool]$Focused) {
    $info = $Element.Current
    $editable = $false
    if ($Focused) {
        $pattern = $null
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $editable = !$pattern.Current.IsReadOnly
        } elseif ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
            # Chromium contenteditable fields can be Custom + TextPattern, not Edit.
            # Read only the attribute, never the document text. Unknown is not editable.
            $readOnly = $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::IsReadOnlyAttribute)
            $editable = $readOnly -is [bool] -and !$readOnly
        } else {
            $editable = $info.ControlType.Id -eq 50004 # Edit
        }
    }
    return @{Id=$info.AutomationId; Name=$info.Name; Class=$info.ClassName; Type=$info.ControlType.Id;
        Focused=$info.HasKeyboardFocus; Enabled=$info.IsEnabled; Hidden=$info.IsOffscreen; Editable=$editable}
}

function Get-FocusedYouTubeInput([long]$WindowHandle) {
    if (!(Test-ReactionForeground $WindowHandle)) { return '' }
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused -or !(Test-ElementWindow $focused $WindowHandle)) { return '' }
    $records = @()
    $element = $focused
    for ($depth = 0; $depth -lt 45 -and $null -ne $element; $depth++) {
        $records += Get-InputRecord $element ($depth -eq 0)
        if ($element.Current.ControlType.Id -eq 50030 -or $element.Current.NativeWindowHandle -eq $WindowHandle) { break }
        $element = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($element)
    }
    $kind = Get-YouTubeInputKind $records
    if (!$kind -or !(Test-ReactionForeground $WindowHandle)) { return '' }
    $latest = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $latest -or ![System.Windows.Automation.Automation]::Compare($focused, $latest)) { return '' }
    return $kind
}
