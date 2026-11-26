# warp-pool.ps1 - WARP egress pool (wgcf + wireproxy).
# One wireproxy per slot, each with its own wgcf identity. The exit IP must be IPv6 and unique:
# the free WARP IPv4 egress is shared CGNAT, so only the per-device IPv6 tells slots apart.
# Profiles are normalized to keep the device IPv6 and ::/0, DNS = 1.1.1.1 and the peer fixed at
# 162.159.192.1:2408 (the AAAA of engage.cloudflareclient.com is unreachable on this host).
# No adapter, no route change, no administrator prompt, no warp-cli state change.
# State: <State>\instances\egress\slotNN, <State>\pool, <State>\bin, <State>\recovery-events.jsonl.
# Never prints PrivateKey or PresharedKey.
[CmdletBinding()]
param(
  [ValidateSet('up','status','claim','release','rotate','verify','down','daemon','reap')]
  [string]$Action = 'status',
  [int]$Count = 0,
  [int]$Slot = 0,
  [string]$Instance = '',
  [switch]$Force,
  [switch]$AllowWarpTunnel,
  [string]$State = ($env:LOCALAPPDATA + '\opencode-infinite'),
  [int]$PortBase = 0,
  [int]$DedupeTries = 0,
  [int]$HealthSec = 0,
  [int]$LeaseMin = 0,
  [int]$BurnedTtlHours = 0,
  [string]$WgDir = '',
  [string]$TraceUrl = 'https://www.cloudflare.com/cdn-cgi/trace'
)
$ErrorActionPreference = 'Stop'

$WgcfVer = '2.3.1'
$WgcfSha = 'e222fd9443d7cb3264d825a3e86967797fc9c938507c5d93e3cc21e4aed11dcc'
$WgcfUrl = 'https://github.com/ViRb3/wgcf/releases/download/v2.3.1/wgcf_2.3.1_windows_amd64.exe'
$WpVer = '1.1.3'
$WpSha = 'bce041ea9fe0f8a3351301dcbe29cdf6a523bb25cf9c62f17ebb5699a8051d0f'
$WpExeSha = 'b176b561fd8bf15d828fcab484cfd5b4fb941cb9f61807901ca64b955af27e1f'
$WpUrl = 'https://github.com/windtf/wireproxy/releases/download/v1.1.3/wireproxy_windows_amd64.tar.gz'
$PeerEndpoint = '162.159.192.1:2408'
$ScriptVersion = '1.0'

$State = [IO.Path]::GetFullPath($State)
$poolDir = Join-Path $State 'pool'
$claimsDir = Join-Path $poolDir 'claims'
$egressDir = Join-Path (Join-Path $State 'instances') 'egress'
$binDir = Join-Path $State 'bin'
$statusFile = Join-Path $poolDir 'pool-status.json'
$poolConfigFile = Join-Path $poolDir 'pool-config.json'
$stopFlag = Join-Path $poolDir 'stop.flag'
$daemonLock = Join-Path $poolDir 'daemon.lock'
$eventsFile = Join-Path $State 'recovery-events.jsonl'

# config.json -> .settings.WPOOL_*; an explicit parameter always wins.
$cfg = $null
$cfgPath = Join-Path $State 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
  try { $cfg = (Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json) } catch { $cfg = $null }
}
$settings = $null
if ($cfg -and $cfg.PSObject.Properties['settings']) { $settings = $cfg.settings }
function CfgVal([string]$name, $default) {
  if ($settings -and $settings.PSObject.Properties[$name]) {
    $v = $settings.$name
    if ($null -ne $v -and [string]$v -ne '') { return $v }
  }
  return $default
}
if (-not $PSBoundParameters.ContainsKey('Count')) { $Count = [int](CfgVal 'WPOOL_COUNT' 4) }
if (-not $PSBoundParameters.ContainsKey('PortBase')) { $PortBase = [int](CfgVal 'WPOOL_PORT_BASE' 42000) }
if (-not $PSBoundParameters.ContainsKey('DedupeTries')) { $DedupeTries = [int](CfgVal 'WPOOL_DEDUPE_TRIES' 3) }
if (-not $PSBoundParameters.ContainsKey('HealthSec')) { $HealthSec = [int](CfgVal 'WPOOL_HEALTH_SEC' 30) }
if (-not $PSBoundParameters.ContainsKey('LeaseMin')) { $LeaseMin = [int](CfgVal 'WPOOL_LEASE_MIN' 15) }
if (-not $PSBoundParameters.ContainsKey('BurnedTtlHours')) { $BurnedTtlHours = [int](CfgVal 'WPOOL_BURNED_TTL_HOURS' 24) }
if (-not $PSBoundParameters.ContainsKey('WgDir')) { $WgDir = [string](CfgVal 'WPOOL_WG_DIR' '') }
$RotateMode = [string](CfgVal 'WPOOL_ROTATE_MODE' 'reconnect')
$VerifyProbe = [int](CfgVal 'WPOOL_VERIFY_PROBE' 0)
if (-not $TraceUrl) { $TraceUrl = 'https://www.cloudflare.com/cdn-cgi/trace' }

function Ensure-Dirs {
  foreach ($d in @($State, $poolDir, $claimsDir, $egressDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
}
function Write-Event([string]$type, $data) {
  try {
    if (-not (Test-Path -LiteralPath $State)) { return }
    $o = [ordered]@{ timestamp = (Get-Date).ToString('o'); type = $type; data = $data }
    $line = ConvertTo-Json -InputObject $o -Compress -Depth 6
    [IO.File]::AppendAllText($eventsFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
  } catch { }
}
function Read-Json([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $raw = [IO.File]::ReadAllText($path)
    if (-not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch { return $null }
}
function Write-Json([string]$path, $obj) {
  $parent = Split-Path -Parent $path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $json = ConvertTo-Json -InputObject $obj -Depth 10
  $tmp = $path + '.tmp'
  [IO.File]::WriteAllText($tmp, $json + "`r`n", (New-Object Text.UTF8Encoding($false)))
  try { Move-Item -LiteralPath $tmp -Destination $path -Force }
  catch { Copy-Item -LiteralPath $tmp -Destination $path -Force; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
# Effective pool config persisted by 'up'. An explicit parameter always wins; otherwise the
# persisted values win over config.json defaults so status/rotate/down/verify/daemon keep the base.
$persistedCfg = Read-Json $poolConfigFile
if ($persistedCfg) {
  if (-not $PSBoundParameters.ContainsKey('PortBase') -and $persistedCfg.PSObject.Properties['portBase']) {
    try {
      $v = [int]$persistedCfg.portBase
      if ($v -gt 0 -and ($v + [Math]::Max(1, [int]$Count)) -le 65535) { $PortBase = $v }
    } catch { }
  }
  if (-not $PSBoundParameters.ContainsKey('Count') -and $persistedCfg.PSObject.Properties['count']) {
    try {
      $v = [int]$persistedCfg.count
      if ($v -ge 1 -and ([int]$PortBase + $v) -le 65535) { $Count = $v }
    } catch { }
  }
}
function SlotName([int]$n) { return ('slot{0:D2}' -f $n) }
function SlotDir([int]$n) { return (Join-Path $egressDir (SlotName $n)) }
function SlotJsonPath([int]$n) { return (Join-Path (SlotDir $n) 'slot.json') }
function SlotPort([int]$n) { return ($PortBase + $n) }
function Test-SlotPortInRange([int]$port) {
  if ([int]$PortBase -le 0 -or [int]$Count -lt 1) { return $false }
  return ($port -gt [int]$PortBase -and $port -le ([int]$PortBase + [int]$Count))
}
function New-Slot([int]$n) {
  return [pscustomobject][ordered]@{
    slot = $n
    port = (SlotPort $n)
    pid = 0
    pidStart = [long]0
    identity = ''
    conf = ''
    ip = ''
    colo = ''
    warp = ''
    health = 'down'
    verifiedAt = ''
    burned = @()
    rotations = 0
    lastCheck = ''
    owner = $null
  }
}
function Get-Slot([int]$n) {
  $o = Read-Json (SlotJsonPath $n)
  if ($null -eq $o) { $o = New-Slot $n }
  $defaults = [ordered]@{
    slot = $n; port = (SlotPort $n); pid = 0; pidStart = [long]0; identity = ''; conf = '';
    ip = ''; colo = ''; warp = ''; health = 'down'; verifiedAt = ''; burned = @();
    rotations = 0; lastCheck = ''; owner = $null
  }
  foreach ($k in $defaults.Keys) {
    if ($null -eq $o.PSObject.Properties[$k]) {
      $o | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k]
    }
  }
  $o.slot = [int]$n
  $o.port = [int]$o.port
  $o.pid = [int]$o.pid
  $o.pidStart = [long]$o.pidStart
  $o.rotations = [int]$o.rotations
  if ($null -eq $o.burned) { $o.burned = @() }
  else { $o.burned = @($o.burned | Where-Object { $null -ne $_ }) }
  return $o
}
function Save-Slot($s) {
  $dir = SlotDir ([int]$s.slot)
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $s.lastCheck = (Get-Date).ToString('o')
  Write-Json (SlotJsonPath ([int]$s.slot)) $s
}
function Refresh-ClaimIp([int]$n) {
  $slotPath = SlotJsonPath $n
  if (-not (Test-Path -LiteralPath $slotPath)) { return }
  $s = Read-Json $slotPath
  if ($null -eq $s) { return }
  $ip = [string]$s.ip
  foreach ($cf in @(Get-ChildItem -LiteralPath $claimsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $c = Read-Json $cf.FullName
    if ($null -eq $c -or -not $c.PSObject.Properties['slot']) { continue }
    try { if ([int]$c.slot -ne $n) { continue } } catch { continue }
    try {
      $c.ip = $ip
      Write-Json $cf.FullName $c
    } catch {
      Write-Event 'claim-ip-refresh-error' @{ slot = $n; file = $cf.Name; error = $_.Exception.Message }
    }
  }
}
function Get-SlotNumbers {
  $nums = @()
  if (Test-Path -LiteralPath $egressDir) {
    foreach ($d in @(Get-ChildItem -LiteralPath $egressDir -Directory -ErrorAction SilentlyContinue)) {
      if ($d.Name -match '^slot(\d+)$') { $nums += [int]$matches[1] }
    }
  }
  return @($nums | Sort-Object -Unique)
}
function Get-AllSlots {
  $arr = @()
  foreach ($n in @(Get-SlotNumbers)) { $arr += Get-Slot $n }
  return $arr
}
function Get-ProcessByPidStart([int]$procId, [long]$ticks) {
  if ($procId -le 0 -or $ticks -le 0) { return $null }
  try {
    $p = Get-Process -Id $procId -ErrorAction Stop
    if ($p.StartTime.Ticks -eq $ticks) { return $p }
  } catch { }
  return $null
}
function Get-SlotProcesses($s) {
  $found = @()
  $seen = @{}
  $reg = Get-ProcessByPidStart ([int]$s.pid) ([long]$s.pidStart)
  if ($reg) { $found += $reg; $seen[[int]$reg.Id] = $true }
  # Also find a wireproxy whose command line points at this slot's run.conf. This catches a
  # process left behind when the recorded pid was cleared (e.g. a hung handshake), and never
  # matches a process from another state/pool because the path is absolute and slot-specific.
  $run = [string]$s.conf
  if (-not $run) { $run = Join-Path (SlotDir ([int]$s.slot)) 'run.conf' }
  if ($run) {
    $runLc = ([IO.Path]::GetFullPath($run)).ToLowerInvariant()
    try {
      $wps = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'wireproxy.exe'" -ErrorAction Stop)
      foreach ($wp in $wps) {
        $cl = [string]$wp.CommandLine
        if (-not $cl -or -not $cl.ToLowerInvariant().Contains($runLc)) { continue }
        $id = [int]$wp.ProcessId
        if ($seen.ContainsKey($id)) { continue }
        $p = $null
        try { $p = Get-Process -Id $id -ErrorAction Stop } catch { }
        if ($p) { $found += $p; $seen[$id] = $true }
      }
    } catch { }
  }
  return @($found)
}
function Test-SlotProcess($s) {
  return (@(Get-SlotProcesses $s).Count -gt 0)
}
function Test-Port([int]$port) {
  if ($port -le 0) { return $false }
  $c = $null
  try {
    $c = New-Object Net.Sockets.TcpClient
    $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(500)) { return $false }
    $c.EndConnect($ar)
    return $true
  } catch { return $false }
  finally { if ($c) { try { $c.Close() } catch { } } }
}
function Parse-Trace([string]$text) {
  $ip = ''; $warp = ''; $colo = ''
  foreach ($ln in ($text -split "`r?`n")) {
    if ($ln -like 'ip=*') { $ip = $ln.Substring(3).Trim() }
    elseif ($ln -like 'warp=*') { $warp = $ln.Substring(5).Trim() }
    elseif ($ln -like 'colo=*') { $colo = $ln.Substring(5).Trim() }
  }
  if (-not $ip) { return $null }
  return [ordered]@{ ip = $ip; warp = $warp; colo = $colo }
}
function Get-Trace([int]$port, [int]$timeoutSec = 8) {
  if ($port -le 0) { return $null }
  if ($timeoutSec -lt 2) { $timeoutSec = 2 }
  $proxy = 'http://127.0.0.1:' + $port
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    # Hard wall-clock bound: curl --max-time/--connect-timeout plus WaitForExit, so a stuck
    # CGNAT proxy cannot stall a status/daemon cycle. No second .NET attempt after a timeout.
    $out = Join-Path $poolDir ('trace-' + [guid]::NewGuid().ToString('N') + '.out')
    $err = $out + '.err'
    $p = $null
    try {
      # The CONNECT through wireproxy can take a few seconds on a cold tunnel, so the
      # connect timeout must not be shorter than the overall bounded budget.
      $connectSec = [string]$timeoutSec
      $argv = @('-s', '-S', '--connect-timeout', $connectSec, '--max-time', [string]$timeoutSec, '-x', $proxy, $TraceUrl)
      $oldNo = $env:NO_PROXY; $oldNo2 = $env:no_proxy; $oldEa = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        $env:NO_PROXY = ''; $env:no_proxy = ''
        $p = Start-Process -FilePath $curl.Source -ArgumentList $argv -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
      } finally {
        $ErrorActionPreference = $oldEa; $env:NO_PROXY = $oldNo; $env:no_proxy = $oldNo2
      }
      if ($p) {
        if (-not $p.WaitForExit(($timeoutSec * 1000) + 2000)) {
          try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        } elseif (Test-Path -LiteralPath $out) {
          # ExitCode is not reliable after WaitForExit(timeout) with redirected streams on
          # PS 5.1; the parsed trace itself is the validity check.
          $r = Parse-Trace ([IO.File]::ReadAllText($out))
          if ($r) { return $r }
        }
      }
    } catch { }
    finally {
      Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
    }
    return $null
  }
  $resp = $null; $sr = $null
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($TraceUrl)
    $req.Proxy = New-Object Net.WebProxy($proxy)
    $req.Timeout = $timeoutSec * 1000
    $req.ReadWriteTimeout = $timeoutSec * 1000
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    return (Parse-Trace $sr.ReadToEnd())
  } catch { return $null }
  finally {
    if ($sr) { try { $sr.Close() } catch { } }
    if ($resp) { try { $resp.Close() } catch { } }
  }
}
function Measure-Slot($s, [int]$timeoutSec = 8) {
  if (-not (Test-SlotProcess $s)) { return @{ ok = $false; reason = 'process dead'; trace = $null } }
  if (-not (Test-Port ([int]$s.port))) { return @{ ok = $false; reason = 'port closed'; trace = $null } }
  $t = Get-Trace ([int]$s.port) $timeoutSec
  if (-not $t) { return @{ ok = $false; reason = 'no trace'; trace = $null } }
  if ($t.ip -notlike '*:*') { return @{ ok = $false; reason = 'ipv4 egress'; trace = $t } }
  if ($t.warp -ne 'on') { return @{ ok = $false; reason = 'warp off'; trace = $t } }
  return @{ ok = $true; reason = ''; trace = $t }
}
function Update-Uniqueness($slots) {
  $seen = @{}
  foreach ($s in @($slots | Sort-Object slot)) {
    if ($s.health -eq 'up' -and $s.ip) {
      if ($seen.ContainsKey([string]$s.ip)) { $s.health = 'degraded'; Save-Slot $s }
      else { $seen[[string]$s.ip] = [int]$s.slot }
    }
  }
}
function Write-PoolStatus($slots) {
  $arr = @()
  foreach ($s in @($slots | Sort-Object slot)) {
    $arr += [ordered]@{
      slot = [int]$s.slot; port = [int]$s.port; ip = [string]$s.ip; colo = [string]$s.colo;
      warp = [string]$s.warp; health = [string]$s.health; owner = $s.owner; pid = [int]$s.pid;
      verifiedAt = [string]$s.verifiedAt
    }
  }
  $upSlots = @($arr | Where-Object { $_.health -eq 'up' -and $_.ip })
  $up = $upSlots.Count
  $distinct = @($upSlots | ForEach-Object { $_.ip } | Sort-Object -Unique).Count
  $o = [ordered]@{
    generatedAt = (Get-Date).ToString('o'); state = $State; portBase = $PortBase;
    count = $arr.Count; up = $up; distinct = $distinct; slots = $arr
  }
  Write-Json $statusFile $o
}
function Show-Table($slots) {
  $rows = @()
  foreach ($s in @($slots | Sort-Object slot)) {
    $ip = '-'; if ($s.ip) { $ip = [string]$s.ip }
    $colo = '-'; if ($s.colo) { $colo = [string]$s.colo }
    $owner = '-'
    if ($s.owner -and $s.owner.instance) { $owner = [string]$s.owner.instance }
    $rows += [pscustomobject]@{ Slot = [int]$s.slot; Port = [int]$s.port; IP = $ip; Colo = $colo; Health = [string]$s.health; Owner = $owner }
  }
  if ($rows.Count -eq 0) { Write-Host 'no slots'; return }
  Write-Host ''
  $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}
function Lock-Slot([int]$n, [int]$timeoutMs) {
  $path = Join-Path $poolDir ((SlotName $n) + '.lock')
  $end = (Get-Date).AddMilliseconds([Math]::Max(0, $timeoutMs))
  while ($true) {
    try {
      return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
      if ((Get-Date) -ge $end) { return $null }
      Start-Sleep -Milliseconds 100
    } catch { return $null }
  }
}

function Invoke-NativeQuiet {
  param([string]$Exe, [string[]]$Argv)
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Exe @Argv 2>&1 | Out-Null
    return $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
}
function Download-File([string]$url, [string]$dest) {
  $tmp = $dest + '.part'
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & $curl.Source -L --fail --silent --show-error --max-time 300 -o $tmp $url 2>&1 | Out-Null
      $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($rc -ne 0) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      throw ('download failed: ' + $url)
    }
  } else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp -TimeoutSec 300
  }
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}
function Ensure-Bins {
  if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Force -Path $binDir | Out-Null }
  $wgcf = Join-Path $binDir 'wgcf.exe'
  $wgcfOk = $false
  if (Test-Path -LiteralPath $wgcf) {
    try { $wgcfOk = ((Get-FileHash -LiteralPath $wgcf -Algorithm SHA256).Hash.ToLower() -eq $WgcfSha) } catch { $wgcfOk = $false }
  }
  if (-not $wgcfOk) {
    Remove-Item -LiteralPath $wgcf -Force -ErrorAction SilentlyContinue
    $tmp = Join-Path $binDir 'wgcf.exe.download'
    Download-File $WgcfUrl $tmp
    $h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $WgcfSha) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      throw ('wgcf sha256 mismatch: ' + $h)
    }
    Move-Item -LiteralPath $tmp -Destination $wgcf -Force
    Write-Event 'bin' @{ name = 'wgcf'; version = $WgcfVer; sha256 = $h }
  }
  $wp = Join-Path $binDir 'wireproxy.exe'
  $wpOk = $false
  if (Test-Path -LiteralPath $wp) {
    try { $wpOk = ((Get-FileHash -LiteralPath $wp -Algorithm SHA256).Hash.ToLower() -eq $WpExeSha) } catch { $wpOk = $false }
  }
  if (-not $wpOk) {
    Remove-Item -LiteralPath $wp -Force -ErrorAction SilentlyContinue
    $tgz = Join-Path $binDir 'wireproxy.tar.gz'
    Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
    Download-File $WpUrl $tgz
    $h = (Get-FileHash -LiteralPath $tgz -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $WpSha) {
      Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
      throw ('wireproxy archive sha256 mismatch: ' + $h)
    }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & $tar -xzf $tgz -C $binDir wireproxy.exe 2>&1 | Out-Null
      $trc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($trc -ne 0) {
      Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
      throw 'tar could not unpack wireproxy'
    }
    Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
    $h2 = (Get-FileHash -LiteralPath $wp -Algorithm SHA256).Hash.ToLower()
    if ($h2 -ne $WpExeSha) {
      Remove-Item -LiteralPath $wp -Force -ErrorAction SilentlyContinue
      throw ('wireproxy exe sha256 mismatch: ' + $h2)
    }
    Write-Event 'bin' @{ name = 'wireproxy'; version = $WpVer; sha256 = $h2 }
  }
  return @{ wgcf = $wgcf; wireproxy = $wp }
}
function Find-WarpCli {
  $cands = @(
    (Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Cloudflare\Cloudflare WARP\warp-cli.exe'),
    (Join-Path $env:LOCALAPPDATA 'Cloudflare\Cloudflare WARP\warp-cli.exe')
  )
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  $cmd = Get-Command warp-cli.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return ''
}
function Test-WarpConnected {
  $wc = Find-WarpCli
  if (-not $wc) { return $false }
  $out = Join-Path $env:TEMP ('wpool-warp-' + [guid]::NewGuid().ToString('N') + '.out')
  $err = $out + '.err'
  try {
    $p = Start-Process -FilePath $wc -ArgumentList @('--accept-tos', 'status') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit(8000)) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
      return $false
    }
    $txt = ''
    if (Test-Path -LiteralPath $out) { $txt = [IO.File]::ReadAllText($out) }
    $txt = $txt -replace '\x1b\[[0-9;]*m', ''
    return ($txt -match '(?im)^\s*(Status\s*:\s*)?Connected\s*$')
  } catch { return $false }
  finally {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
  }
}
function Convert-ProfileText([string]$text, [int]$port) {
  $lines = @($text -split "`r?`n")
  $out = New-Object System.Collections.Generic.List[string]
  $section = ''
  $seenDns = $false; $seenEndpoint = $false; $seenAllowed = $false; $hasV6 = $false
  foreach ($ln in $lines) {
    $t = $ln.Trim()
    if ($t -match '^\[(.+)\]$') {
      if ($section -eq 'interface' -and -not $seenDns) { $out.Add('DNS = 1.1.1.1'); $seenDns = $true }
      if ($section -eq 'peer') {
        if (-not $seenEndpoint) { $out.Add('Endpoint = ' + $PeerEndpoint); $seenEndpoint = $true }
        if (-not $seenAllowed) { $out.Add('AllowedIPs = 0.0.0.0/0, ::/0'); $seenAllowed = $true }
      }
      $section = $matches[1].Trim().ToLower()
      if ($section -eq 'http') { continue }
      $out.Add('[' + $matches[1].Trim() + ']')
      continue
    }
    if ($section -eq 'http') { continue }
    if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { $out.Add($ln.TrimEnd()); continue }
    $eq = $t.IndexOf('=')
    if ($eq -lt 1) { $out.Add($t); continue }
    $k = $t.Substring(0, $eq).Trim()
    $v = $t.Substring($eq + 1).Trim()
    $kl = $k.ToLower()
    if ($kl -eq 'dns') { if (-not $seenDns) { $out.Add('DNS = 1.1.1.1'); $seenDns = $true }; continue }
    if ($kl -eq 'endpoint') { if (-not $seenEndpoint) { $out.Add('Endpoint = ' + $PeerEndpoint); $seenEndpoint = $true }; continue }
    if ($kl -eq 'allowedips') { if (-not $seenAllowed) { $out.Add('AllowedIPs = 0.0.0.0/0, ::/0'); $seenAllowed = $true }; continue }
    if ($kl -eq 'address') {
      if ($v -match ':') { $hasV6 = $true }
      $out.Add('Address = ' + $v)
      continue
    }
    $out.Add($k + ' = ' + $v)
  }
  if ($section -eq 'interface' -and -not $seenDns) { $out.Add('DNS = 1.1.1.1') }
  if ($section -eq 'peer') {
    if (-not $seenEndpoint) { $out.Add('Endpoint = ' + $PeerEndpoint) }
    if (-not $seenAllowed) { $out.Add('AllowedIPs = 0.0.0.0/0, ::/0') }
  }
  if (-not $hasV6) { throw 'profile has no IPv6 Address' }
  $joined = $out -join "`r`n"
  if ($joined -notmatch '(?im)^\s*PrivateKey\s*=\s*\S+') { throw 'profile has no PrivateKey' }
  if ($joined -notmatch '(?im)^\s*PublicKey\s*=\s*\S+') { throw 'profile has no PublicKey' }
  $out.Add('')
  $out.Add('[http]')
  $out.Add('BindAddress = 127.0.0.1:' + $port)
  return (($out -join "`r`n") + "`r`n")
}
function Write-RunConf([int]$n) {
  $dir = SlotDir $n
  $prof = Join-Path $dir 'profile.conf'
  if (-not (Test-Path -LiteralPath $prof)) { throw ('profile.conf missing for slot ' + $n) }
  $txt = [IO.File]::ReadAllText($prof)
  $s = Get-Slot $n
  $port = [int]$s.port
  if (-not (Test-SlotPortInRange $port)) { $port = SlotPort $n }
  $norm = Convert-ProfileText $txt $port
  $run = Join-Path $dir 'run.conf'
  [IO.File]::WriteAllText($run, $norm, (New-Object Text.UTF8Encoding($false)))
  return $run
}
function Use-Manual([int]$n) {
  if (-not $WgDir) { return $false }
  $src = Join-Path $WgDir ((SlotName $n) + '.conf')
  if (-not (Test-Path -LiteralPath $src)) { return $false }
  $dir = SlotDir $n
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Copy-Item -LiteralPath $src -Destination (Join-Path $dir 'profile.conf') -Force
  return $true
}
function New-WgcfIdentity([int]$n) {
  $bins = Ensure-Bins
  $dir = SlotDir $n
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $acct = Join-Path $dir 'account.toml'
  $prof = Join-Path $dir 'profile.conf'
  Remove-Item -LiteralPath $acct -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $prof -Force -ErrorAction SilentlyContinue
  $name = 'warp-pool-' + (SlotName $n)
  $ok = $false
  for ($i = 1; $i -le 2; $i++) {
    $rc = Invoke-NativeQuiet -Exe $bins.wgcf -Argv @('register', '--accept-tos', '--config', $acct, '--name', $name, '--model', 'PC')
    if ($rc -eq 0 -and (Test-Path -LiteralPath $acct)) { $ok = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $ok) { throw ('wgcf register failed for slot ' + $n) }
  $rc = Invoke-NativeQuiet -Exe $bins.wgcf -Argv @('generate', '--config', $acct, '--profile', $prof)
  if ($rc -ne 0 -or -not (Test-Path -LiteralPath $prof)) { throw ('wgcf generate failed for slot ' + $n) }
  if ((Get-Item -LiteralPath $prof).Length -lt 100) { throw ('wgcf profile is empty for slot ' + $n) }
  Write-Event 'identity' @{ slot = $n; kind = 'wgcf'; name = $name }
  return 'wgcf'
}
function Ensure-Identity([int]$n, [switch]$NewIdentity) {
  if (Use-Manual $n) { return 'manual' }
  $dir = SlotDir $n
  $prof = Join-Path $dir 'profile.conf'
  $acct = Join-Path $dir 'account.toml'
  if (-not $NewIdentity -and (Test-Path -LiteralPath $prof) -and (Get-Item -LiteralPath $prof).Length -gt 0) {
    if (Test-Path -LiteralPath $acct) { return 'wgcf' }
    return 'manual'
  }
  return (New-WgcfIdentity $n)
}
function Start-SlotProcess([int]$n) {
  $bins = Ensure-Bins
  $dir = SlotDir $n
  $run = Join-Path $dir 'run.conf'
  if (-not (Test-Path -LiteralPath $run)) { throw ('run.conf missing for slot ' + $n) }
  $out = Join-Path $dir 'out.log'
  $err = Join-Path $dir 'err.log'
  Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $bins.wireproxy -ArgumentList @('-s', '-c', ('"' + $run + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  if (-not $p) { throw ('wireproxy did not start for slot ' + $n) }
  $ticks = [long]0
  try { $ticks = $p.StartTime.Ticks } catch { try { $ticks = (Get-Process -Id $p.Id).StartTime.Ticks } catch { } }
  $s = Get-Slot $n
  if (-not (Test-SlotPortInRange ([int]$s.port))) { $s.port = SlotPort $n }
  $s.pid = [int]$p.Id
  $s.pidStart = [long]$ticks
  $s.conf = $run
  Save-Slot $s
  return $s
}
function Stop-SlotProcess([int]$n) {
  $s = Get-Slot $n
  # Only processes registered by this slot (pid + start ticks) or whose command line
  # references this slot's run.conf may be stopped. A hung handshake is covered too.
  $procs = @(Get-SlotProcesses $s)
  foreach ($p in $procs) {
    try { Stop-Process -Id ([int]$p.Id) -Force -ErrorAction Stop }
    catch { Write-Event 'stop-error' @{ slot = $n; pid = [int]$p.Id; error = $_.Exception.Message } }
  }
  $alive = @()
  foreach ($p in $procs) {
    $exited = $false
    $end = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $end) {
      try { if ($p.HasExited) { $exited = $true; break } } catch { $exited = $true; break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $exited) { $alive += [int]$p.Id }
  }
  $s = Get-Slot $n
  if ($alive.Count -eq 0) {
    # Clear pid/pidStart only after every targeted process is confirmed gone. A failed
    # Stop-Process must not leave a live wireproxy orphaned from its slot record.
    $s.pid = 0
    $s.pidStart = [long]0
    $s.health = 'down'
  } else {
    # Keep the recorded identity so a later sweep can retry the stop.
    Write-Event 'stop-error' @{ slot = $n; pids = ($alive -join ','); error = 'processes still alive after stop' }
  }
  Save-Slot $s
  $end = (Get-Date).AddSeconds(2)
  while ((Get-Date) -lt $end -and (Test-Port ([int]$s.port))) { Start-Sleep -Milliseconds 100 }
  return $s
}
function Wait-SlotHealthy([int]$n, [int]$seconds, [string]$prevIp = '') {
  $end = (Get-Date).AddSeconds($seconds)
  $last = $null
  while ((Get-Date) -lt $end) {
    $s = Get-Slot $n
    if (-not (Test-SlotProcess $s)) { return @{ ok = $false; reason = 'process dead'; trace = $null } }
    $m = Measure-Slot $s 8
    if ($m.ok) {
      if (-not $prevIp -or $m.trace.ip -ne $prevIp) { return $m }
      $last = $m
    }
    Start-Sleep -Milliseconds 1000
  }
  if ($last) { return @{ ok = $false; reason = 'same ip'; trace = $last.trace } }
  return @{ ok = $false; reason = 'no trace'; trace = $null }
}
function Start-Slot([int]$n, [switch]$NewIdentity, [string]$PrevIp = '', [int]$WaitSec = 25) {
  $s = Get-Slot $n
  if (-not (Test-SlotPortInRange ([int]$s.port))) { $s.port = SlotPort $n }
  $identity = Ensure-Identity $n -NewIdentity:$NewIdentity
  $run = Write-RunConf $n
  $s.identity = $identity
  $s.conf = $run
  Save-Slot $s
  $s = Start-SlotProcess $n
  $m = Wait-SlotHealthy $n $WaitSec $PrevIp
  if (-not $m.ok) {
    Stop-SlotProcess $n | Out-Null
    return @{ ok = $false; reason = $m.reason; slot = $n; ip = '' }
  }
  $s = Get-Slot $n
  $s.ip = [string]$m.trace.ip
  $s.colo = [string]$m.trace.colo
  $s.warp = [string]$m.trace.warp
  $s.health = 'up'
  $s.verifiedAt = (Get-Date).ToString('o')
  Save-Slot $s
  Write-Event 'slot-up' @{ slot = $n; port = [int]$s.port; ip = $s.ip; colo = $s.colo; identity = $identity }
  return @{ ok = $true; reason = ''; slot = $n; ip = $s.ip; port = [int]$s.port; trace = $m.trace }
}
function Add-Burned($s, [string]$ip) {
  if (-not $ip) { return }
  $hours = $BurnedTtlHours
  if ($hours -le 0) { $hours = 24 }
  $until = (Get-Date).AddHours($hours).ToString('o')
  $arr = @()
  foreach ($b in @($s.burned)) {
    if (-not $b -or -not $b.ip) { continue }
    $expired = $false
    if ($b.until) { try { if ([DateTime]::Parse([string]$b.until) -lt (Get-Date)) { $expired = $true } } catch { } }
    if (-not $expired) { $arr += $b }
  }
  if (@($arr | Where-Object { $_.ip -eq $ip }).Count -eq 0) {
    $arr += [ordered]@{ ip = $ip; at = (Get-Date).ToString('o'); until = $until }
  }
  $s.burned = $arr
}
function Rotate-Slot([int]$n, [switch]$ForceIdentity, [int]$MaxIdentity = 2, [int]$WaitSec = 20) {
  $s = Get-Slot $n
  $oldIp = [string]$s.ip
  if ($oldIp) { Add-Burned $s $oldIp; Save-Slot $s }
  $manual = Use-Manual $n
  $success = $false
  $lastIp = $oldIp
  if (-not $ForceIdentity) {
    for ($i = 1; $i -le 2; $i++) {
      if (Test-SlotProcess $s) { Stop-SlotProcess $n | Out-Null }
      $r = Start-Slot $n -PrevIp $oldIp -WaitSec $WaitSec
      if ($r.ok) { $lastIp = [string]$r.ip }
      if ($r.ok -and $r.ip -ne $oldIp) { $success = $true; break }
    }
  }
  if (-not $success -and -not $manual) {
    for ($i = 1; $i -le $MaxIdentity; $i++) {
      $r = Start-Slot $n -NewIdentity -PrevIp $oldIp -WaitSec 25
      if ($r.ok) { $lastIp = [string]$r.ip }
      if ($r.ok -and $r.ip -ne $oldIp) { $success = $true; break }
    }
  }
  if (-not $success) {
    $r = Start-Slot $n -WaitSec 25
    if ($r.ok) { $lastIp = [string]$r.ip }
  }
  $s = Get-Slot $n
  $s.rotations = [int]$s.rotations + 1
  if ($success) {
    $s.health = 'up'
    Write-Event 'rotate' @{ slot = $n; before = $oldIp; after = $lastIp }
  } else {
    if ($s.pid -gt 0) { $s.health = 'degraded' }
    Write-Event 'rotate-failed' @{ slot = $n; before = $oldIp; after = $lastIp }
  }
  Save-Slot $s
  Refresh-ClaimIp $n
  return @{ ok = $success; slot = $n; before = $oldIp; after = $lastIp }
}
function Invoke-Dedupe($slots, [int]$tries) {
  if ($tries -lt 1) { $tries = 1 }
  $byIp = @{}
  foreach ($s in @($slots | Sort-Object slot)) {
    if ($s.health -ne 'up' -or -not $s.ip) { continue }
    $key = [string]$s.ip
    if (-not $byIp.ContainsKey($key)) { $byIp[$key] = @() }
    $byIp[$key] += [int]$s.slot
  }
  foreach ($ip in @($byIp.Keys)) {
    $nums = @($byIp[$ip] | Sort-Object)
    if ($nums.Count -le 1) { continue }
    foreach ($n in @($nums | Select-Object -Skip 1)) {
      $ok = $false
      for ($t = 1; $t -le $tries; $t++) {
        $r = Rotate-Slot $n -ForceIdentity -MaxIdentity 1 -WaitSec 25
        if ($r.ok) {
          $cur = Get-Slot $n
          $dup = $false
          foreach ($o in @(Get-AllSlots)) {
            if ([int]$o.slot -ne $n -and $o.health -eq 'up' -and $o.ip -eq $cur.ip) { $dup = $true }
          }
          if (-not $dup) { $ok = $true; break }
        }
      }
      if (-not $ok) {
        $cur = Get-Slot $n
        $cur.health = 'degraded'
        Save-Slot $cur
        Write-Event 'dedupe-failed' @{ slot = $n; ip = $cur.ip; tries = $tries }
      }
    }
  }
}

function Invoke-Up {
  Ensure-Dirs
  if ($Count -lt 1) { Write-Host 'up requires Count >= 1'; return 1 }
  if ($PortBase -le 0 -or (($PortBase + $Count) -gt 65535)) { Write-Host 'bad PortBase/Count'; return 1 }
  # Persist the effective base/count so every later action without explicit parameters reuses it.
  Write-Json $poolConfigFile ([ordered]@{ portBase = [int]$PortBase; count = [int]$Count; writtenAt = (Get-Date).ToString('o') })
  if (Test-Path -LiteralPath $stopFlag) { Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue }
  if (-not $AllowWarpTunnel -and (Test-WarpConnected)) {
    Write-Host 'warp-cli reports Connected; pass -AllowWarpTunnel to stack WARP-over-WARP'
    return 6
  }
  Ensure-Bins | Out-Null
  for ($n = 1; $n -le $Count; $n++) {
    $s = Get-Slot $n
    $expected = SlotPort $n
    if ($s.pid -gt 0 -and [int]$s.port -eq $expected) {
      $m = Measure-Slot $s 8
      if ($m.ok) {
        $s.ip = [string]$m.trace.ip
        $s.colo = [string]$m.trace.colo
        $s.warp = [string]$m.trace.warp
        $s.health = 'up'
        $s.verifiedAt = (Get-Date).ToString('o')
        Save-Slot $s
        Write-Host ('slot ' + $n + ' already up on port ' + $expected + ' ip ' + $s.ip)
        continue
      }
    }
    Stop-SlotProcess $n | Out-Null
    $ok = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
      try {
        $r = Start-Slot $n -NewIdentity:($attempt -gt 1) -WaitSec 25
        if ($r.ok) { $ok = $true; break }
        Write-Event 'slot-attempt' @{ slot = $n; attempt = $attempt; ok = $false; reason = $r.reason }
        Write-Host ('slot ' + $n + ' attempt ' + $attempt + ' failed: ' + $r.reason)
      } catch {
        Write-Host ('slot ' + $n + ' attempt ' + $attempt + ' error: ' + $_.Exception.Message)
        Write-Event 'slot-error' @{ slot = $n; attempt = $attempt; error = $_.Exception.Message }
      }
      Stop-SlotProcess $n | Out-Null
    }
    if (-not $ok) {
      $s = Get-Slot $n
      $s.health = 'down'
      $s.ip = ''
      $s.warp = ''
      Save-Slot $s
      Write-Host ('slot ' + $n + ' is down')
    }
  }
  Invoke-Dedupe @(Get-AllSlots) ([Math]::Max(1, $DedupeTries))
  $slots = @(Get-AllSlots)
  Update-Uniqueness $slots
  $slots = @(Get-AllSlots)
  Write-PoolStatus $slots
  Show-Table $slots
  $up = @($slots | Where-Object { $_.health -eq 'up' -and $_.ip }).Count
  $distinct = @($slots | Where-Object { $_.health -eq 'up' -and $_.ip } | ForEach-Object { $_.ip } | Sort-Object -Unique).Count
  if ($up -eq 0) { return 3 }
  if ($up -gt 1 -and $distinct -lt $up) { return 2 }
  return 0
}
function Invoke-Status {
  Ensure-Dirs
  foreach ($n in @(Get-SlotNumbers)) {
    $s = Get-Slot $n
    $m = Measure-Slot $s 8
    if ($m.ok) {
      $s.ip = [string]$m.trace.ip
      $s.colo = [string]$m.trace.colo
      $s.warp = [string]$m.trace.warp
      $s.health = 'up'
      $s.verifiedAt = (Get-Date).ToString('o')
    } else {
      if (-not (Test-SlotProcess $s) -or -not (Test-Port ([int]$s.port))) { $s.health = 'down' }
      else { $s.health = 'degraded' }
    }
    Save-Slot $s
  }
  $slots = @(Get-AllSlots)
  Update-Uniqueness $slots
  $slots = @(Get-AllSlots)
  Write-PoolStatus $slots
  Show-Table $slots
  return 0
}
function Invoke-Claim {
  if (-not $Instance) { Write-Host 'claim requires -Instance'; return 1 }
  if ($Instance -notmatch '^[A-Za-z0-9._-]{1,64}$') { Write-Host 'bad Instance name'; return 1 }
  Ensure-Dirs
  $nums = @(Get-SlotNumbers)
  if ($nums.Count -eq 0) { Write-Host 'no slots'; return 7 }
  $claimPath = Join-Path $claimsDir ($Instance + '.json')
  $existing = Read-Json $claimPath
  $order = @()
  if ($existing -and $existing.slot) { $order += [int]$existing.slot }
  foreach ($n in $nums) { if ($order -notcontains $n) { $order += $n } }
  $end = (Get-Date).AddSeconds(10)
  foreach ($n in $order) {
    $remaining = [int][Math]::Max(0, ($end - (Get-Date)).TotalMilliseconds)
    if ($remaining -le 0) { break }
    $lock = Lock-Slot $n $remaining
    if (-not $lock) { continue }
    try {
      $s = Get-Slot $n
      if ($s.health -ne 'up' -or -not $s.ip) { continue }
      if (-not (Test-SlotProcess $s) -or -not (Test-Port ([int]$s.port))) {
        $s.health = 'down'
        Save-Slot $s
        continue
      }
      $ownerInstance = ''
      if ($s.owner -and $s.owner.instance) { $ownerInstance = [string]$s.owner.instance }
      if ($ownerInstance -and $ownerInstance -ne $Instance) { continue }
      $now = (Get-Date).ToString('o')
      $at = $now
      if ($existing -and [int]$existing.slot -eq $n -and $existing.at) { $at = [string]$existing.at }
      $ticks = [long]0
      try { $ticks = (Get-Process -Id $PID).StartTime.Ticks } catch { }
      $s.owner = [ordered]@{ instance = $Instance; pid = $PID; ticks = $ticks; at = $at }
      Save-Slot $s
      $claim = [ordered]@{
        instance = $Instance; slot = $n; port = [int]$s.port;
        proxy = ('http://127.0.0.1:' + $s.port); ip = [string]$s.ip; at = $at
      }
      Write-Json $claimPath $claim
      Write-Event 'claim' @{ instance = $Instance; slot = $n; port = [int]$s.port }
      Write-Host ('claimed slot ' + $n + ' port ' + $s.port + ' for ' + $Instance)
      return 0
    } finally { $lock.Dispose() }
  }
  Write-Host ('no free slot for ' + $Instance)
  return 7
}
function Invoke-Release {
  if (-not $Instance) { Write-Host 'release requires -Instance'; return 1 }
  if ($Instance -notmatch '^[A-Za-z0-9._-]{1,64}$') { Write-Host 'bad Instance name'; return 1 }
  Ensure-Dirs
  $claimPath = Join-Path $claimsDir ($Instance + '.json')
  $nums = @()
  $existing = Read-Json $claimPath
  if ($existing -and $existing.slot) { $nums += [int]$existing.slot }
  foreach ($n in @(Get-SlotNumbers)) {
    if ($nums -contains $n) { continue }
    $s = Get-Slot $n
    if ($s.owner -and $s.owner.instance -eq $Instance) { $nums += $n }
  }
  foreach ($n in @($nums | Sort-Object -Unique)) {
    $lock = Lock-Slot $n 5000
    if (-not $lock) { continue }
    try {
      $s = Get-Slot $n
      if ($s.owner -and $s.owner.instance -eq $Instance) {
        $s.owner = $null
        Save-Slot $s
        Write-Event 'release' @{ instance = $Instance; slot = $n }
      }
    } finally { $lock.Dispose() }
  }
  Remove-Item -LiteralPath $claimPath -Force -ErrorAction SilentlyContinue
  Write-Host ('released ' + $Instance)
  return 0
}
function Invoke-Rotate {
  Ensure-Dirs
  if ($Slot -le 0) { Write-Host 'rotate requires -Slot'; return 1 }
  if (-not (Test-Path -LiteralPath (SlotJsonPath $Slot))) { Write-Host ('slot ' + $Slot + ' not found'); return 3 }
  # Same slot lock as claim/release: concurrent rotators (launcher + dispatcher) would
  # otherwise spawn two wireproxies on one port. Never hold it past this call.
  $lock = Lock-Slot $Slot 10000
  if (-not $lock) { Write-Host ('slot ' + $Slot + ' is locked; rotate aborted'); return 4 }
  try {
    $s = Get-Slot $Slot
    if (-not (Test-SlotProcess $s)) {
      $r0 = Start-Slot $Slot -WaitSec 25
      if (-not $r0.ok) { Write-Host ('slot ' + $Slot + ' could not start: ' + $r0.reason); return 3 }
      $s = Get-Slot $Slot
    }
    $before = [string]$s.ip
    $forceId = $Force -or ($RotateMode -eq 'identity')
    $r = Rotate-Slot $Slot -ForceIdentity:$forceId -MaxIdentity 2 -WaitSec 20
    $after = [string](Get-Slot $Slot).ip
    Write-Host ('slot ' + $Slot + ' ip before=' + $before + ' after=' + $after)
    $slots = @(Get-AllSlots)
    Update-Uniqueness $slots
    $slots = @(Get-AllSlots)
    Write-PoolStatus $slots
    Show-Table $slots
    if ($r.ok -and $after -ne $before -and $after -like '*:*') { return 0 }
    return 2
  } finally { $lock.Dispose() }
}
function Invoke-Verify {
  Ensure-Dirs
  $nums = @(Get-SlotNumbers)
  if ($Slot -gt 0) { $nums = @($Slot) }
  if ($nums.Count -eq 0) { Write-Host 'no slots'; return 3 }
  $dead = $false; $bad = $false
  foreach ($n in $nums) {
    $s = Get-Slot $n
    $m = Measure-Slot $s 8
    if (-not $m.ok) {
      if (-not (Test-SlotProcess $s) -or -not (Test-Port ([int]$s.port))) { $s.health = 'down'; $dead = $true }
      else { $s.health = 'degraded'; $bad = $true }
      Save-Slot $s
      Write-Host ('slot ' + $n + ': ' + $m.reason)
      continue
    }
    $s.ip = [string]$m.trace.ip
    $s.colo = [string]$m.trace.colo
    $s.warp = [string]$m.trace.warp
    $s.health = 'up'
    $s.verifiedAt = (Get-Date).ToString('o')
    Save-Slot $s
    if ($VerifyProbe -gt 0) {
      Start-Sleep -Seconds 1
      $m2 = Measure-Slot $s 8
      if ($m2.ok -and $m2.trace.ip -ne $s.ip) {
        $s.health = 'degraded'
        Save-Slot $s
        $bad = $true
        Write-Host ('slot ' + $n + ': ip moved during probe (' + $s.ip + ' -> ' + $m2.trace.ip + ')')
        continue
      }
    }
    Write-Host ('slot ' + $n + ': ip=' + $s.ip + ' warp=' + $s.warp + ' colo=' + $s.colo)
  }
  $slots = @(Get-AllSlots)
  $seen = @{}
  foreach ($s in @($slots | Sort-Object slot)) {
    if ($s.health -eq 'up' -and $s.ip) {
      if ($seen.ContainsKey([string]$s.ip)) {
        $s.health = 'degraded'
        Save-Slot $s
        $bad = $true
        Write-Host ('slot ' + $s.slot + ': duplicate ip ' + $s.ip)
      } else { $seen[[string]$s.ip] = [int]$s.slot }
    }
  }
  $slots = @(Get-AllSlots)
  Write-PoolStatus $slots
  Show-Table $slots
  if ($dead) { return 3 }
  if ($bad) { return 2 }
  return 0
}
function Invoke-Down {
  Ensure-Dirs
  $nums = @(Get-SlotNumbers)
  if ($Slot -gt 0) { $nums = @($Slot) }
  # A full down must signal the daemon to exit, otherwise it resurrects the slots within
  # WPOOL_HEALTH_SEC. A partial (-Slot) down must NOT write the flag: other slots stay up.
  if ($Slot -le 0) {
    try { [IO.File]::WriteAllText($stopFlag, (Get-Date).ToString('o') + "`r`n", (New-Object Text.UTF8Encoding($false))) }
    catch { Write-Event 'stop-flag-error' @{ error = $_.Exception.Message } }
  }
  foreach ($n in $nums) {
    Stop-SlotProcess $n | Out-Null
    Write-Host ('slot ' + $n + ' stopped')
  }
  $slots = @(Get-AllSlots)
  Write-PoolStatus $slots
  Show-Table $slots
  $open = @()
  foreach ($n in $nums) {
    $p = SlotPort $n
    if (Test-Port $p) { $open += $p }
  }
  if ($open.Count -gt 0) {
    Write-Host ('ports still open: ' + ($open -join ', '))
    return 3
  }
  return 0
}
function Invoke-Daemon {
  Ensure-Dirs
  if (Test-Path -LiteralPath $stopFlag) {
    if ($Force) { Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue }
    else { Write-Host 'stop.flag exists; pass -Force to clear it'; return 0 }
  }
  $lock = $null
  try { $lock = [IO.File]::Open($daemonLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { Write-Host 'daemon already running'; return 4 }
  try {
    $ticks = [long]0
    try { $ticks = (Get-Process -Id $PID).StartTime.Ticks } catch { }
    $lock.SetLength(0)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([string]$PID + '|' + [string]$ticks))
    $lock.Write($bytes, 0, $bytes.Length)
    $lock.Flush()
    Write-Event 'daemon-start' @{ pid = $PID; healthSec = $HealthSec }
    $interval = [Math]::Max(5, $HealthSec)
    while (-not (Test-Path -LiteralPath $stopFlag)) {
      # Reap expired leases at the start of every cycle. Lease expiry is the only
      # criterion: owner.pid belongs to the ephemeral claim process, already gone.
      Invoke-Reap | Out-Null
      foreach ($n in @(Get-SlotNumbers)) {
        if (Test-Path -LiteralPath $stopFlag) { break }
        $s = Get-Slot $n
        $m = Measure-Slot $s 8
        if ($m.ok) {
          $s.ip = [string]$m.trace.ip
          $s.colo = [string]$m.trace.colo
          $s.warp = [string]$m.trace.warp
          $s.health = 'up'
          $s.verifiedAt = (Get-Date).ToString('o')
          Save-Slot $s
          continue
        }
        $alive = Test-SlotProcess $s
        $age = 0
        if ($alive) {
          try { $age = ((Get-Date) - (Get-Process -Id $s.pid).StartTime).TotalSeconds } catch { $age = 0 }
        }
        $restart = (-not $alive) -or ($age -gt 60) -or ($m.reason -eq 'warp off') -or ($m.reason -eq 'port closed')
        if ($restart) {
          Write-Event 'daemon-restart' @{ slot = $n; reason = $m.reason }
          try { Start-Slot $n -WaitSec 60 | Out-Null } catch { Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message } }
        } else {
          $s.health = 'degraded'
          Save-Slot $s
        }
      }
      $slots = @(Get-AllSlots)
      Update-Uniqueness $slots
      $slots = @(Get-AllSlots)
      Write-PoolStatus $slots
      $end = (Get-Date).AddSeconds($interval)
      while ((Get-Date) -lt $end -and -not (Test-Path -LiteralPath $stopFlag)) { Start-Sleep -Seconds 1 }
    }
    Write-Event 'daemon-stop' @{ pid = $PID }
    return 0
  } finally { if ($lock) { try { $lock.Dispose() } catch { } } }
}
function Invoke-Reap {
  Ensure-Dirs
  # owner.pid/ticks identify the short-lived PowerShell process that ran 'claim' (already
  # exited). They are NOT a liveness signal: using them would release every active claim.
  # The ONLY reap criterion is lease expiry: 'at' older than LeaseMin minutes. Claim
  # preserves 'at' when the same instance re-claims the same slot, so a live claim
  # effectively never expires -- do not add pid-based death checks here by mistake.
  $released = 0
  $now = Get-Date
  $handled = @{}
  $claimFiles = @()
  if (Test-Path -LiteralPath $claimsDir) { $claimFiles = @(Get-ChildItem -LiteralPath $claimsDir -Filter '*.json' -File -ErrorAction SilentlyContinue) }
  foreach ($cf in $claimFiles) {
    $c = Read-Json $cf.FullName
    if (-not $c -or -not $c.slot) {
      Remove-Item -LiteralPath $cf.FullName -Force -ErrorAction SilentlyContinue
      continue
    }
    $n = [int]$c.slot
    $handled[$n] = $true
    $s = Get-Slot $n
    $expired = $false
    if ($LeaseMin -gt 0 -and $c.at) {
      try { if (($now - [DateTime]::Parse([string]$c.at)).TotalMinutes -gt $LeaseMin) { $expired = $true } } catch { }
    }
    if ($expired) {
      $lock = Lock-Slot $n 2000
      if ($lock) {
        try {
          $s = Get-Slot $n
          if ($s.owner -and $s.owner.instance -eq $c.instance) { $s.owner = $null; Save-Slot $s }
        } finally { $lock.Dispose() }
      }
      Remove-Item -LiteralPath $cf.FullName -Force -ErrorAction SilentlyContinue
      $released++
      Write-Event 'reap' @{ instance = [string]$c.instance; slot = $n; reason = 'lease' }
    }
  }
  foreach ($n in @(Get-SlotNumbers)) {
    if ($handled.ContainsKey($n)) { continue }
    $s = Get-Slot $n
    if (-not $s.owner -or -not $s.owner.instance) { continue }
    $expired = $false
    if ($LeaseMin -gt 0 -and $s.owner.at) {
      try { if (($now - [DateTime]::Parse([string]$s.owner.at)).TotalMinutes -gt $LeaseMin) { $expired = $true } } catch { }
    }
    if ($expired) {
      $lock = Lock-Slot $n 2000
      if ($lock) {
        try {
          $s = Get-Slot $n
          if ($s.owner -and $s.owner.instance) { $s.owner = $null; Save-Slot $s }
        } finally { $lock.Dispose() }
      }
      $released++
      Write-Event 'reap' @{ instance = ''; slot = $n; reason = 'lease' }
    }
  }
  Write-Host ('reaped ' + $released + ' claim(s)')
  return 0
}

try {
  Ensure-Dirs
  $code = 0
  switch ($Action) {
    'up' { $code = Invoke-Up }
    'status' { $code = Invoke-Status }
    'claim' { $code = Invoke-Claim }
    'release' { $code = Invoke-Release }
    'rotate' { $code = Invoke-Rotate }
    'verify' { $code = Invoke-Verify }
    'down' { $code = Invoke-Down }
    'daemon' { $code = Invoke-Daemon }
    'reap' { $code = Invoke-Reap }
    default { $code = 1 }
  }
  exit $code
} catch {
  Write-Host ('error: ' + $_.Exception.Message)
  try { Write-Event 'error' @{ action = $Action; error = $_.Exception.Message } } catch { }
  exit 1
}
