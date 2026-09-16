# Shared UI Automation operations. No reaction registration or disk access.
if (!(Get-Variable WindowWalkers -Scope Script -ErrorAction SilentlyContinue)) { $script:WindowWalkers = @{} }
function Get-BrowserProcessName([long]$WindowHandle) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    return (Get-Process -Id $root.Current.ProcessId).ProcessName
}

function Test-ElementWindow($Element, [long]$WindowHandle) {
    if ($null -eq $Element -or $WindowHandle -le 0) { return $false }
    if (!$script:WindowWalkers.ContainsKey($WindowHandle)) {
        if ($script:WindowWalkers.Count -ge 16) { $script:WindowWalkers.Clear() }
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NativeWindowHandleProperty, [int]$WindowHandle)
        $script:WindowWalkers[$WindowHandle] = [System.Windows.Automation.TreeWalker]::new($condition)
    }
    return $null -ne $script:WindowWalkers[$WindowHandle].Normalize($Element)
}
