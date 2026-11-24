param()
$ErrorActionPreference = 'Stop'
function Write-ResumeLog([string]$Message) {
    if (-not $env:OC_LOGF) { return }
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $env:OC_LOGF -Value "[$stamp] [resume] $Message" -Encoding UTF8
    } catch { }
}
function Quote-ProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}
try {
    $exe = $env:OC_EXE
    if ($exe -match '\.(cmd|bat)$') {
        $candidate = Join-Path (Split-Path -Parent $exe) 'node_modules\@opencode\cli\bin\opencode.exe'
        if (Test-Path -LiteralPath $candidate) {
            $exe = $candidate
        } else {
            $exe = $null
        }
    }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        $desktopCli = Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\resources\opencode-cli.exe'
        if (Test-Path -LiteralPath $desktopCli) {
            $exe = $desktopCli
            Write-ResumeLog "fallback: using Desktop bundled CLI $desktopCli"
        }
    }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        Write-ResumeLog 'abort: OpenCode executable missing'
        exit 9009
    }
    $arguments = @('run')
    if ($env:OC_FL) { $arguments += @($env:OC_FL -split '\s+' | Where-Object { $_ }) }
    if ($env:OC_MSG) { $arguments += [string]$env:OC_MSG }
    $stdout = $env:OC_OUTF
    $stderr = $env:OC_ERRF
    if (-not $stdout -or -not $stderr) { throw 'OC_OUTF/OC_ERRF not configured' }
    Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    $timeout = 300
    if ($env:OC_TO -match '^\d+$') { $timeout = [Math]::Max(30,[int]$env:OC_TO) }
    # v3.5.3: the total cap is a safety net, not a per-turn deadline. Agent turns can
    # legitimately run for many minutes; the idle limit below already detects a dead
    # route. A short OC_TO (90 s) killed live turns and re-sent the resume prompt.
    $timeout = [Math]::Max($timeout, 1800)
    $idleLimit = 600
    if ($env:OC_IDLE -match '^\d+$') { $idleLimit = [Math]::Max(30,[int]$env:OC_IDLE) }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $exe
    $startInfo.Arguments = (($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $outFile = [System.IO.File]::Create($stdout)
    $errFile = [System.IO.File]::Create($stderr)
    $outTask = $null
    $errTask = $null
    if (-not $process.Start()) { throw 'Process.Start returned false' }
    Write-ResumeLog "child started pid=$($process.Id) exe=$exe model=$env:OC_MODEL timeout=$($timeout)s idle=$($idleLimit)s args=$($startInfo.Arguments)"
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outFile)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($errFile)
    $elapsed = 0
    $lastActivity = 0
    $lastBytes = -1L
    $lastHeartbeat = 0
    $timedOut = $false
    while (-not $process.WaitForExit(1000)) {
        $elapsed++
        $bytes = 0L
        try { $outFile.Flush(); $errFile.Flush(); $bytes = $outFile.Length + $errFile.Length } catch { }
        if ($bytes -ne $lastBytes) { $lastBytes = $bytes; $lastActivity = $elapsed }
        if (($elapsed - $lastHeartbeat) -ge 15) {
            $lastHeartbeat = $elapsed
            Write-ResumeLog "progress elapsed=$($elapsed)s stdout=$($outFile.Length)B stderr=$($errFile.Length)B pid=$($process.Id)"
        }
        if ($elapsed -ge $timeout) {
            $timedOut = $true
            Write-ResumeLog "total timeout elapsed=$($elapsed)s limit=$($timeout)s pid=$($process.Id)"
            break
        }
        if (($elapsed - $lastActivity) -ge $idleLimit) {
            $timedOut = $true
            Write-ResumeLog "idle timeout elapsed=$($elapsed)s idle_limit=$($idleLimit)s pid=$($process.Id)"
            break
        }
    }
    if ($timedOut -and -not $process.HasExited) {
        try { & taskkill.exe /T /F /PID $process.Id 2>$null | Out-Null } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
    } elseif (-not $timedOut) { $process.WaitForExit() }
    try { if ($outTask) { $outTask.Wait(5000) | Out-Null } } catch { }
    try { if ($errTask) { $errTask.Wait(5000) | Out-Null } } catch { }
    try { $outFile.Flush(); $errFile.Flush() } catch { }
    $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    Write-ResumeLog "child finished exit=$exitCode elapsed=$($elapsed)s model=$env:OC_MODEL"
    $outFile.Dispose()
    $errFile.Dispose()
    $process.Dispose()
    exit $exitCode
} catch {
    Write-ResumeLog "runner exception: $($_.Exception.Message)"
    try { if ($outFile) { $outFile.Dispose() }; if ($errFile) { $errFile.Dispose() } } catch { }
    [Console]::Error.WriteLine("resume-runner: " + $_.Exception.Message)
    exit 1
}