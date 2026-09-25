. (Join-Path $PSScriptRoot 'browser_uia.ps1')
# Pure classification of an editable element and its bounded ancestry; focus is verified separately.
function Get-YouTubeInputKind($Records) {
    if (!$Records -or $Records.Count -eq 0) { return '' }
    $field = $Records[0]
    if (!$field.Enabled -or $field.Hidden -or !$field.Editable) { return '' }
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

function Get-InputRecord($Element, [bool]$IncludeEditState) {
    $info = $Element.Current
    if (!$IncludeEditState) {
        # Ancestry needs structure only, not names, focus state or edit patterns.
        return @{Id=$info.AutomationId; Class=$info.ClassName; Type=$info.ControlType.Id}
    }
    $editable = $false
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        $editable = !$pattern.Current.IsReadOnly
    } elseif ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
        # Chromium contenteditable fields can be Custom + TextPattern, not Edit.
        # Read only the attribute, never the document text. Unknown is not editable.
        $readOnly = $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::IsReadOnlyAttribute)
        $editable = $readOnly -is [bool] -and !$readOnly
    }
    return @{Id=$info.AutomationId; Name=$info.Name; Class=$info.ClassName; Type=$info.ControlType.Id;
        Focused=$info.HasKeyboardFocus; Enabled=$info.IsEnabled; Hidden=$info.IsOffscreen; Editable=$editable}
}

function Get-FocusedYouTubeInput([long]$WindowHandle, [ref]$VerifiedElement) {
    $VerifiedElement.Value = $null
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused -or !(Test-ElementWindow $focused $WindowHandle)) { return '' }
    $records = @(Get-YouTubeInputRecords $focused $WindowHandle)
    if (!$records -or !$records[0].Focused) { return '' }
    $kind = Get-YouTubeInputKind $records
    if (!$kind) { return '' }
    $latest = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $latest -or ![System.Windows.Automation.Automation]::Compare($focused, $latest)) { return '' }
    if (!(Test-ElementWindow $latest $WindowHandle)) { return '' }
    $VerifiedElement.Value = $focused
    return $kind
}


# Revalidate the exact element after the final URL read; a second editable field is not equivalent.
function Test-FocusedInputIdentity($VerifiedElement, [long]$WindowHandle) {
    if ($null -eq $VerifiedElement) { return $false }
    $latest = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $latest -or ![System.Windows.Automation.Automation]::Compare($VerifiedElement, $latest)) { return $false }
    if (!(Test-ElementWindow $latest $WindowHandle)) { return $false }
    $record = Get-InputRecord $latest $true
    return $record.Focused -and $record.Enabled -and !$record.Hidden -and $record.Editable
}

function Get-YouTubeInputRecords($Target, [long]$WindowHandle) {
    $records = @()
    $element = $Target
    for ($depth = 0; $depth -lt 45 -and $null -ne $element; $depth++) {
        $record = Get-InputRecord $element ($depth -eq 0)
        $records += $record
        # Links can expose TextPattern. Reject non-editable targets before walking
        # a long live-chat ancestry, using the same record returned to classification.
        if ($depth -eq 0 -and (!$record.Enabled -or $record.Hidden -or !$record.Editable)) { break }
        if ($record.Type -eq 50030 -or $element.Current.NativeWindowHandle -eq $WindowHandle) { break }
        $element = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($element)
    }
    return $records
}
