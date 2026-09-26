[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference='Stop'
if (!$ProjectRoot) { $ProjectRoot=Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'release-files.ps1')
$null=Get-ReleaseVersion $ProjectRoot
$utf8=[Text.UTF8Encoding]::new($false,$true)
foreach($file in @(Get-ReleaseFiles $ProjectRoot)) {
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    $scriptFile=$file.Extension -in @('.ahk','.ps1')
    if (!$scriptFile -and $file.Extension -ne '.md') { continue }
    $bom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $text=$utf8.GetString($bytes)
    if ($scriptFile -and (!$bom -or $text -match '(?<!\r)\n|\r(?!\n)')) { throw "Script requires UTF-8 BOM/CRLF: $($file.Name)" }
    if (!$scriptFile -and ($bom -or $text.Contains("`r"))) { throw "Markdown requires UTF-8 without BOM/LF: $($file.Name)" }
    if ($file.Extension -eq '.ps1') {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count) {
            $parseError = $errors[0]
            throw "PowerShell parse failure: $($file.FullName):$($parseError.Extent.StartLineNumber):$($parseError.Extent.StartColumnNumber): $($parseError.Message)"
        }
    }
    # Application Gui.Show calls belong only to the shared presenter (menus/viewport wrappers excluded).
    if ($file.Extension -eq '.ahk' -and $file.Name -ne 'window_presenter.ahk' -and
        $text -match '(?m)^\s*(?!menu\.|popup\.|(?:panel\.)?viewport\.)[\w.]+\.Show\(') {
        throw "Presentation boundary regression: $($file.Name) directly shows a Gui"
    }
    if ($file.Extension -ne '.md') { continue }
    # Ignore examples inside fenced code, then check local Markdown targets and headings.
    $prose=[regex]::Replace($text,'(?ms)^```.*?^```[^\n]*','')
    foreach($link in [regex]::Matches($prose,'\]\(([^)]+)\)')) {
        $target=$link.Groups[1].Value.Trim('<','>')
        if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { continue }
        $parts=$target.Split('#',2)
        $path=if($parts[0]) { Join-Path $file.DirectoryName ([Uri]::UnescapeDataString($parts[0])) } else { $file.FullName }
        if (!(Test-Path -LiteralPath $path)) { throw "Broken link in $($file.Name): $target" }
        if ($parts.Count -eq 2 -and $parts[1] -and [IO.Path]::GetExtension($path) -eq '.md') {
            $headings=@([regex]::Matches([IO.File]::ReadAllText($path),'(?m)^#{1,6}\s+(.+?)\s*#*\s*$') | ForEach-Object {
                ([regex]::Replace($_.Groups[1].Value.ToLowerInvariant(),'[^\p{L}\p{N}_\- ]','')).Replace(' ','-')
            })
            if ($headings -cnotcontains [Uri]::UnescapeDataString($parts[1])) { throw "Missing heading in $($file.Name): $target" }
        }
    }
}
foreach ($module in @('src\shortcuts\shortcut_policy.ahk','src\settings\settings_schema.ahk','src\settings\settings_store.ahk','src\settings\settings_repository.ahk','src\settings\reaction_registration_repository.ahk','src\settings\library_storage_plan.ahk','src\storage\sqlite_connection.ahk','src\browser\worker_client.ahk','src\library\danmaku_library.ahk','src\library\library_service.ahk','src\library\profile_service.ahk','src\settings\settings_service.ahk')) {
    $moduleText = [IO.File]::ReadAllText((Join-Path $ProjectRoot $module))
    $moduleText = [regex]::Replace($moduleText, '(?m)^\s*;.*$', '')
    if ($moduleText -match '\b(PaletteWindow|ManagementWindow|ManagementStatus|ManagedList|EditingProfileId|ActiveEditorDialog|RefreshLibraryViews|RefreshManagement|RefreshPalette|ToolTip|MsgBox|InputBox|Gui)\b') {
        throw "Boundary regression: $module depends on GUI"
    }
}
Write-Output 'PASS: version, encodings, PowerShell syntax, module boundaries and local documentation links'
