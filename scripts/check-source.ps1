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
        if ($errors.Count) { throw "PowerShell parse failure: $($file.Name): $($errors[0].Message)" }
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
Write-Output 'PASS: version, encodings, PowerShell syntax and local documentation links'
