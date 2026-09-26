# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# The connection owns worker lifetime, including an owner that disappears without shutdown.
$pipeRuntime = New-TestRuntime
$workerEntry = Join-Path $pipeRuntime 'src\browser\browser_worker.ps1'
foreach ($scenario in @('disconnect','missing-signal','missing-server')) {
    $pipeName = 'chatpalette-lifetime-' + [guid]::NewGuid().ToString('N')
    $server = $null; $signal = $null; $connection = $null; $process = $null
    try {
        if ($scenario -ne 'missing-server') {
            $server = [IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536)
            $connection = $server.BeginWaitForConnection($null,$null)
        }
        if ($scenario -eq 'disconnect') {
            $signal = [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,$pipeName+'-ready')
        }
        $process = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$workerEntry+'"'),'-PipeName',$pipeName -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $pipeRuntime ($scenario+'.stdout.txt')) -RedirectStandardError (Join-Path $pipeRuntime ($scenario+'.stderr.txt'))
        $null = $process.Handle
        $ownedHandle = $process.SafeHandle
        if ($server) {
            if (!$connection.AsyncWaitHandle.WaitOne(5000)) { throw "Worker did not connect: $scenario" }
            $server.EndWaitForConnection($connection)
        }
        if ($signal) {
            if (!$signal.WaitOne(5000)) { throw 'Worker did not signal readiness' }
            $request = [Text.Encoding]::UTF8.GetBytes("Seq=1`nWindow=0`nMode=fixture_no_action`n")
            $header = [BitConverter]::GetBytes([int]$request.Length)
            $server.Write($header,0,$header.Length)
            $server.Write($request,0,$request.Length)
            $server.Flush()
            if (!$signal.WaitOne(5000)) { throw 'Worker did not reply' }
            $reader = [IO.BinaryReader]::new($server,[Text.Encoding]::UTF8,$true)
            try {
                $size = $reader.ReadInt32()
                if ($size -lt 1 -or $size -gt 32768) { throw 'Invalid worker reply length' }
                $body = $reader.ReadBytes($size)
                $reply = [Text.Encoding]::UTF8.GetString($body)
                if ($body.Length -ne $size -or $reply -notmatch '(?m)^Seq=1$' -or $reply -notmatch '(?m)^State=unavailable$' -or $reply -notmatch '(?m)^Window=0$') { throw 'Worker did not complete the isolated request' }
            } finally { $reader.Dispose() }
            $server.Dispose(); $server = $null
        }
        $owned = $process; $process = $null
        $code = Wait-TestProcess -Process $owned -TimeoutMs 8000
        if ($code -ne 1 -or !$ownedHandle.IsClosed) { throw "Worker did not exit and release its handle: $scenario" }
    } finally {
        if ($server) { $server.Dispose() }
        if ($connection) { $connection.AsyncWaitHandle.Dispose() }
        if ($signal) { $signal.Dispose() }
        if ($process) { Wait-TestProcess -Process $process -TimeoutMs 8000 | Out-Null }
    }
}
Write-Output 'PASS: worker exits on pipe disconnect, missing notification and missing server; isolated protocol only'
