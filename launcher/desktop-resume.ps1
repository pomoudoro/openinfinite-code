# Sends the recovery message to the chat that hit the free limit, through the running
# Desktop service (POST /api/session/{id}/prompt). The call returns as soon as the
# message is queued; the turn runs in the Desktop, so nothing here waits for it.
#   -Mode send    find the chat, skip duplicates, send, start "verify" in background.
#                 Exit: 0 sent, 3 already sent, 4 chat unknown, 5 API failed.
#   -Mode verify  log when the reply starts (or the limit comes back). Runs detached.
param(
    [ValidateSet('send','verify')][string]$Mode = 'send',
    [int]$SinceMinutes = 20,
    [string]$Session = '',
    [int64]$SentMs = 0,
    [string]$ResultFile = '',
    # Everything except the POST: find the chat, check duplicates, wait for the service.
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$state = Join-Path $env:LOCALAPPDATA 'opencode-infinite'
$launchLog = if ($env:OC_LAUNCHLOG) { $env:OC_LAUNCHLOG } else { Join-Path $state 'launcher.log' }
$events = Join-Path $state 'recovery-events.jsonl'
$cli = if ($env:OC_CLI) { $env:OC_CLI } else { Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\resources\opencode-cli.exe' }
$targetPy = Join-Path $here 'resume-target.py'
# localhost must not go through the WARP proxy; the proxy vars stay so a service spawned here is still proxied.
$env:NO_PROXY = '127.0.0.1,localhost'
$env:no_proxy = '127.0.0.1,localhost'

function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Log([string]$Message) {
    try { Add-Content -LiteralPath $launchLog -Encoding OEM -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] [resume-api] ' + $Message) } catch {}
}
function Emit([string]$Type, $Data) {
    try {
        $o = [ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = $Type; data = $Data }
        [IO.File]::AppendAllText($events, (ConvertTo-Json -InputObject $o -Compress -Depth 6) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
function Quote([string]$v) {
    if ($v -notmatch '[\s"]') { return $v }
    $e = $v -replace '(\\*)"', '$1$1\"'
    $e = $e -replace '(\\+)$', '$1$1'
    return '"' + $e + '"'
}
function Invoke-Exe([string]$File, [string[]]$ArgList, [int]$TimeoutSec = 30) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = (($ArgList | ForEach-Object { Quote $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null } catch {}
        return [pscustomobject]@{ Code = 124; Out = ''; Err = 'timeout' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}
function Python-Json([string[]]$ArgList) {
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
    if (-not $py) { throw 'python not found' }
    $r = Invoke-Exe $py (@('-I', $targetPy) + $ArgList) 30
    $line = @($r.Out -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    if (-not $line) { throw ('resume-target.py gave no JSON (code ' + $r.Code + '): ' + $r.Err.Trim()) }
    return ($line | ConvertFrom-Json)
}
function Write-Result([hashtable]$Values) {
    if (-not $ResultFile) { return }
    $lines = foreach ($k in $Values.Keys) { 'RAPI_' + $k + '=' + ([string]$Values[$k] -replace '[\r\n]', ' ') }
    [IO.File]::WriteAllLines($ResultFile, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
}

# The hidden instruction (pt-BR). Built from char codes: this .ps1 has no BOM, and Windows
# PowerShell 5.1 would read accented literals as ANSI.
function Get-HiddenResumeText {
    if ($env:OC_RESUME_HIDDEN_TEXT) { return [string]$env:OC_RESUME_HIDDEN_TEXT }
    $a = [char]0xE1  # a acute
    return ('O limite gratuito foi atingido e o IP foi trocado. Continue a tarefa anterior exatamente de onde parou, sem repetir o que j' + $a + ' foi feito.')
}
# Body of the synthetic call: no "description" (a description makes the Desktop show it).
function Get-SyntheticBody([string]$Text) {
    return (ConvertTo-Json -Compress -InputObject ([ordered]@{
        text = $Text
        metadata = [ordered]@{ source = 'openinfinite'; kind = 'free-limit-resume' }
        delivery = 'queue'
    }))
}
function Request-Rotate {
    # Wait for the TUI the launcher opened after the send (tui.pid is written by :launch,
    # after :watch_start cleared the old markers), then mark the hit and close it.
    $tpf = Join-Path $state 'tui.pid'
    $hitf = Join-Path $state 'watch_hit.txt'
    $after = [DateTimeOffset]::FromUnixTimeMilliseconds($SentMs).UtcDateTime
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        try {
            $fi = Get-Item -LiteralPath $tpf -ErrorAction Stop
            if ($fi.LastWriteTimeUtc -ge $after) {
                $tp = [int](Get-Content -LiteralPath $tpf -TotalCount 1)
                if ($tp -gt 0 -and (Get-Process -Id $tp -ErrorAction SilentlyContinue)) {
                    Set-Content -LiteralPath $hitf -Value 'HIT'
                    Log ("closing TUI pid $tp so the launcher rotates the IP again session=$Session")
                    Emit 'resume_rotate_request' @{ session = $Session; tui_pid = $tp }
                    & taskkill.exe /T /F /PID $tp 2>$null | Out-Null
                    return
                }
            }
        } catch {}
        Start-Sleep -Seconds 1
    }
    Log ("no TUI opened within 90 s after the send; nothing closed session=$Session")
}

# Tests dot-source this file with OC_RESUME_LIB_ONLY=1 to get the functions without sending anything.
if ($env:OC_RESUME_LIB_ONLY -eq '1') { return }

if ($Mode -eq 'verify') {
    # Poll the DB until the reply starts or the limit comes back; stop with the Desktop.
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        try { $s = Python-Json @('status', '--session', $Session, '--since-ms', [string]$SentMs) } catch { continue }
        if ($s.first_token_ms) {
            $ms = [int64]$s.first_token_ms - $SentMs
            Log ("reply started session=$Session after=${ms}ms")
            Emit 'resume_first_token' @{ session = $Session; after_ms = $ms }
            exit 0
        }
        if ($s.limit_ms) {
            # The error lands ~2 s after the send, before the watcher starts tailing the log
            # (it reads from the size taken at :run), so the watcher never sees it. Hand off
            # the same way the watcher does: hit marker + kill the new TUI -> :quota_rotate.
            Log ("limit came back before the reply session=$Session; asking the launcher to rotate again")
            Emit 'resume_limit_again' @{ session = $Session }
            Request-Rotate
            exit 0
        }
        if (-not (Get-Process -Name OpenCode -ErrorAction SilentlyContinue)) {
            Log ("Desktop closed before the reply started session=$Session")
            exit 0
        }
    }
    Log ("no reply observed in 30 min session=$Session")
    exit 0
}

$t0 = NowMs
$message = $env:OC_MSG
if (-not $message) { $message = 'continue' }
# openinfinite-code: hidden resume. The official server (opencode 2.3+) has
# POST /api/session/{id}/synthetic: the text goes to the model and the Desktop timeline skips
# a synthetic message that has no description, so no "continue" shows in the chat. The text is
# an instruction to the model, not a chat line. Any failure falls back to the visible prompt.
$hidden = ($env:OC_RESUME_HIDDEN -eq '1')
$hiddenText = Get-HiddenResumeText
$checkText = if ($hidden) { $hiddenText } else { $message }
$since = $t0 - [int64]$SinceMinutes * 60000
try {
    $target = Python-Json @('target', '--since-ms', [string]$since)
} catch {
    Log ('target lookup failed: ' + $_.Exception.Message)
    $target = [pscustomobject]@{ session = $null; source = 'error' }
}
if (-not $target.session) {
    Log 'target chat unknown: no free-limit error found in the DB or log, nothing sent'
    Emit 'resume_target_unknown' @{ since_minutes = $SinceMinutes }
    Write-Result @{ STATUS = 'unknown' }
    exit 4
}
$dir = [string]$target.directory
$sid = [string]$target.session
Log ("target session=$sid dir=$dir source=$($target.source) title=$($target.title)")
Emit 'resume_target' @{ session = $sid; directory = $dir; source = $target.source }

try {
    $chk = Python-Json @('check', '--session', $sid, '--since-ms', [string]$since, '--text', $checkText)
    if ($chk.already_sent) {
        Log ("already sent after the last limit (at $($chk.sent_ms)): not sending again session=$sid")
        Emit 'resume_skipped_duplicate' @{ session = $sid; sent_ms = $chk.sent_ms }
        Write-Result @{ STATUS = 'duplicate'; SESSION = $sid; DIR = $dir; SOURCE = $target.source }
        exit 3
    }
} catch {
    Log ('duplicate check failed, sending anyway: ' + $_.Exception.Message)
}

# Readiness: poll the service once per second instead of a fixed pause.
$ready = $false
$readyDeadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $readyDeadline) {
    $r = Invoke-Exe $cli @('api', 'GET', '/api/info') 10
    if ($r.Code -eq 0 -and $r.Out -match '"version"') { $ready = $true; break }
    Start-Sleep -Seconds 1
}
$readyMs = (NowMs) - $t0
if (-not $ready) {
    Log ("service not answering after ${readyMs}ms; falling back to the CLI resume session=$sid")
    Emit 'resume_api_unavailable' @{ session = $sid; waited_ms = $readyMs }
    Write-Result @{ STATUS = 'api_failed'; SESSION = $sid; DIR = $dir; SOURCE = $target.source }
    exit 5
}

$body = ConvertTo-Json -Compress -InputObject ([ordered]@{ text = $message; delivery = 'queue' })
$synBody = Get-SyntheticBody $hiddenText
if ($DryRun) {
    Log ("dry run: would send to session=$sid dir=$dir ready=${readyMs}ms hidden=$hidden body=" + $(if ($hidden) { $synBody } else { $body }))
    Write-Result @{ STATUS = 'dryrun'; SESSION = $sid; DIR = $dir; SOURCE = $target.source; HIDDEN = [int]$hidden }
    exit 0
}
$sent = $null
$sentHidden = $false
if ($hidden) {
    for ($try = 1; $try -le 2 -and -not $sent; $try++) {
        $r = Invoke-Exe $cli @('api', 'POST', "/api/session/$sid/synthetic", '--data', $synBody, '--header', 'content-type:application/json') 30
        if ($r.Code -eq 0 -and $r.Out -match '"id"\s*:\s*"(msg_[^"]+)"') { $sent = $matches[1]; $sentHidden = $true; break }
        $why = (($r.Out + ' ' + $r.Err).Trim() -replace '\s+', ' ')
        if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
        Log ("hidden send try $try failed code=$($r.Code): $why")
        # 404 = this OpenCode has no synthetic route: no point in a second try.
        if ($why -match '404|Not Found|NotFound') { break }
        Start-Sleep -Seconds 1
    }
    if (-not $sent) {
        Log ("hidden resume unavailable; sending the visible message instead session=$sid")
        Emit 'resume_hidden_fallback' @{ session = $sid }
    }
}
for ($try = 1; $try -le 3 -and -not $sent; $try++) {
    $r = Invoke-Exe $cli @('api', 'POST', "/api/session/$sid/prompt", '--data', $body, '--header', 'content-type:application/json') 30
    if ($r.Code -eq 0 -and $r.Out -match '"id"\s*:\s*"(msg_[^"]+)"') { $sent = $matches[1]; break }
    $why = (($r.Out + ' ' + $r.Err).Trim() -replace '\s+', ' ')
    if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
    Log ("send try $try failed code=$($r.Code): $why")
    Start-Sleep -Seconds 1
}
if (-not $sent) {
    Emit 'resume_api_failed' @{ session = $sid }
    Write-Result @{ STATUS = 'api_failed'; SESSION = $sid; DIR = $dir; SOURCE = $target.source }
    exit 5
}
$sentMs = NowMs
Log ("delivered session=$sid message=$sent hidden=$sentHidden ready=${readyMs}ms total=$($sentMs - $t0)ms")
Emit 'resume_delivered' @{ session = $sid; message = $sent; hidden = $sentHidden; ready_ms = $readyMs; total_ms = ($sentMs - $t0) }
Write-Result @{ STATUS = 'sent'; SESSION = $sid; DIR = $dir; SOURCE = $target.source; MSGID = $sent; HIDDEN = [int]$sentHidden }

$psExe = Join-Path $PSHOME 'powershell.exe'
$self = $MyInvocation.MyCommand.Path
Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote $self), '-Mode', 'verify', '-Session', $sid, '-SentMs', [string]($sentMs - 2000)) | Out-Null
exit 0
