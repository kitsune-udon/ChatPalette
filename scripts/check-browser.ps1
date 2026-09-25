[CmdletBinding(DefaultParameterSetName="Inspect")]
param(
    [Parameter(Mandatory=$true,ParameterSetName="List")][switch]$List,
    [Parameter(Mandatory=$true,ParameterSetName="Inspect")][long]$WindowHandle,
    [Parameter(ParameterSetName="Inspect")][ValidateSet('Auto','Watch','Popout')][string]$PageKind="Auto",
    [switch]$Exercise,
    [Parameter(Mandatory=$true,ParameterSetName="Inspect")][string]$OutputPath
)
$ErrorActionPreference='Stop'
if (!$List) {
    $OutputPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $OutputPath) { throw 'Report already exists; choose a new path.' }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath)) | Out-Null
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\browser\browser_worker.ps1') -Library
if ($List) {
    foreach($window in [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)) {
        try {
            $process=Get-Process -Id $window.Current.ProcessId
            if ($process.ProcessName -in @('chrome','msedge','brave','firefox','opera','vivaldi')) {
                [pscustomobject]@{Browser=$process.ProcessName;WindowHandle=$window.Current.NativeWindowHandle}
            }
        } catch { }
    }
    return
}
$report=[ordered]@{Time=[DateTime]::UtcNow.ToString('o'); Browser=''; BrowserVersion=''; PageKind='unknown';
    Foreground=$false; VideoDetected=$false; ChatDetected=$false; LauncherDetected=$false;
    Focus='not-run'; Hover='not-run'; Display='not-verified'; Error=''}
try {
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    $process=Get-Process -Id $root.Current.ProcessId
    if ($process.ProcessName -notin @('chrome','msedge','brave','firefox','opera','vivaldi')) { throw 'Unsupported browser process' }
    $report.Browser=$process.ProcessName
    $report.BrowserVersion=$process.MainModule.FileVersionInfo.FileVersion
    $report.Foreground=Test-ReactionForeground $WindowHandle
    $report.VideoDetected=[bool](Read-BrowserVideoId $WindowHandle)
    if ($report.VideoDetected) {
        $address=$script:AddressBarCache[$WindowHandle].Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if ($address -notmatch '^https?://') { $address='https://'+$address }
        $report.PageKind=if (([uri]$address).AbsolutePath -in @('/live_chat','/live_chat_replay')) {'Popout'} else {'Watch'}
        if ($PageKind -ne 'Auto' -and $PageKind -ne $report.PageKind) { throw 'Unexpected page kind' }
    }
    $report.ChatDetected=$null -ne (Find-ChatInput $WindowHandle)
    $report.LauncherDetected=$null -ne (Find-ReactionLauncher $WindowHandle)
    if ($Exercise) {
        if (!$report.Foreground -or !$report.VideoDetected) { throw 'Place the target video in the foreground before exercising actions' }
        $report.Focus=(Invoke-PageAction @{Seq=1;Window=$WindowHandle;Mode='chat_focus';Video=''}).State
        $report.Hover=(Invoke-PageAction @{Seq=2;Window=$WindowHandle;Mode='reactions_show';Video=''}).State
    }
} catch { $report.Error='Inspection failed; verify target window, foreground and accessible live chat.' }
# Never include titles, URLs, field values or exception text in a shareable report.
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json))
$stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $stream.Write($bytes,0,$bytes.Length) }
finally { $stream.Dispose() }
[pscustomobject]$report
if ($report.Error -or !$report.VideoDetected -or !$report.ChatDetected -or !$report.LauncherDetected -or
    ($Exercise -and ($report.Focus -ne 'focused' -or $report.Hover -ne 'hovered'))) { exit 1 }
