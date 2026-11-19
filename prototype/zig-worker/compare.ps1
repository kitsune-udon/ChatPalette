[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ZigExe,
    [Parameter(Mandatory=$true)][ValidateRange(1,[long]::MaxValue)][long]$WindowHandle,
    [ValidateRange(1,1000)][int]$Repeats = 5,
    [ValidatePattern('\A(?:[A-Za-z0-9_-]{11})?\z')][string]$ExpectedVideo = '',
    [ValidateSet('browser_context','verify_input')][string]$FirstMode = 'browser_context',
    [object]$FixtureExpectation,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$zigPath = (Get-Item -LiteralPath $ZigExe -ErrorAction Stop).FullName
$repo = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..')).FullName
$workerScript = Join-Path $repo 'src\browser\browser_worker.ps1'
$windowsPS = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($OutputPath) {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $OutputPath) { throw 'Choose a new report path.' }
}
$fixtureChecked = $null -ne $FixtureExpectation
$fixtureScenario = $null
if ($fixtureChecked) {
    $keys = if ($FixtureExpectation -is [Collections.IDictionary]) { $FixtureExpectation.Keys } else { $FixtureExpectation.PSObject.Properties.Name }
    foreach ($key in @('Scenario','ContextState','DetectedVideo','InputState','InputDetail')) {
        if ($keys -notcontains $key -or $FixtureExpectation.$key -isnot [string]) { throw "Invalid fixture expectation field: $key" }
    }
    if ($keys -contains 'ExpectedVideo') {
        if ($FixtureExpectation.ExpectedVideo -cnotmatch '\A(?:[A-Za-z0-9_-]{11})?\z' -or
            ($PSBoundParameters.ContainsKey('ExpectedVideo') -and $ExpectedVideo -cne $FixtureExpectation.ExpectedVideo)) {
            throw 'Requested video and fixture expectation disagree.'
        }
        $ExpectedVideo = $FixtureExpectation.ExpectedVideo
    }
    $fixtureScenario = if ($FixtureExpectation.Scenario -cin @('Chat','Comment','Search','Address','Popout','Changed','NonYouTube')) {
        $FixtureExpectation.Scenario
    } else { 'custom' }
}

# Keep host-side parsing/reporting outside both timed intervals. Use the production
# framing, process identity and ready event, with one deadline per whole request.
if (-not ('ChatPaletteProbe.Trial' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace ChatPaletteProbe {
    public sealed class Reply {
        public string State, Video, Detail;
        public double Milliseconds;
    }
    public sealed class Trial {
        public readonly Dictionary<string, Reply> Replies = new Dictionary<string, Reply>();
        public string Error, Cleanup;
        static readonly Encoding Utf8 = new UTF8Encoding(false, true);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint client);

        static int Remaining(Stopwatch clock, double deadline) {
            double remaining = deadline - clock.Elapsed.TotalMilliseconds;
            if (remaining <= 0) throw new TimeoutException();
            return (int)Math.Ceiling(remaining);
        }
        static void Wait(Task task, Stopwatch clock, double deadline) {
            try {
                if (!task.Wait(Remaining(clock, deadline))) throw new TimeoutException();
            } catch (AggregateException e) { throw e.GetBaseException(); }
        }
        static void Wait(EventWaitHandle signal, Stopwatch clock, double deadline) {
            if (!signal.WaitOne(Remaining(clock, deadline))) throw new TimeoutException();
        }
        static void ReadExactly(NamedPipeServerStream pipe, byte[] bytes, Stopwatch clock, double deadline) {
            for (int offset = 0; offset < bytes.Length;) {
                Task<int> read = pipe.ReadAsync(bytes, offset, bytes.Length-offset);
                Wait(read, clock, deadline);
                int count = read.Result;
                if (count == 0) throw new EndOfStreamException();
                offset += count;
            }
        }
        static Reply Parse(byte[] bytes, string seq, string window, string mode) {
            var fields = new Dictionary<string,string>(StringComparer.Ordinal);
            foreach (string line in Utf8.GetString(bytes).Split('\n')) {
                int index = line.IndexOf('=');
                if (index <= 0 || line.IndexOf('\r') >= 0) throw new InvalidDataException();
                fields.Add(line.Substring(0,index), line.Substring(index+1));
            }
            if (fields["Seq"] != seq || fields["Window"] != window) throw new InvalidDataException();
            var reply = new Reply { State = fields["State"], Video = fields["Video"],
                Detail = fields.ContainsKey("Detail") ? fields["Detail"] : "" };
            bool known = reply.State == "ok" || reply.State == "unavailable" ||
                (mode == "verify_input" && (reply.State == "wrong_input" || reply.State == "changed"));
            if (!known || (reply.State != "unavailable" &&
                !System.Text.RegularExpressions.Regex.IsMatch(reply.Video, @"\A[A-Za-z0-9_-]{11}\z")))
                throw new InvalidDataException();
            if (reply.State == "ok" && mode == "verify_input" &&
                reply.Detail != "chat" && reply.Detail != "comment") throw new InvalidDataException();
            return reply;
        }
        public static Trial Run(string exe, string script, string directory, string window, string video, string[] modes) {
            Trial result = new Trial();
            string name = "youtube-helper-" + Guid.NewGuid().ToString("B").ToUpperInvariant();
            string stage = "prepare";
            NamedPipeServerStream pipe = null;
            EventWaitHandle signal = null;
            Process process = null;
            bool started = false;
            try {
                pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous, 65536, 65536);
                signal = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-ready");
                string args = script == "" ? "" : "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" ";
                var info = new ProcessStartInfo(exe, args + "-PipeName " + name) {
                    WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true
                };
                process = new Process { StartInfo = info };
                Task connection = pipe.WaitForConnectionAsync();
                stage = "start";
                Stopwatch clock = Stopwatch.StartNew();
                if (!process.Start()) throw new InvalidOperationException();
                started = true;
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                for (int i = 0; i < modes.Length; i++) {
                    string mode = modes[i];
                    string seq = (i+1).ToString(CultureInfo.InvariantCulture);
                    byte[] payload = Utf8.GetBytes("Seq=" + seq + "\nWindow=" + window + "\nMode=" + mode + "\nVideo=" + video + "\n");
                    byte[] frame = new byte[4 + payload.Length];
                    Buffer.BlockCopy(BitConverter.GetBytes(payload.Length), 0, frame, 0, 4);
                    Buffer.BlockCopy(payload, 0, frame, 4, payload.Length);
                    double begin = i == 0 ? 0 : clock.Elapsed.TotalMilliseconds;
                    double deadline = begin + (mode == "verify_input" ? 2500 : 8000);
                    if (i == 0) {
                        stage = "connect";
                        Wait(connection, clock, deadline);
                        uint client;
                        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out client) || client != process.Id)
                            throw new InvalidDataException();
                        stage = "ready";
                        Wait(signal, clock, deadline);
                    }
                    stage = mode + ".write";
                    Wait(pipe.WriteAsync(frame, 0, frame.Length), clock, deadline);
                    stage = mode + ".read";
                    var header = new byte[4];
                    ReadExactly(pipe, header, clock, deadline);
                    int length = BitConverter.ToInt32(header, 0);
                    if (length < 1 || length > 32768) throw new InvalidDataException();
                    var body = new byte[length];
                    ReadExactly(pipe, body, clock, deadline);
                    double received = clock.Elapsed.TotalMilliseconds;
                    if (received > deadline) throw new TimeoutException();
                    stage = mode + ".notification";
                    Wait(signal, clock, deadline);
                    stage = mode + ".reply";
                    Reply reply = Parse(body, seq, window, mode);
                    reply.Milliseconds = received - begin;
                    result.Replies.Add(mode, reply);
                }
            } catch (Exception e) {
                result.Error = stage + "." + e.GetType().Name;
            } finally {
                if (pipe != null) pipe.Dispose();
                if (signal != null) signal.Dispose();
                if (process != null) {
                    try {
                        if (started && !process.WaitForExit(250)) {
                            try { process.Kill(); } catch (InvalidOperationException) { if (!process.HasExited) throw; }
                            if (!process.WaitForExit(2000)) throw new TimeoutException();
                            result.Cleanup = "forced";
                        }
                    } catch (Exception e) { result.Cleanup = "failed." + e.GetType().Name; }
                    finally { process.Dispose(); }
                }
            }
            return result;
        }
    }
}
'@
}

function Get-PublicReply($Reply) {
    if ($null -eq $Reply) { return $null }
    $detail = if (!$Reply.Detail) { 'empty' } elseif ($Reply.Detail -cin @('chat','comment')) { $Reply.Detail } else { 'other' }
    [ordered]@{ state=$Reply.State; hasVideo=[bool]$Reply.Video; detail=$detail; milliseconds=[math]::Round($Reply.Milliseconds,3) }
}
function Get-Median($Values) {
    if (!$Values.Count) { return $null }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    return [math]::Round(($sorted[[int][math]::Floor(($n-1)/2)] + $sorted[[int][math]::Floor($n/2)])/2,3)
}

$FirstMode = $FirstMode.ToLowerInvariant()
$secondMode = if ($FirstMode -eq 'browser_context') { 'verify_input' } else { 'browser_context' }
$modes = [string[]]@($FirstMode,$secondMode)
$windowText = $WindowHandle.ToString([Globalization.CultureInfo]::InvariantCulture)
$samples = [Collections.Generic.List[object]]::new()
$passed = $true
$allEqual = $true
$timings = @{}
foreach ($mode in $modes) {
    $timings[$mode] = @{ powershell=[Collections.Generic.List[double]]::new(); zig=[Collections.Generic.List[double]]::new() }
}
for ($round = 1; $round -le $Repeats; $round++) {
    $order = if ($round % 2) { 'powershell','zig' } else { 'zig','powershell' }
    $runs = @{}
    $errors = [ordered]@{}
    foreach ($name in $order) {
        $exe = if ($name -eq 'powershell') { $windowsPS } else { $zigPath }
        $entry = if ($name -eq 'powershell') { $workerScript } else { '' }
        $run = [ChatPaletteProbe.Trial]::Run($exe,$entry,$repo,$windowText,$ExpectedVideo,$modes)
        $runs[$name] = $run
        if ($run.Error -or $run.Cleanup) { $errors[$name] = [ordered]@{ error=$run.Error; cleanup=$run.Cleanup } }
    }
    $match = $errors.Count -eq 0
    $fixturePassed = $true
    $comparisons = [ordered]@{}
    foreach ($mode in $modes) {
        $a = $runs.powershell.Replies[$mode]
        $b = $runs.zig.Replies[$mode]
        $both = $null -ne $a -and $null -ne $b
        $stateMatch = $both -and $a.State -ceq $b.State
        $videoMatch = $both -and $a.Video -ceq $b.Video
        $detailMatch = $both -and $a.Detail -ceq $b.Detail
        $equal = $stateMatch -and $videoMatch -and $detailMatch
        if (!$equal) { $match = $false }
        $fixtureMatches = $null
        if ($fixtureChecked) {
            $expectedState = if ($mode -eq 'browser_context') { $FixtureExpectation.ContextState } else { $FixtureExpectation.InputState }
            $expectedDetail = if ($mode -eq 'browser_context') { '' } else { $FixtureExpectation.InputDetail }
            $fixtureMatches = [ordered]@{}
            foreach ($name in $order) {
                $reply = $runs[$name].Replies[$mode]
                $fixtureMatches[$name] = $null -ne $reply -and $reply.State -ceq $expectedState -and
                    $reply.Video -ceq $FixtureExpectation.DetectedVideo -and $reply.Detail -ceq $expectedDetail
                if (!$fixtureMatches[$name]) { $fixturePassed = $false }
            }
        }
        $comparisons[$mode] = [ordered]@{
            powershell=(Get-PublicReply $a); zig=(Get-PublicReply $b); equal=$equal
            stateEqual=$stateMatch; videoEqual=$videoMatch; detailEqual=$detailMatch; fixtureMatches=$fixtureMatches; timingEligible=$false
        }
    }
    if (!$match) { $allEqual = $false }
    $roundPassed = $match -and $fixturePassed
    if (!$roundPassed) { $passed = $false }
    foreach ($mode in $modes) {
        # A matching refusal tests parity, but cannot support a speed claim for a successful operation.
        if ($roundPassed -and $runs.powershell.Replies[$mode].State -ceq 'ok') {
            $comparisons[$mode].timingEligible = $true
            foreach ($name in $order) { $timings[$mode][$name].Add($runs[$name].Replies[$mode].Milliseconds) }
        }
    }
    $samples.Add([ordered]@{ trial=$round; order=$order; equal=$match; passed=$roundPassed; errors=$errors; modes=$comparisons })
}

$summary = [ordered]@{}
foreach ($mode in $modes) {
    $summary[$mode] = [ordered]@{
        measurement=$(if ($mode -eq $FirstMode) { 'process-start-to-first-response' } else { 'warm-request-to-response' })
        pairs=$timings[$mode].zig.Count
        powershellMedianMs=(Get-Median $timings[$mode].powershell); zigMedianMs=(Get-Median $timings[$mode].zig)
    }
}
$report = [ordered]@{ firstMode=$FirstMode; repeats=$Repeats; expectedVideoSupplied=[bool]$ExpectedVideo;
    fixtureChecked=$fixtureChecked; fixtureScenario=$fixtureScenario; equal=$allEqual; passed=$passed; summary=$summary; trials=$samples }
$json = $report | ConvertTo-Json -Depth 10
if ($OutputPath) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath))
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
Write-Output $json
if (!$passed) { exit 1 }
exit 0
