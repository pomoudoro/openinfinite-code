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
# ---- hidden resume for terminal windows (openinfinite-code) ------------------------------------
# "opencode run" always writes a visible user message. For a hidden resume the runner starts its
# own private server ("opencode serve", born with this proxy env, like run --standalone), sends
# the resume as a synthetic message (no description: the UIs skip it), auto-approves permission
# requests when --auto was asked, waits until the turn ends (the newest "idle" message) and stops
# the server. Measured on 2.3.2: the server answers in ~0.9 s and the turn ends with an idle
# message whose outcome is "succeeded". Any failure BEFORE the message is accepted returns $null
# and the caller falls back to "opencode run" (visible); after that, the result is final.
function Get-HiddenResumeText {
    if ($env:OC_RESUME_HIDDEN_TEXT) { return [string]$env:OC_RESUME_HIDDEN_TEXT }
    $a = [char]0xE1  # a acute; this file has no BOM, so no accented literals
    return ('O limite gratuito foi atingido e o IP foi trocado. Continue a tarefa anterior exatamente de onde parou, sem repetir o que j' + $a + ' foi feito.')
}
function Get-SyntheticBody([string]$Text) {
    return (ConvertTo-Json -Compress -InputObject ([ordered]@{
        text = $Text
        metadata = [ordered]@{ source = 'openinfinite'; kind = 'free-limit-resume' }
        delivery = 'queue'
    }))
}
# "-s ses_x --standalone --auto -m opencode/model#variant" -> what the hidden path needs.
function Get-ResumeFlags([string]$Flags) {
    $r = [ordered]@{ session = ''; standalone = $false; auto = $false; model = '' }
    $tok = @($Flags -split '\s+' | Where-Object { $_ })
    for ($i = 0; $i -lt $tok.Count; $i++) {
        switch -Exact ($tok[$i]) {
            '-s' { if ($i + 1 -lt $tok.Count) { $r.session = $tok[$i + 1]; $i++ } }
            '--session' { if ($i + 1 -lt $tok.Count) { $r.session = $tok[$i + 1]; $i++ } }
            '-m' { if ($i + 1 -lt $tok.Count) { $r.model = $tok[$i + 1]; $i++ } }
            '--model' { if ($i + 1 -lt $tok.Count) { $r.model = $tok[$i + 1]; $i++ } }
            '--standalone' { $r.standalone = $true }
            '--auto' { $r.auto = $true }
        }
    }
    return $r
}
# "opencode/deepseek-v4.1-flash-free#max" -> the body of POST /api/session/{id}/model.
function Get-ModelBody([string]$Model) {
    if ($Model -notmatch '^([^/]+)/([^#]+)(#(.+))?$') { return '' }
    $m = [ordered]@{ id = $matches[2]; providerID = $matches[1] }
    if ($matches[4]) { $m['variant'] = $matches[4] }
    return (ConvertTo-Json -Compress -InputObject ([ordered]@{ model = $m }))
}
function Invoke-CliCapture([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 30) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($ArgList | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null } catch { }
        return [pscustomobject]@{ Code = 124; Out = ''; Err = 'timeout' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}
function Invoke-HiddenResume([string]$Exe, $Flags, [string]$OutPath, [string]$ErrPath, [int]$Timeout, [int]$IdleLimit) {
    $sid = [string]$Flags.session
    $pwBytes = New-Object byte[] 24
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($pwBytes)
    $env:OPENCODE_PASSWORD = [Convert]::ToBase64String($pwBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $env:NO_PROXY = '127.0.0.1,localhost,::1'; $env:no_proxy = $env:NO_PROXY
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $url = 'http://127.0.0.1:' + $port
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = 'serve --hostname 127.0.0.1 --port ' + $port
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $srv = $null
    try {
        $srv = [System.Diagnostics.Process]::Start($psi)
        $null = $srv.StandardOutput.ReadToEndAsync(); $null = $srv.StandardError.ReadToEndAsync()
        $ready = $false
        $end = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $end -and -not $srv.HasExited) {
            $r = Invoke-CliCapture $Exe @('api', '--server', $url, 'GET', '/api/info') 10
            if ($r.Code -eq 0 -and $r.Out -match '"version"') { $ready = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { Write-ResumeLog "hidden: private server did not answer; falling back to opencode run"; return $null }
        Write-ResumeLog "hidden: private server pid=$($srv.Id) ready session=$sid"
        if ($Flags.model) {
            $mb = Get-ModelBody ([string]$Flags.model)
            $g = Invoke-CliCapture $Exe @('api', '--server', $url, 'GET', "/api/session/$sid") 20
            if ($g.Code -ne 0) { Write-ResumeLog ("hidden: session $sid not found on the private server; falling back"); return $null }
            $cur = $null
            try { $cur = ($g.Out | ConvertFrom-Json).data.model } catch { }
            $new = $null
            try { $new = ($mb | ConvertFrom-Json).model } catch { }
            $same = ($cur -and $new -and [string]$cur.id -eq [string]$new.id -and [string]$cur.providerID -eq [string]$new.providerID -and [string]$cur.variant -eq [string]$new.variant)
            if ($mb -and -not $same) {
                $s = Invoke-CliCapture $Exe @('api', '--server', $url, 'POST', "/api/session/$sid/model", '--data', $mb, '--header', 'content-type:application/json') 20
                Write-ResumeLog "hidden: model switch to $($Flags.model) code=$($s.Code)"
            }
        }
        $body = Get-SyntheticBody (Get-HiddenResumeText)
        $r = Invoke-CliCapture $Exe @('api', '--server', $url, 'POST', "/api/session/$sid/synthetic", '--data', $body, '--header', 'content-type:application/json') 30
        if ($r.Code -ne 0 -or $r.Out -notmatch '"created"\s*:\s*(\d+)') {
            Write-ResumeLog ("hidden: synthetic refused code=$($r.Code) " + (($r.Out + ' ' + $r.Err) -replace '\s+', ' ').Trim()); return $null
        }
        $sentMs = [int64]$matches[1]
        Write-ResumeLog "hidden: resume sent session=$sid created=$sentMs auto=$($Flags.auto)"
        # From here the message is in the chat: wait for the turn, never fall back.
        $t0 = Get-Date; $lastAct = Get-Date; $lastSnap = ''; $outcome = ''; $idleJson = ''; $approved = 0
        while ($true) {
            Start-Sleep -Seconds 2
            if ($srv.HasExited) { [IO.File]::WriteAllText($ErrPath, 'hidden resume: the private server stopped before the turn ended'); return 1 }
            if ($Flags.auto) {
                $pl = Invoke-CliCapture $Exe @('api', '--server', $url, 'GET', "/api/session/$sid/permission") 15
                $reqs = @()
                try { $reqs = @(([string]$pl.Out | ConvertFrom-Json).data | Where-Object { $_ -and $_.id }) } catch { }
                foreach ($q in $reqs) {
                    $rid = [string]$q.id
                    $rr = Invoke-CliCapture $Exe @('api', '--server', $url, 'POST', "/api/session/$sid/permission/$rid/reply", '--data', '{"decision":"once"}', '--header', 'content-type:application/json') 15
                    $approved++
                    Write-ResumeLog "hidden: permission $rid approved (auto) code=$($rr.Code)"
                }
            }
            $ms = Invoke-CliCapture $Exe @('api', '--server', $url, 'GET', "/api/session/$sid/message?limit=8") 20
            $snap = [string]$ms.Out
            if ($snap -and $snap -ne $lastSnap) { $lastSnap = $snap; $lastAct = Get-Date }
            try { $list = @(($snap | ConvertFrom-Json).data) } catch { $list = @() }
            $idle = @($list | Where-Object { $_.type -eq 'idle' -and [int64]$_.time.created -gt $sentMs } | Select-Object -First 1)
            if ($idle.Count) { $outcome = [string]$idle[0].outcome; $idleJson = ConvertTo-Json -Compress -Depth 8 -InputObject $idle[0]; break }
            $el = ((Get-Date) - $t0).TotalSeconds
            if ($el -ge $Timeout -or ((Get-Date) - $lastAct).TotalSeconds -ge $IdleLimit) {
                Write-ResumeLog "hidden: timeout elapsed=$([int]$el)s; interrupting session=$sid"
                $null = Invoke-CliCapture $Exe @('api', '--server', $url, 'POST', "/api/session/$sid/interrupt") 15
                return 124
            }
        }
        $texts = @($list | Where-Object { $_.type -eq 'assistant' -and [int64]$_.time.created -gt $sentMs } | ForEach-Object { @($_.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" })
        [IO.File]::WriteAllText($OutPath, (@($texts) -join "`n"), (New-Object Text.UTF8Encoding($false)))
        Write-ResumeLog "hidden: turn ended outcome=$outcome approved=$approved elapsed=$([int]((Get-Date) - $t0).TotalSeconds)s"
        if ($outcome -eq 'succeeded') { return 0 }
        # The idle message carries the error (free limit, model, auth...): the launcher reads resume.err.
        [IO.File]::WriteAllText($ErrPath, $idleJson, (New-Object Text.UTF8Encoding($false)))
        return 1
    } finally {
        if ($srv -and -not $srv.HasExited) { try { & taskkill.exe /T /F /PID $srv.Id 2>$null | Out-Null } catch { } }
        $env:OPENCODE_PASSWORD = ''
    }
}

# Tests dot-source this file with OC_RESUME_LIB_ONLY=1 to get the functions without running.
if ($env:OC_RESUME_LIB_ONLY -eq '1') { return }

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
    # openinfinite-code: hidden resume through a private server (see Invoke-HiddenResume).
    if ($env:OC_RESUME_HIDDEN -eq '1') {
        $flags = Get-ResumeFlags ([string]$env:OC_FL)
        if ($flags.session -and $flags.standalone) {
            $hr = Invoke-HiddenResume $exe $flags $stdout $stderr $timeout $idleLimit
            if ($null -ne $hr) {
                Write-ResumeLog "hidden resume finished exit=$hr session=$($flags.session)"
                exit $hr
            }
            Write-ResumeLog 'hidden resume unavailable; sending the visible message with opencode run'
        } else {
            Write-ResumeLog "hidden resume skipped: needs -s <session> and --standalone (args=$env:OC_FL)"
        }
    }
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