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
  [ValidateSet('up','status','claim','release','rotate','verify','down','daemon','reap','grow','boot','spawn','stats','dashboard','tidy')]
  [string]$Action = 'status',
  # spawn: the action the detached process runs (boot or daemon).
  [ValidateSet('boot','daemon')]
  [string]$Then = 'daemon',
  # grow: the pool never grows past this many slots.
  [int]$Max = 0,
  # rotate: why the launcher rotates (its WHY: quota, watcher, exit, stop). quota/watcher = the
  # free limit came back, which feeds the burned-family memory.
  [string]$Reason = '',
  [int]$Count = 0,
  [int]$Slot = 0,
  [string]$Instance = '',
  # claim: the long-lived process that owns the claim (launcher cmd.exe, dispatcher). 0 = the
  # parent of this PowerShell, which is the caller when it runs the script directly.
  [int]$OwnerPid = 0,
  [switch]$Force,
  # rotate: try the fast swap to a free verified slot first (v1.5; needs -Instance and Reason quota/watcher).
  [switch]$Swap,
  # dashboard: write pool\dashboard.html without opening it.
  [switch]$NoOpen,
  # tidy: also delete old opencode.db snapshots and old .bak copies in backup\ (see Invoke-Tidy).
  [switch]$Prune,
  [switch]$AllowWarpTunnel,
  [string]$State = ($env:LOCALAPPDATA + '\opencode-infinite'),
  [int]$PortBase = 0,
  [int]$DedupeTries = 0,
  [int]$HealthSec = 0,
  [int]$LeaseMin = 0,
  [int]$BurnedTtlHours = 0,
  [string]$WgDir = '',
  # The API host itself (opencode.ai has AAAA): a passing trace proves the API sees the slot's IP.
  [string]$TraceUrl = 'https://opencode.ai/cdn-cgi/trace'
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
# WARP endpoints a slot cycles through when it is rebuilt. Measured from this host: one identity
# answered on all of these; 162.159.193.1:2408 did not. A rebuilt slot moves to the next one, so
# an endpoint that stopped answering the slot's handshakes is not retried in a loop.
$PeerEndpoints = @('162.159.192.1:2408', '188.114.97.1:2408', '162.159.195.1:2408', '162.159.192.1:4500', '188.114.96.1:500')
$ScriptVersion = '1.9.1'

$SelfPath = $MyInvocation.MyCommand.Path
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
if (-not $PSBoundParameters.ContainsKey('BurnedTtlHours')) { $BurnedTtlHours = [int](CfgVal 'WPOOL_BURNED_TTL_HOURS' 72) }
if (-not $PSBoundParameters.ContainsKey('WgDir')) { $WgDir = [string](CfgVal 'WPOOL_WG_DIR' '') }
$RotateMode = [string](CfgVal 'WPOOL_ROTATE_MODE' 'reconnect')
$VerifyProbe = [int](CfgVal 'WPOOL_VERIFY_PROBE' 0)
# Only the WARP app in TUNNEL mode can capture the slots' UDP (plan, limit 1). In proxy mode
# (warp-cli "Mode: WarpProxy", the setup this project uses) the slots go out by the normal route
# and never touch it, so proxy mode is always allowed. WPOOL_ALLOW_WARP_TUNNEL=1 (default) also
# allows tunnel mode; 0 makes 'up' refuse with exit 6 while the app is connected in tunnel mode.
# The launcher exports its effective value; config.json is the fallback for POOL.bat / manual runs.
$allowCfg = [string]$env:WPOOL_ALLOW_WARP_TUNNEL
if ($allowCfg -notmatch '^[01]$') { $allowCfg = [string](CfgVal 'WPOOL_ALLOW_WARP_TUNNEL' 1) }
if (-not $AllowWarpTunnel -and $allowCfg -eq '1') { $AllowWarpTunnel = [switch]$true }
if (-not $TraceUrl) { $TraceUrl = 'https://opencode.ai/cdn-cgi/trace' }
# 64 = two slots whose exit IPv6 share the first 64 bits count as the same exit (dedupe, burned,
# collision). 0 (default) = the full address. Turn on if 'stats' shows the limit follows the /64.
function EnvOrCfgInt([string]$name, [int]$default) {
  $e = [string][Environment]::GetEnvironmentVariable($name)
  if ($e -match '^\d+$') { return [int]$e }
  return [int](CfgVal $name $default)
}
$DedupePrefix = EnvOrCfgInt 'WPOOL_DEDUPE_PREFIX' 0
if ($DedupePrefix -ne 64) { $DedupePrefix = 0 }
if (-not $PSBoundParameters.ContainsKey('Max')) { $Max = EnvOrCfgInt 'WPOOL_MAX' 8 }
if ($Max -lt 1) { $Max = 8 }
if ($Max -gt 16) { $Max = 16 }

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
    rotations = 0; lastCheck = ''; owner = $null; epIdx = 0; endpoint = ''
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
      if ($c.PSObject.Properties['instance'] -and $c.instance) {
        Write-Json (Instance-EgressPath ([string]$c.instance)) ([ordered]@{ slot = $n; port = [int]$c.port; proxy = [string]$c.proxy; ip = $ip; colo = [string]$s.colo })
      }
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
# First 64 bits of an IPv6 exit ("2a09:bac1:1120:36a8"); '' for IPv4 or garbage.
function Get-Prefix64([string]$ip) {
  if (-not $ip -or $ip -notlike '*:*') { return '' }
  try {
    $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes()
    $h = @()
    for ($i = 0; $i -lt 8; $i += 2) { $h += ('{0:x}' -f (([int]$b[$i] -shl 8) -bor [int]$b[$i + 1])) }
    return ($h -join ':')
  } catch { return '' }
}
# ---- burned exit families ------------------------------------------------------------------
# Measured on 2026-11-26: exits in 2a09:bac5:... lasted 8-22 min of real use, while every exit in
# 2a09:bac1:...:36a8 (the range the WARP app also hands out, shared by many users) hit the free
# limit again within 10 s, so a slot kept rotating into the same burned range in a 10 s loop.
# v1.4: a "family" is no longer the first 32 bits. Measured on 2026-11-26 (25 rotations): inside
# 2a09:bac5 the exits ...:243c::39c:N burned in 8-89 s while ...:297d::422:N, ...:1c8c::2d8:N and
# ...:1c96::2d9:N lasted 5-35 min. What tells them apart is hextet 4 plus the interface id without
# its last hextet; hextet 3 (f41..f47) only follows the endpoint/colo. So the family of
# 2a09:bac5:f43:243c::39c:4 is "2a09:bac5:*:243c::39c". The pool remembers, per family, exits that
# hit the limit quickly and exits that lasted, and refuses exits from a family that only burns.
$FamQuickSec = 120
$FamGoodSec = 300
# families-v2.json: keyed by the narrow family. The old families.json (/32 keys) is left alone.
$familiesFile = Join-Path $poolDir 'families-v2.json'
function Get-Family([string]$ip) {
  if (-not $ip -or $ip -notlike '*:*') { return '' }
  try { $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes() } catch { return '' }
  $h = @()
  for ($i = 0; $i -lt 16; $i += 2) { $h += ('{0:x}' -f (([int]$b[$i] -shl 8) -bor [int]$b[$i + 1])) }
  $tail = @($h[4], $h[5], $h[6])
  while ($tail.Count -gt 0 -and $tail[0] -eq '0') { $tail = @($tail | Select-Object -Skip 1) }
  return ($h[0] + ':' + $h[1] + ':*:' + $h[3] + '::' + ($tail -join ':'))
}
function Read-Families {
  Import-FamilyHistory
  $o = Read-Json $familiesFile
  $h = @{}
  if ($o) { foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
  return $h
}
# First run of v1.4: seed families-v2.json from rotation-history.jsonl (rows whose reason is
# quota/watcher, or empty on lines written before the reason existed), with their own timestamps,
# so the pool already knows yesterday's burned families instead of relearning them in a 10 s loop.
$script:famSeeded = $false
function Import-FamilyHistory {
  if ($script:famSeeded) { return }
  $script:famSeeded = $true
  if (Test-Path -LiteralPath $familiesFile) { return }
  $hist = Join-Path $poolDir 'rotation-history.jsonl'
  $all = [ordered]@{}
  if (Test-Path -LiteralPath $hist) {
    foreach ($l in @(Get-Content -LiteralPath $hist -Encoding UTF8)) {
      if (-not $l.Trim()) { continue }
      try { $r = $l | ConvertFrom-Json } catch { continue }
      # A line with a reason other than quota/watcher (exit, stop, '' = daemon/manual) is not a limit.
      if ($r.PSObject.Properties['reason'] -and @('quota', 'watcher') -notcontains ([string]$r.reason).ToLowerInvariant()) { continue }
      $lived = [int]$r.livedSec
      $fam = Get-Family ([string]$r.before)
      if (-not $fam -or $lived -lt 0) { continue }
      $kind = ''
      if ($lived -lt $FamQuickSec) { $kind = 'quick' } elseif ($lived -ge $FamGoodSec) { $kind = 'good' }
      if (-not $kind) { continue }
      if (-not $all.Contains($fam)) { $all[$fam] = [ordered]@{ quick = @(); good = @() } }
      $all[$fam][$kind] = @($all[$fam][$kind]) + [string]$r.at
    }
  }
  try { Write-Json $familiesFile $all; Write-Event 'families-seeded' @{ families = $all.Count } } catch { }
}
# Outcomes of a family within the TTL, oldest first: @{ t = DateTime; k = 'quick'|'good' }.
function Get-FamilyOutcomes([string]$fam, $all = $null) {
  $list = @()
  if (-not $fam) { return $list }
  if ($null -eq $all) { $all = Read-Families }
  if (-not $all.ContainsKey($fam)) { return $list }
  $f = $all[$fam]
  $ttl = [Math]::Max(1, $BurnedTtlHours)
  $now = Get-Date
  foreach ($k in @('quick', 'good')) {
    foreach ($t in @($f.$k)) {
      try { $d = [DateTime]::Parse([string]$t); if (($now - $d).TotalHours -lt $ttl) { $list += [pscustomobject]@{ t = $d; k = $k } } } catch { }
    }
  }
  return @($list | Sort-Object t)
}
function Get-FamilyCounts([string]$fam, $all = $null) {
  $o = @(Get-FamilyOutcomes $fam $all)
  $last2 = @($o | Select-Object -Last 2)
  $bad = (@($o | Where-Object { $_.k -eq 'quick' }).Count -ge 2 -and $last2.Count -eq 2 -and @($last2 | Where-Object { $_.k -eq 'quick' }).Count -eq 2)
  return @{ quick = @($o | Where-Object { $_.k -eq 'quick' }).Count; good = @($o | Where-Object { $_.k -eq 'good' }).Count; burned = $bad }
}
# Burned = 2+ quick limits within the TTL and the last two outcomes were both quick. One exit that
# lasted clears it; a family that worked in the morning but burns now (243c::39c on 26/11) is
# refused after two quick limits instead of waiting for its good runs to age out.
function Test-FamilyBad([string]$ip) {
  $fam = Get-Family $ip
  if (-not $fam) { return $false }
  return [bool](Get-FamilyCounts $fam).burned
}
# v1.5: how well a family has done within the TTL: +1 per exit that lasted, -1 per quick limit,
# with the newest outcome counted twice. Unknown families score 0, between good and bad ones.
function Get-FamilyScore([string]$ip, $all = $null) {
  $o = @(Get-FamilyOutcomes (Get-Family $ip) $all)
  $score = 0
  foreach ($x in $o) { if ($x.k -eq 'good') { $score++ } else { $score-- } }
  if ($o.Count) { if ($o[-1].k -eq 'good') { $score++ } else { $score-- } }
  return $score
}
function Add-FamilyOutcome([string]$ip, [string]$kind) {
  $fam = Get-Family $ip
  if (-not $fam -or ($kind -ne 'quick' -and $kind -ne 'good')) { return }
  $lk = Lock-Pool 'families' 5000
  if (-not $lk) { return }
  try {
    $wasBad = Test-FamilyBad $ip
    $all = Read-Families
    $f = $null
    if ($all.ContainsKey($fam)) { $f = $all[$fam] }
    $q = @(); $g = @()
    if ($f) { $q = @($f.quick | Where-Object { $_ }); $g = @($f.good | Where-Object { $_ }) }
    if ($kind -eq 'quick') { $q += (Get-Date).ToString('o') } else { $g += (Get-Date).ToString('o') }
    $all[$fam] = [ordered]@{ quick = @($q | Select-Object -Last 50); good = @($g | Select-Object -Last 50) }
    $out = [ordered]@{}
    foreach ($k in @($all.Keys | Sort-Object)) { $out[$k] = $all[$k] }
    Write-Json $familiesFile $out
    if (-not $wasBad -and (Test-FamilyBad $ip)) { Write-Event 'family-burned' @{ family = $fam; ip = $ip } }
  } finally { $lk.Dispose() }
}
# What counts as "the same exit": the full IP, or its /64 with WPOOL_DEDUPE_PREFIX=64.
function UniqKey([string]$ip) {
  if ($DedupePrefix -eq 64) { $p = Get-Prefix64 $ip; if ($p) { return ($p + '::/64') } }
  return $ip
}
# Dedupe key (v1.4): with WPOOL_FAMILY_DEDUPE=1 (default) two free slots in the same family count
# as the same exit, so 4 tunnels are 4 different ranges and not 2 ranges twice. Only used to
# rotate free duplicates; Update-Uniqueness (which marks 'degraded') keeps the strict key.
$FamilyDedupe = EnvOrCfgInt 'WPOOL_FAMILY_DEDUPE' 1
# v1.5: 1 (default) = a window that hits the limit moves to a free verified slot at once (-Swap).
$FastSwap = EnvOrCfgInt 'WPOOL_FAST_SWAP' 1
function DedupeKey([string]$ip) {
  if ($FamilyDedupe -eq 1) { $f = Get-Family $ip; if ($f) { return $f } }
  return (UniqKey $ip)
}
# Per-slot cooldown for rotations the pool starts by itself (family dedupe, burned replacement):
# when every family is burned or taken, a slot is retried every 10 min, not every HealthSec.
$script:selfRotateAt = @{}
function Test-SelfRotateDue([int]$n) {
  if ($script:selfRotateAt.ContainsKey($n) -and ((Get-Date) - $script:selfRotateAt[$n]).TotalSeconds -lt 600) { return $false }
  $script:selfRotateAt[$n] = Get-Date
  return $true
}
function Update-Uniqueness($slots) {
  $seen = @{}
  foreach ($s in @($slots | Sort-Object slot)) {
    if ($s.health -eq 'up' -and $s.ip) {
      $key = UniqKey ([string]$s.ip)
      if ($seen.ContainsKey($key)) { $s.health = 'degraded'; Save-Slot $s }
      else { $seen[$key] = [int]$s.slot }
    }
  }
}
# Plan item 8: slots past the configured count (left by an earlier, larger 'up' or 'grow') are
# stopped and their folders removed, unless a live window or dispatcher still holds them.
function Invoke-RetireExtra([int]$keep) {
  foreach ($n in @(Get-SlotNumbers)) {
    if ($n -le $keep) { continue }
    $s = Get-Slot $n
    if ((Test-OwnerAlive $s.owner) -eq $true) { continue }
    $lk = Lock-Slot $n 2000
    if (-not $lk) { continue }
    try { Stop-SlotProcess $n | Out-Null } finally { $lk.Dispose() }
    try {
      Remove-Item -LiteralPath (SlotDir $n) -Recurse -Force -ErrorAction Stop
      Remove-Item -LiteralPath (Join-Path $poolDir ((SlotName $n) + '.lock')) -Force -ErrorAction SilentlyContinue
      Write-Event 'slot-retired' @{ slot = $n; keep = $keep }
    } catch { Write-Event 'slot-retire-error' @{ slot = $n; error = $_.Exception.Message } }
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
    $fam = '-'
    if ($s.ip) { $fam = Get-Family ([string]$s.ip); if (Test-FamilyBad ([string]$s.ip)) { $fam += ' (burned)' } }
    $rows += [pscustomobject]@{ Slot = [int]$s.slot; Port = [int]$s.port; IP = $ip; Family = $fam; Colo = $colo; Health = [string]$s.health; Owner = $owner }
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

function Lock-Pool([string]$name, [int]$timeoutMs) {
  $path = Join-Path $poolDir ($name + '.lock')
  $end = (Get-Date).AddMilliseconds([Math]::Max(0, $timeoutMs))
  while ($true) {
    try {
      return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
      if ((Get-Date) -ge $end) { return $null }
      Start-Sleep -Milliseconds 250
    } catch { return $null }
  }
}
# Claim owner = a long-lived process identified by pid + start ticks (never a recycled pid).
function Get-OwnerIdentity([int]$ownerPid) {
  $id = $ownerPid
  if ($id -le 0) {
    try { $id = [int](Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop).ParentProcessId } catch { $id = 0 }
  }
  if ($id -le 0) { return $null }
  try {
    $p = Get-Process -Id $id -ErrorAction Stop
    return [ordered]@{ pid = [int]$id; ticks = [long]$p.StartTime.Ticks; name = [string]$p.ProcessName }
  } catch { return $null }
}
# $true = owner process alive, $false = gone, $null = unknown (claim written before v1.1).
function Test-OwnerAlive($owner) {
  if (-not $owner) { return $null }
  if (-not $owner.PSObject.Properties['kind'] -or [string]$owner.kind -ne 'process') { return $null }
  $procId = 0; $ticks = [long]0
  try { $procId = [int]$owner.pid; $ticks = [long]$owner.ticks } catch { return $null }
  if ($procId -le 0 -or $ticks -le 0) { return $null }
  return ($null -ne (Get-ProcessByPidStart $procId $ticks))
}
# v1.7: in use = an owner that is alive OR unknown (a lease claim, or one written before v1.1).
# Rotations the pool starts by itself (burned replacement, family dedupe) never touch such a slot.
function Test-SlotInUse($s) {
  if (-not $s -or -not $s.owner) { return $false }
  return ((Test-OwnerAlive $s.owner) -ne $false)
}
function Instance-EgressPath([string]$inst) {
  return (Join-Path (Join-Path (Join-Path $State 'instances') $inst) 'egress.json')
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
    # warp-cli 2024+ prints "Status update: Connected"; older builds print "Status: Connected"
    # or a bare "Connected". "Disconnected"/"Connecting" must not match.
    if ($txt -notmatch '(?im)^\s*(Status(\s+update)?\s*:\s*)?Connected\b') { return $false }
    # Connected in proxy mode ("Mode: WarpProxy on port 40000") captures nothing: not a tunnel.
    $p2 = Start-Process -FilePath $wc -ArgumentList @('--accept-tos', 'settings') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p2.WaitForExit(8000)) { try { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue } catch { }; return $true }
    $set = ''
    if (Test-Path -LiteralPath $out) { $set = [IO.File]::ReadAllText($out) -replace '\x1b\[[0-9;]*m', '' }
    if ($set -match '(?im)Mode:\s*WarpProxy') { return $false }
    return $true
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
  $seenDns = $false; $seenEndpoint = $false; $seenAllowed = $false; $hasV6 = $false; $seenKeepalive = $false
  foreach ($ln in $lines) {
    $t = $ln.Trim()
    if ($t -match '^\[(.+)\]$') {
      if ($section -eq 'interface' -and -not $seenDns) { $out.Add('DNS = 1.1.1.1'); $seenDns = $true }
      if ($section -eq 'peer') {
        if (-not $seenEndpoint) { $out.Add('Endpoint = ' + $PeerEndpoint); $seenEndpoint = $true }
        if (-not $seenAllowed) { $out.Add('AllowedIPs = 0.0.0.0/0, ::/0'); $seenAllowed = $true }
        if (-not $seenKeepalive) { $out.Add('PersistentKeepalive = 25'); $seenKeepalive = $true }
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
    if ($kl -eq 'persistentkeepalive') { $seenKeepalive = $true; $out.Add('PersistentKeepalive = ' + $v); continue }
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
    # Pool slots sit idle most of the time; without a keepalive the UDP mapping in the router (or in
    # the WARP client tunnel) expires and the next trace or request stalls until a new handshake.
    if (-not $seenKeepalive) { $out.Add('PersistentKeepalive = 25') }
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
function Write-RunConf([int]$n, [switch]$NextEndpoint) {
  $dir = SlotDir $n
  $prof = Join-Path $dir 'profile.conf'
  if (-not (Test-Path -LiteralPath $prof)) { throw ('profile.conf missing for slot ' + $n) }
  $txt = [IO.File]::ReadAllText($prof)
  $s = Get-Slot $n
  $port = [int]$s.port
  if (-not (Test-SlotPortInRange $port)) { $port = SlotPort $n }
  $idx = 0
  try { $idx = [int]$s.epIdx } catch { $idx = 0 }
  if ($NextEndpoint) { $idx++ }
  $idx = (($idx % $PeerEndpoints.Count) + $PeerEndpoints.Count) % $PeerEndpoints.Count
  $script:PeerEndpoint = $PeerEndpoints[$idx]
  $s.epIdx = $idx
  $s.endpoint = $script:PeerEndpoint
  Save-Slot $s
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
# CreateProcess with no inherited handles, no console (CREATE_NO_WINDOW) and, when the caller's job
# allows it, out of that job (CREATE_BREAKAWAY_FROM_JOB): a slot outlives whoever started it.
# Compiled only when a wireproxy is started, so claim/status/release stay fast.
function Ensure-Detached {
  if ('OpenInfinite.Detached' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace OpenInfinite {
  public static class Detached {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
      public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
      public int dwX; public int dwY; public int dwXSize; public int dwYSize;
      public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
      public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
      public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
      uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    public static int Start(string exe, string args, string cwd) {
      const uint CREATE_NO_WINDOW = 0x08000000, CREATE_NEW_PROCESS_GROUP = 0x00000200, CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
      int err = 0;
      foreach (uint extra in new uint[] { CREATE_BREAKAWAY_FROM_JOB, 0 }) {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        StringBuilder cmd = new StringBuilder("\"" + exe + "\" " + args);
        if (CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | extra, IntPtr.Zero, cwd, ref si, out pi)) {
          CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
          return pi.dwProcessId;
        }
        err = Marshal.GetLastWin32Error();
      }
      throw new Win32Exception(err);
    }
  }
}
'@
}
function Start-SlotProcess([int]$n) {
  $bins = Ensure-Bins
  $dir = SlotDir $n
  $run = Join-Path $dir 'run.conf'
  if (-not (Test-Path -LiteralPath $run)) { throw ('run.conf missing for slot ' + $n) }
  # Plan, up step 3: the port is pinned to the slot. A port already taken fails the slot instead of
  # starting a second wireproxy that cannot bind (and whose trace would measure someone else's proxy).
  $s0 = Get-Slot $n
  $port0 = [int]$s0.port
  if (-not (Test-SlotPortInRange $port0)) { $port0 = SlotPort $n }
  if (Test-Port $port0) {
    if (Test-SlotProcess $s0) { throw ('slot ' + $n + ' already has a running wireproxy on port ' + $port0) }
    throw ('port ' + $port0 + ' is in use by another program; slot ' + $n + ' not started')
  }
  # v1.0 used Start-Process -Redirect*, which inherits every handle of this PowerShell and its
  # console. A caller reading this script through a pipe (the dispatcher's '2>&1 | Out-Null')
  # then waited until the wireproxy exited -- i.e. forever -- and closing the launcher window that
  # booted the pool killed the slots on its console. -s keeps wireproxy silent, so no log is lost.
  foreach ($old in @('out.log', 'err.log')) { Remove-Item -LiteralPath (Join-Path $dir $old) -Force -ErrorAction SilentlyContinue }
  $newPid = 0
  Ensure-Detached
  try { $newPid = [OpenInfinite.Detached]::Start($bins.wireproxy, ('-s -c "' + $run + '"'), $dir) }
  catch { throw ('wireproxy did not start for slot ' + $n + ': ' + $_.Exception.Message) }
  $p = $null
  try { $p = Get-Process -Id $newPid -ErrorAction Stop } catch { }
  if (-not $p) { throw ('wireproxy exited at once for slot ' + $n) }
  $ticks = [long]0
  try { $ticks = $p.StartTime.Ticks } catch { }
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
function Get-BurnedIps($s) {
  $ips = @()
  foreach ($b in @($s.burned)) {
    if (-not $b -or -not $b.ip) { continue }
    $expired = $false
    if ($b.until) { try { if ([DateTime]::Parse([string]$b.until) -lt (Get-Date)) { $expired = $true } } catch { } }
    if (-not $expired) { $ips += [string]$b.ip }
  }
  return $ips
}
# $avoid = IPs that do not count as a new exit (the previous IP plus the slot's live burned[]).
function Wait-SlotHealthy([int]$n, [int]$seconds, [string[]]$avoid = @(), [switch]$AvoidBadFamily, [string[]]$AvoidFamilies = @()) {
  $end = (Get-Date).AddSeconds($seconds)
  $last = $null
  $refused = 0
  $avoidKeys = @($avoid | Where-Object { $_ } | ForEach-Object { UniqKey ([string]$_) })
  while ((Get-Date) -lt $end) {
    $s = Get-Slot $n
    if (-not (Test-SlotProcess $s)) { return @{ ok = $false; reason = 'process dead'; trace = $null } }
    $m = Measure-Slot $s 8
    if ($m.ok) {
      $ip = [string]$m.trace.ip
      $isOld = ($avoidKeys.Count -gt 0 -and $avoidKeys -contains (UniqKey $ip))
      $isBad = ($AvoidBadFamily -and (Test-FamilyBad $ip))
      # v1.4: a family another slot already uses (family dedupe) counts as taken.
      $isTaken = (@($AvoidFamilies | Where-Object { $_ }).Count -gt 0 -and $AvoidFamilies -contains (DedupeKey $ip))
      if (-not $isOld -and -not $isBad -and -not $isTaken) { return $m }
      $last = $m
      # The exit of a live tunnel rarely changes within seconds: two refusals in a row are enough,
      # the caller moves on to the next endpoint or identity instead of waiting out the timeout.
      $refused++
      if ($refused -ge 2) {
        if ($isBad) { Write-Event 'exit-refused' @{ slot = $n; ip = $ip; family = (Get-Family $ip); endpoint = [string]$s.endpoint } }
        return @{ ok = $false; reason = $(if ($isBad) { 'burned family' } elseif ($isTaken) { 'family taken' } else { 'same ip' }); trace = $m.trace }
      }
    }
    Start-Sleep -Milliseconds 1000
  }
  if ($last) { return @{ ok = $false; reason = 'same ip'; trace = $last.trace } }
  return @{ ok = $false; reason = 'no trace'; trace = $null }
}
function Start-Slot([int]$n, [switch]$NewIdentity, [string]$PrevIp = '', [int]$WaitSec = 25, [switch]$AvoidBurned, [switch]$NextEndpoint, [switch]$AvoidBadFamily, [string[]]$AvoidFamilies = @()) {
  $s = Get-Slot $n
  if (-not (Test-SlotPortInRange ([int]$s.port))) { $s.port = SlotPort $n }
  # One wireproxy per slot: any process still serving this slot is stopped first, so a restart,
  # a reconnect or a new identity never races a second wireproxy for the same port.
  if (Test-SlotProcess $s) { Stop-SlotProcess $n | Out-Null; $s = Get-Slot $n }
  $avoid = @()
  if ($PrevIp) { $avoid += $PrevIp }
  if ($AvoidBurned) { $avoid += @(Get-BurnedIps $s) }
  try {
    $identity = Ensure-Identity $n -NewIdentity:$NewIdentity
    $run = Write-RunConf $n -NextEndpoint:$NextEndpoint
    $s = Get-Slot $n
    $s.identity = $identity
    $s.conf = $run
    Save-Slot $s
    $s = Start-SlotProcess $n
  } catch {
    Write-Event 'slot-error' @{ slot = $n; error = $_.Exception.Message }
    return @{ ok = $false; reason = $_.Exception.Message; slot = $n; ip = '' }
  }
  $m = Wait-SlotHealthy $n $WaitSec $avoid -AvoidBadFamily:$AvoidBadFamily -AvoidFamilies $AvoidFamilies
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
function Rotate-Slot([int]$n, [switch]$ForceIdentity, [int]$MaxIdentity = 2, [int]$WaitSec = 20, [string[]]$AvoidFamilies = @()) {
  $s = Get-Slot $n
  $oldIp = [string]$s.ip
  # How long the old exit served, measured before the rotation itself takes any time.
  $lived = -1
  if ($s.PSObject.Properties['ipSince'] -and $s.ipSince) { try { $lived = [int]((Get-Date) - [DateTime]::Parse([string]$s.ipSince)).TotalSeconds } catch { } }
  # The free limit came back (launcher WHY = quota/watcher): remember how the old exit's family did.
  if ($oldIp -and $lived -ge 0 -and @('quota', 'watcher') -contains $Reason.ToLowerInvariant()) {
    if ($lived -lt $FamQuickSec) { Add-FamilyOutcome $oldIp 'quick' }
    elseif ($lived -ge $FamGoodSec) { Add-FamilyOutcome $oldIp 'good' }
  }
  if ($oldIp) { Add-Burned $s $oldIp; Save-Slot $s }
  $manual = Use-Manual $n
  $success = $false
  $lastIp = $oldIp
  # Plan: reconnect first (no registration), cycling WARP endpoints; an IP equal to the old one, still
  # in burned[] or from a burned family escalates to a new identity. Start-Slot stops the old wireproxy.
  if (-not $ForceIdentity) {
    for ($i = 1; $i -le 4; $i++) {
      $r = Start-Slot $n -PrevIp $oldIp -WaitSec $WaitSec -AvoidBurned -AvoidBadFamily -NextEndpoint:($i -ge 2) -AvoidFamilies $AvoidFamilies
      if ($r.ok) { $lastIp = [string]$r.ip; $success = $true; break }
    }
  }
  if (-not $success -and -not $manual) {
    for ($i = 1; $i -le $MaxIdentity; $i++) {
      $r = Start-Slot $n -NewIdentity -PrevIp $oldIp -WaitSec 25 -AvoidBurned -AvoidBadFamily -NextEndpoint -AvoidFamilies $AvoidFamilies
      if ($r.ok) { $lastIp = [string]$r.ip; $success = $true; break }
    }
  }
  if (-not $success) {
    # Keep the slot serving even when no new IP was found: a stale exit beats a dead port.
    $r = Start-Slot $n -WaitSec 25
    if ($r.ok) { $lastIp = [string]$r.ip }
  }
  $s = Get-Slot $n
  $s.rotations = [int]$s.rotations + 1
  # Plan item 6: one line per rotation with the /64 of both exits and how long the old exit
  # lasted. 'stats' reads it to tell an IP-based limit from a range-based one.
  $ownerName = ''
  if ($s.owner -and $s.owner.instance) { $ownerName = [string]$s.owner.instance }
  try {
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{
      at = (Get-Date).ToString('o'); slot = $n; owner = $ownerName; ok = [bool]$success;
      before = $oldIp; beforePrefix = (Get-Prefix64 $oldIp); after = $lastIp; afterPrefix = (Get-Prefix64 $lastIp);
      livedSec = $lived; endpoint = [string]$s.endpoint; reason = $Reason;
      beforeFamily = (Get-Family $oldIp); afterFamily = (Get-Family $lastIp) })
    [IO.File]::AppendAllText((Join-Path $poolDir 'rotation-history.jsonl'), $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
  } catch { }
  if ($s.PSObject.Properties['ipSince']) { $s.ipSince = (Get-Date).ToString('o') }
  else { $s | Add-Member -NotePropertyName ipSince -NotePropertyValue ((Get-Date).ToString('o')) }
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

function Invoke-Up {
  Ensure-Dirs
  if ($Count -lt 1) { Write-Host 'up requires Count >= 1'; return 1 }
  if ($PortBase -le 0 -or (($PortBase + $Count) -gt 65535)) { Write-Host 'bad PortBase/Count'; return 1 }
  # Two 'up' runs at once (launcher boot + POOL.bat, two windows) used to start two wireproxies per
  # slot and register identities over each other. The second one now waits and then finds the
  # slots already up, which is fast.
  $upLock = Lock-Pool 'up' 600000
  if (-not $upLock) { Write-Host 'another up is still running after 10 minutes'; return 4 }
  try { return (Invoke-UpLocked) } finally { $upLock.Dispose() }
}
function Write-UpProgress([int]$done, [int]$total, [string]$what) {
  try { Write-Json (Join-Path $poolDir 'up-progress.json') ([ordered]@{ done = $done; total = $total; what = $what; at = (Get-Date).ToString('o') }) } catch { }
}
# A slot past the configured count that a live window or dispatcher still uses (it was added by
# 'grow') keeps the count up to it, so 'up' never retires a tunnel in use.
function Get-EffectiveCount([int]$configured) {
  $eff = $configured
  foreach ($s in @(Get-AllSlots)) {
    if ([int]$s.slot -le $eff) { continue }
    if ((Test-OwnerAlive $s.owner) -eq $true) { $eff = [int]$s.slot }
  }
  return $eff
}
function Invoke-UpLocked {
  $Count = Get-EffectiveCount $Count
  # Persist the effective base/count so every later action without explicit parameters reuses it.
  Write-Json $poolConfigFile ([ordered]@{ portBase = [int]$PortBase; count = [int]$Count; writtenAt = (Get-Date).ToString('o') })
  if (Test-Path -LiteralPath $stopFlag) { Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue }
  $warpUp = Test-WarpConnected
  if ($warpUp -and -not $AllowWarpTunnel) {
    Write-Host 'the WARP app is connected in tunnel mode; disconnect it, switch it to proxy mode, or set WPOOL_ALLOW_WARP_TUNNEL=1'
    Write-Event 'warp-client-refused' @{ tunnelMode = $true }
    return 6
  }
  if ($warpUp) { Write-Event 'warp-client-stacked' @{ tunnelMode = $true; note = 'slots run inside the WARP app tunnel' } }
  Write-UpProgress 0 $Count 'binaries'
  Ensure-Bins | Out-Null
  for ($n = 1; $n -le $Count; $n++) {
    Write-UpProgress ($n - 1) $Count ('slot ' + $n)
    # The daemon of another window may be restarting this slot right now: wait for its lock.
    $lk = Lock-Slot $n 90000
    if (-not $lk) { Write-Host ('slot ' + $n + ' is locked by another pool action; skipped'); continue }
    try {
      $s = Get-Slot $n
      $expected = SlotPort $n
      if ([int]$s.port -eq $expected -and (Test-SlotProcess $s)) {
        $m = Measure-Slot $s 8
        if (-not $m.ok) { Start-Sleep -Seconds 2; $m = Measure-Slot $s 8 }
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
      # Measured: a slot that gets no handshake reply usually has a stalled UDP path, not a bad
      # identity -- the same identity and endpoint answer again from a new process (new source
      # port). So attempt 2 only restarts; attempt 3 registers a new identity.
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
          $r = Start-Slot $n -NewIdentity:($attempt -ge 3) -NextEndpoint:($attempt -ge 2) -WaitSec 25
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
    } finally { $lk.Dispose() }
  }
  Write-UpProgress $Count $Count 'dedupe'
  for ($t = 1; $t -le [Math]::Max(1, $DedupeTries); $t++) {
    $ips = @(Get-AllSlots | Where-Object { [int]$_.slot -le $Count -and $_.health -eq 'up' -and $_.ip } | ForEach-Object { DedupeKey ([string]$_.ip) })
    if ($ips.Count -eq @($ips | Sort-Object -Unique).Count) { break }
    Invoke-DaemonDedupe
  }
  Write-UpProgress $Count $Count 'burned families'
  Invoke-ReplaceBurned
  Invoke-RetireExtra $Count
  Write-UpProgress $Count $Count 'done'
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
  if ($Instance -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $Instance -ieq 'egress') { Write-Host 'bad Instance name'; return 1 }
  Ensure-Dirs
  $nums = @(Get-SlotNumbers)
  # Only the configured slots are handed out; slot folders past the count are leftovers.
  if ($Count -ge 1) { $nums = @($nums | Where-Object { $_ -le $Count }) }
  if ($nums.Count -eq 0) { Write-Host 'no slots'; return 7 }
  $ownerId = Get-OwnerIdentity $OwnerPid
  $claimPath = Join-Path $claimsDir ($Instance + '.json')
  $existing = Read-Json $claimPath
  $order = @()
  if ($existing -and $existing.slot) { $order += [int]$existing.slot }
  # Free slots whose exit is in a burned family (or still in the slot's own burned[], left by a
  # swap) go last; the others go best family first (v1.5): a new window starts on an exit that works.
  $good = @(); $bad = @()
  $famAll = Read-Families
  foreach ($n in $nums) {
    if ($order -contains $n) { continue }
    $sn = Get-Slot $n
    $ipn = [string]$sn.ip
    if ((Test-FamilyBad $ipn) -or ($ipn -and @(Get-BurnedIps $sn) -contains $ipn)) { $bad += $n }
    else { $good += [pscustomobject]@{ n = $n; score = (Get-FamilyScore $ipn $famAll) } }
  }
  $order += @($good | Sort-Object @{ Expression = 'score'; Descending = $true }, n | ForEach-Object { [int]$_.n }) + $bad
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
      if ($ownerInstance -and $ownerInstance -ne $Instance) {
        # A slot whose owner process is gone is free again (same rule as reap); a live or
        # unknown owner keeps it.
        if ((Test-OwnerAlive $s.owner) -ne $false) { continue }
        Remove-Item -LiteralPath (Join-Path $claimsDir ($ownerInstance + '.json')) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Instance-EgressPath $ownerInstance) -Force -ErrorAction SilentlyContinue
        Write-Event 'reap' @{ instance = $ownerInstance; slot = $n; reason = 'owner-gone-on-claim' }
      }
      $now = (Get-Date).ToString('o')
      $at = $now
      if ($existing -and [int]$existing.slot -eq $n -and $existing.at) { $at = [string]$existing.at }
      $owner = [ordered]@{ instance = $Instance; at = $at; renewedAt = $now }
      if ($ownerId) {
        $owner.kind = 'process'; $owner.pid = [int]$ownerId.pid; $owner.ticks = [long]$ownerId.ticks; $owner.process = [string]$ownerId.name
      } else { $owner.kind = 'lease' }
      $s.owner = $owner
      Save-Slot $s
      $claim = [ordered]@{
        instance = $Instance; slot = $n; port = [int]$s.port;
        proxy = ('http://127.0.0.1:' + $s.port); ip = [string]$s.ip; at = $at; renewedAt = $now;
        owner = $owner
      }
      Write-Json $claimPath $claim
      # Plan: instances\<instance>\egress.json says exactly where this instance leaves from.
      Write-Json (Instance-EgressPath $Instance) ([ordered]@{ slot = $n; port = [int]$s.port; proxy = ('http://127.0.0.1:' + $s.port); ip = [string]$s.ip; colo = [string]$s.colo })
      # The instance moved to another slot (its old one went down): the old slot stops naming it.
      foreach ($m in $nums) {
        if ($m -eq $n) { continue }
        $o = Get-Slot $m
        if (-not $o.owner -or [string]$o.owner.instance -ne $Instance) { continue }
        $lk = Lock-Slot $m 2000
        if (-not $lk) { continue }
        try {
          $o = Get-Slot $m
          if ($o.owner -and [string]$o.owner.instance -eq $Instance) { $o.owner = $null; Save-Slot $o }
        } finally { $lk.Dispose() }
      }
      Write-Event 'claim' @{ instance = $Instance; slot = $n; port = [int]$s.port; ownerPid = $(if ($ownerId) { [int]$ownerId.pid } else { 0 }) }
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
  Remove-Item -LiteralPath (Instance-EgressPath $Instance) -Force -ErrorAction SilentlyContinue
  Write-Host ('released ' + $Instance)
  return 0
}
# v1.5 fast swap: when the free limit comes back (Reason quota/watcher) and the window passes -Swap
# and -Instance, its claim moves at once to a FREE slot that is already up and verified, in a
# working family different from the burned one. No reconnect, no registration: the window gets a new
# exit in about a second instead of 10-60 s. The old slot is left free with its exit in burned[];
# the daemon rotates it in the background (Invoke-ReplaceBurned) before anyone claims it again.
# Returns the new slot number, or 0 when no spare fits (the caller rotates in place as before).
function Invoke-SwapToSpare([int]$from) {
  if (-not $Swap -or -not $Instance -or $FastSwap -ne 1) { return 0 }
  if (@('quota', 'watcher') -notcontains $Reason.ToLowerInvariant()) { return 0 }
  $claimPath = Join-Path $claimsDir ($Instance + '.json')
  $claim = Read-Json $claimPath
  if (-not $claim -or [int]$claim.slot -ne $from) { return 0 }
  $src = Get-Slot $from
  $oldIp = [string]$src.ip
  $oldFam = Get-Family $oldIp
  $all = Read-Families
  $cands = @()
  foreach ($n in @(Get-SlotNumbers)) {
    if ($n -eq $from -or ($Count -ge 1 -and $n -gt $Count)) { continue }
    $s = Get-Slot $n
    if ($s.health -ne 'up' -or -not $s.ip) { continue }
    if ($s.owner -and (Test-OwnerAlive $s.owner) -ne $false) { continue }
    $ip = [string]$s.ip
    if ((Get-Family $ip) -eq $oldFam) { continue }
    if (Test-FamilyBad $ip) { continue }
    if (@(Get-BurnedIps $s) -contains $ip) { continue }
    $cands += [pscustomobject]@{ n = $n; score = (Get-FamilyScore $ip $all) }
  }
  foreach ($c in @($cands | Sort-Object @{ Expression = 'score'; Descending = $true }, n)) {
    $n = [int]$c.n
    $lk = Lock-Slot $n 2000
    if (-not $lk) { continue }
    try {
      $s = Get-Slot $n
      if ($s.owner -and (Test-OwnerAlive $s.owner) -ne $false) { continue }
      if (-not (Test-SlotProcess $s)) { continue }
      $m = Measure-Slot $s 6
      if (-not $m.ok -or (Get-Family ([string]$m.trace.ip)) -eq $oldFam -or (Test-FamilyBad ([string]$m.trace.ip))) { continue }
      # The old exit: same bookkeeping as Rotate-Slot (family outcome, burned[], history line).
      $lived = -1
      if ($src.PSObject.Properties['ipSince'] -and $src.ipSince) { try { $lived = [int]((Get-Date) - [DateTime]::Parse([string]$src.ipSince)).TotalSeconds } catch { } }
      if ($oldIp -and $lived -ge 0) {
        if ($lived -lt $FamQuickSec) { Add-FamilyOutcome $oldIp 'quick' }
        elseif ($lived -ge $FamGoodSec) { Add-FamilyOutcome $oldIp 'good' }
      }
      $now = (Get-Date).ToString('o')
      $owner = $src.owner
      if (-not $owner) { $owner = $claim.owner }
      $s.ip = [string]$m.trace.ip; $s.colo = [string]$m.trace.colo; $s.warp = [string]$m.trace.warp
      $s.health = 'up'; $s.verifiedAt = $now; $s.owner = $owner
      if ($s.PSObject.Properties['ipSince']) { $s.ipSince = $now } else { $s | Add-Member -NotePropertyName ipSince -NotePropertyValue $now }
      Save-Slot $s
      $src = Get-Slot $from
      if ($oldIp) { Add-Burned $src $oldIp }
      $src.owner = $null
      Save-Slot $src
      $claim2 = [ordered]@{
        instance = $Instance; slot = $n; port = [int]$s.port; proxy = ('http://127.0.0.1:' + $s.port);
        ip = [string]$s.ip; at = [string]$claim.at; renewedAt = $now; owner = $owner
      }
      Write-Json $claimPath $claim2
      Write-Json (Instance-EgressPath $Instance) ([ordered]@{ slot = $n; port = [int]$s.port; proxy = ('http://127.0.0.1:' + $s.port); ip = [string]$s.ip; colo = [string]$s.colo })
      try {
        $line = ConvertTo-Json -Compress -InputObject ([ordered]@{
          at = $now; slot = $from; owner = $Instance; ok = $true; swap = $n;
          before = $oldIp; beforePrefix = (Get-Prefix64 $oldIp); after = [string]$s.ip; afterPrefix = (Get-Prefix64 ([string]$s.ip));
          livedSec = $lived; endpoint = [string]$src.endpoint; reason = $Reason;
          beforeFamily = $oldFam; afterFamily = (Get-Family ([string]$s.ip)) })
        [IO.File]::AppendAllText((Join-Path $poolDir 'rotation-history.jsonl'), $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
      } catch { }
      Write-Event 'swap' @{ instance = $Instance; from = $from; to = $n; before = $oldIp; after = [string]$s.ip; lived = $lived }
      Write-Host ('swapped ' + $Instance + ' from slot ' + $from + ' to slot ' + $n + ' port ' + $s.port + ' ip ' + $s.ip)
      return $n
    } finally { $lk.Dispose() }
  }
  return 0
}
function Invoke-Rotate {
  Ensure-Dirs
  if ($Slot -le 0) { Write-Host 'rotate requires -Slot'; return 1 }
  if (-not (Test-Path -LiteralPath (SlotJsonPath $Slot))) { Write-Host ('slot ' + $Slot + ' not found'); return 3 }
  $swapped = 0
  $lk0 = Lock-Slot $Slot 10000
  if ($lk0) { try { $swapped = Invoke-SwapToSpare $Slot } finally { $lk0.Dispose() } }
  if ($swapped -gt 0) {
    $slots = @(Get-AllSlots)
    Write-PoolStatus $slots
    Show-Table $slots
    return 0
  }
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
      if ($seen.ContainsKey((UniqKey ([string]$s.ip)))) {
        $s.health = 'degraded'
        Save-Slot $s
        $bad = $true
        Write-Host ('slot ' + $s.slot + ': duplicate ip ' + $s.ip)
      } else { $seen[(UniqKey ([string]$s.ip))] = [int]$s.slot }
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
# Plan: two slots with the same IP -> the newer one gets a new identity. v1.0 only marked it
# 'degraded' (claim then skipped it forever). The lowest slot keeps its IP; an owned duplicate is
# rotated too, since sharing an IP with another instance is what the pool exists to prevent.
function Invoke-DaemonDedupe {
  $byIp = @{}
  foreach ($s in @(Get-AllSlots | Sort-Object slot)) {
    if ($Count -ge 1 -and [int]$s.slot -gt $Count) { continue }
    if ($s.health -notin @('up', 'degraded') -or -not $s.ip) { continue }
    if (-not (Test-SlotProcess $s)) { continue }
    $key = UniqKey ([string]$s.ip)
    if (-not $byIp.ContainsKey($key)) { $byIp[$key] = @() }
    $byIp[$key] += [int]$s.slot
  }
  $rotated = @()
  foreach ($ip in @($byIp.Keys)) {
    $nums = @($byIp[$ip] | Sort-Object)
    if ($nums.Count -le 1) { continue }
    foreach ($n in @($nums | Select-Object -Skip 1)) {
      if (Test-Path -LiteralPath $stopFlag) { return }
      $lk = Lock-Slot $n 2000
      if (-not $lk) { continue }
      try {
        Write-Event 'collision' @{ slot = $n; ip = $ip; keeps = [int]$nums[0] }
        $r = Rotate-Slot $n -ForceIdentity -MaxIdentity 1 -WaitSec 25
        $rotated += $n
        if (-not $r.ok) { Write-Event 'dedupe-failed' @{ slot = $n; ip = $ip } }
      } catch {
        Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message }
      } finally { $lk.Dispose() }
    }
  }
  if ($FamilyDedupe -ne 1) { return }
  # Same family, different IP (v1.4): only a FREE duplicate moves (an instance in use keeps its
  # exit), with a reconnect first (no new registration) and the 10 min per-slot cooldown.
  $byFam = @{}
  foreach ($s in @(Get-AllSlots | Sort-Object slot)) {
    if ($Count -ge 1 -and [int]$s.slot -gt $Count) { continue }
    if ($s.health -ne 'up' -or -not $s.ip -or $rotated -contains [int]$s.slot) { continue }
    $key = DedupeKey ([string]$s.ip)
    if (-not $byFam.ContainsKey($key)) { $byFam[$key] = @() }
    $byFam[$key] += $s
  }
  foreach ($fam in @($byFam.Keys)) {
    $group = @($byFam[$fam])
    if ($group.Count -le 1) { continue }
    # Keep an owned slot (or the lowest); move the free others.
    $keep = @($group | Where-Object { Test-SlotInUse $_ } | Select-Object -First 1)
    if (-not $keep) { $keep = @($group | Select-Object -First 1) }
    foreach ($s in $group) {
      $n = [int]$s.slot
      if ($n -eq [int]$keep[0].slot) { continue }
      if (Test-SlotInUse $s) { continue }
      if (-not (Test-SelfRotateDue $n)) { continue }
      if (Test-Path -LiteralPath $stopFlag) { return }
      $lk = Lock-Slot $n 2000
      if (-not $lk) { continue }
      try {
        Write-Event 'family-collision' @{ slot = $n; family = $fam; keeps = [int]$keep[0].slot }
        $r = Rotate-Slot $n -MaxIdentity 1 -WaitSec 20 -AvoidFamilies @(@($byFam.Keys) | Where-Object { $_ })
        if (-not $r.ok) { Write-Event 'family-dedupe-failed' @{ slot = $n; family = $fam } }
      } catch {
        Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message }
      } finally { $lk.Dispose() }
    }
  }
}
# v1.4: a FREE slot whose exit is in a burned family is rotated to a working family before a
# window claims it. Measured 27/11: after a reboot all 4 slots came back on burned families
# (36a8::39c, 243c::39c), so the first window was going to hit the limit in seconds.
function Invoke-ReplaceBurned {
  foreach ($s in @(Get-AllSlots | Sort-Object slot)) {
    if (Test-Path -LiteralPath $stopFlag) { return }
    $n = [int]$s.slot
    if ($Count -ge 1 -and $n -gt $Count) { continue }
    if ($s.health -ne 'up' -or -not $s.ip) { continue }
    if (Test-SlotInUse $s) { continue }
    $selfBurned = (@(Get-BurnedIps $s) -contains [string]$s.ip)
    if (-not $selfBurned -and -not (Test-FamilyBad ([string]$s.ip))) { continue }
    # A slot left behind by a swap (its exit in its own burned[]) is due at once (no earlier try);
    # a failed rotation keeps the stale exit, so the 10 min cooldown applies to both cases.
    if (-not (Test-SelfRotateDue $n)) { continue }
    $lk = Lock-Slot $n 2000
    if (-not $lk) { continue }
    try {
      $fam = Get-Family ([string]$s.ip)
      Write-Event 'burned-replace' @{ slot = $n; ip = [string]$s.ip; family = $fam }
      $taken = @(Get-AllSlots | Where-Object { [int]$_.slot -ne $n -and $_.health -eq 'up' -and $_.ip } | ForEach-Object { DedupeKey ([string]$_.ip) })
      $r = Rotate-Slot $n -MaxIdentity 2 -WaitSec 20 -AvoidFamilies $taken
      if (-not $r.ok) { Write-Event 'burned-replace-failed' @{ slot = $n; family = $fam } }
    } catch {
      Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message }
    } finally { $lk.Dispose() }
  }
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
    Write-Event 'daemon-start' @{ pid = $PID; healthSec = $HealthSec; version = $ScriptVersion }
    # v1.9: INICIAR.bat copies a new warp-pool.ps1 over this one; a daemon started earlier kept the old
    # code until a reboot (27/11: the 1.3 daemon never replaced the burned slots). It now notices and
    # starts the new one after releasing its lock.
    $selfStamp = $null
    try { $selfStamp = (Get-Item -LiteralPath $SelfPath).LastWriteTimeUtc } catch { }
    $interval = [Math]::Max(5, $HealthSec)
    $fails = @{}
    while (-not (Test-Path -LiteralPath $stopFlag)) {
      # 'grow' raises the persisted count while the daemon runs: follow it, so a slot added for a
      # fifth window is watched like the others.
      $pc = Read-Json $poolConfigFile
      if ($pc -and $pc.PSObject.Properties['count']) { try { if ([int]$pc.count -ge 1) { $Count = [int]$pc.count } } catch { } }
      # Owner-gone claims are freed first (see Invoke-Reap: a live owner is never reaped).
      Invoke-Reap | Out-Null
      foreach ($n in @(Get-SlotNumbers)) {
        if (Test-Path -LiteralPath $stopFlag) { break }
        # Slots past the configured count (left by an earlier, larger 'up') are not resurrected.
        if ($Count -ge 1 -and $n -gt $Count) { continue }
        # Same slot lock as claim/rotate: a rotate in progress is never raced by a restart.
        $lk = Lock-Slot $n 2000
        if (-not $lk) { continue }
        try {
          $s = Get-Slot $n
          $m = Measure-Slot $s 8
          if ($m.ok) {
            # Measured: the WARP IPv6 exit of a live tunnel moves by itself (same process, new IP
            # after a rekey). The claim and egress.json follow it so they never show a stale exit.
            $drift = ($s.ip -and [string]$s.ip -ne [string]$m.trace.ip)
            if ($drift) { Write-Event 'ip-drift' @{ slot = $n; before = [string]$s.ip; after = [string]$m.trace.ip } }
            $s.ip = [string]$m.trace.ip
            $s.colo = [string]$m.trace.colo
            $s.warp = [string]$m.trace.warp
            $s.health = 'up'
            $s.verifiedAt = (Get-Date).ToString('o')
            Save-Slot $s
            if ($drift) { Refresh-ClaimIp $n }
            $fails[$n] = 0
            continue
          }
          $alive = Test-SlotProcess $s
          # Confirm at once instead of waiting a whole HealthSec: a stalled slot left the instance
          # using it hanging for up to two cycles (~1 min) before the rebuild, then ECONNRESET.
          if ($alive -and $m.reason -eq 'no trace') {
            Start-Sleep -Seconds 3
            $m2 = Measure-Slot $s 8
            if ($m2.ok) {
              $s.ip = [string]$m2.trace.ip; $s.colo = [string]$m2.trace.colo; $s.warp = [string]$m2.trace.warp
              $s.health = 'up'; $s.verifiedAt = (Get-Date).ToString('o'); Save-Slot $s
              $fails[$n] = 0
              continue
            }
            $m = $m2
            $fails[$n] = [int]$fails[$n] + 1
          }
          $fails[$n] = [int]$fails[$n] + 1
          # A restart gives the slot a new exit IP under whoever is using it, so one lost trace on a
          # live tunnel only marks it degraded; the second consecutive failure rebuilds it. The
          # rebuild is what clears a stalled UDP path (handshake sent, never answered): wireproxy
          # keeps retrying from the same source port forever, a new process gets a new one.
          $hard = (-not $alive) -or ($m.reason -eq 'warp off') -or ($m.reason -eq 'port closed') -or ($m.reason -eq 'ipv4 egress')
          if (-not $hard -and $fails[$n] -lt 2) {
            $s.health = 'degraded'
            Save-Slot $s
            continue
          }
          # Backoff: after 4 failed cycles only every 4th cycle retries, so a broken network or a
          # refused registration does not hammer the Cloudflare API every HealthSec.
          if ($fails[$n] -gt 4 -and ($fails[$n] % 4) -ne 0) {
            $s.health = $(if ($alive) { 'degraded' } else { 'down' })
            Save-Slot $s
            continue
          }
          Write-Event 'daemon-restart' @{ slot = $n; reason = $m.reason; fails = [int]$fails[$n] }
          # Rebuilt on the next WARP endpoint: the stalled one is not answering this identity.
          # v1.9.1: a rebuild avoids burned families too (27/11 09:57: a rebuilt free slot came back on
          # 36a8::39c). If only a burned exit answers, the slot still comes back (a stale exit beats a
          # dead port) and Invoke-ReplaceBurned moves it later.
          $r = Start-Slot $n -WaitSec 30 -NextEndpoint -AvoidBadFamily
          if (-not $r.ok -and $r.reason -eq 'burned family') { $r = Start-Slot $n -WaitSec 30 -NextEndpoint }
          # The same identity keeps failing: a fresh wgcf device (a manual .conf in WgDir still wins).
          if (-not $r.ok -and ($fails[$n] % 4) -eq 0) {
            Write-Event 'daemon-new-identity' @{ slot = $n; reason = $r.reason }
            $r = Start-Slot $n -NewIdentity -NextEndpoint -WaitSec 30 -AvoidBadFamily
            if (-not $r.ok -and $r.reason -eq 'burned family') { $r = Start-Slot $n -NewIdentity -NextEndpoint -WaitSec 30 }
          }
          if ($r.ok) { $fails[$n] = 0; Refresh-ClaimIp $n }
          else { Write-Event 'daemon-restart-failed' @{ slot = $n; reason = $r.reason } }
        } catch {
          Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message }
        } finally { $lk.Dispose() }
      }
      Invoke-ReplaceBurned
      Invoke-DaemonDedupe
      $slots = @(Get-AllSlots)
      Update-Uniqueness $slots
      $slots = @(Get-AllSlots)
      Write-PoolStatus $slots
      try { Write-Dashboard | Out-Null } catch { Write-Event 'dashboard-error' @{ error = $_.Exception.Message } }
      Limit-PoolLogs
      $end = (Get-Date).AddSeconds($interval)
      while ((Get-Date) -lt $end -and -not (Test-Path -LiteralPath $stopFlag)) { Start-Sleep -Seconds 1 }
      if ($selfStamp) {
        $nowStamp = $null
        try { $nowStamp = (Get-Item -LiteralPath $SelfPath).LastWriteTimeUtc } catch { }
        if ($nowStamp -and $nowStamp -ne $selfStamp) { $script:daemonReload = $true; Write-Event 'daemon-reload' @{ pid = $PID; from = $ScriptVersion }; break }
      }
    }
    Write-Event 'daemon-stop' @{ pid = $PID }
    return 0
  } finally {
    if ($lock) { try { $lock.Dispose() } catch { } }
    if ($script:daemonReload) {
      # The lock is free now: the new copy of the script takes over as the daemon.
      try { Ensure-Detached; $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $null = [OpenInfinite.Detached]::Start($ps, ('-NoProfile -ExecutionPolicy Bypass -File "' + $SelfPath + '" -Action daemon -State "' + $State + '" -HealthSec ' + $HealthSec), $State) } catch { Write-Event 'daemon-reload-failed' @{ error = $_.Exception.Message } }
    }
  }
}
function Invoke-Reap {
  Ensure-Dirs
  # Plan: reap frees a slot whose owner died. Since v1.1 a claim names its owner as a long-lived
  # process (launcher window cmd.exe or the dispatcher) by pid + start ticks:
  #   owner alive  -> never reaped, however old the claim is;
  #   owner gone   -> reaped now;
  #   owner unknown (claim from v1.0, owner = the short-lived claim PowerShell) -> lease rule:
  #   'renewedAt' (or 'at') older than LeaseMin minutes.
  # v1.0 reaped on 'at' alone, and 'at' is kept on re-claim, so every live claim was dropped
  # after LeaseMin minutes and a second window could take the same slot and the same IP.
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
    $reason = 'lease'
    $alive = $null
    if ($c.PSObject.Properties['owner']) { $alive = Test-OwnerAlive $c.owner }
    if ($alive -eq $true) { continue }
    if ($alive -eq $false) { $expired = $true; $reason = 'owner-gone' }
    elseif ($LeaseMin -gt 0) {
      $stamp = [string]$c.at
      if ($c.PSObject.Properties['renewedAt'] -and $c.renewedAt) { $stamp = [string]$c.renewedAt }
      if ($stamp) { try { if (($now - [DateTime]::Parse($stamp)).TotalMinutes -gt $LeaseMin) { $expired = $true } } catch { } }
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
      if ($c.instance) { Remove-Item -LiteralPath (Instance-EgressPath ([string]$c.instance)) -Force -ErrorAction SilentlyContinue }
      $released++
      Write-Event 'reap' @{ instance = [string]$c.instance; slot = $n; reason = $reason }
    }
  }
  foreach ($n in @(Get-SlotNumbers)) {
    if ($handled.ContainsKey($n)) { continue }
    $s = Get-Slot $n
    if (-not $s.owner -or -not $s.owner.instance) { continue }
    # Owner recorded on the slot but no claim file: same rule, owner process first.
    $alive = Test-OwnerAlive $s.owner
    if ($alive -eq $true) { continue }
    $expired = ($alive -eq $false)
    if ($null -eq $alive -and $LeaseMin -gt 0) {
      $stamp = [string]$s.owner.at
      if ($s.owner.PSObject.Properties['renewedAt'] -and $s.owner.renewedAt) { $stamp = [string]$s.owner.renewedAt }
      if ($stamp) { try { if (($now - [DateTime]::Parse($stamp)).TotalMinutes -gt $LeaseMin) { $expired = $true } } catch { } }
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

# Plan item 2: every slot is taken -> one more slot, up to WPOOL_MAX. Shares the 'up' lock, so it
# never races a boot. Exit 0 = the new slot is up, 8 = already at WPOOL_MAX, 3 = it did not come up.
function Invoke-Grow {
  Ensure-Dirs
  $upLock = Lock-Pool 'up' 120000
  if (-not $upLock) { Write-Host 'pool is busy (up running)'; return 4 }
  try {
    $n = [int]$Count + 1
    if ($n -gt $Max) { Write-Host ('pool is at WPOOL_MAX (' + $Max + ')'); Write-Event 'grow-refused' @{ count = [int]$Count; max = $Max }; return 8 }
    if (($PortBase + $n) -gt 65535) { Write-Host 'bad PortBase/Count'; return 1 }
    $Count = $n
    Write-Json $poolConfigFile ([ordered]@{ portBase = [int]$PortBase; count = [int]$Count; writtenAt = (Get-Date).ToString('o') })
    Ensure-Bins | Out-Null
    $ok = $false
    $lk = Lock-Slot $n 30000
    if ($lk) {
      try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
          $r = Start-Slot $n -NewIdentity:($attempt -ge 3) -NextEndpoint:($attempt -ge 2) -WaitSec 25
          if ($r.ok) { $ok = $true; break }
        }
      } finally { $lk.Dispose() }
    }
    Write-Event 'grow' @{ slot = $n; ok = $ok; max = $Max }
    $slots = @(Get-AllSlots)
    Update-Uniqueness $slots
    Write-PoolStatus @(Get-AllSlots)
    Write-Host ('slot ' + $n + $(if ($ok) { ' added' } else { ' did not come up' }))
    if ($ok) { return 0 }
    return 3
  } finally { $upLock.Dispose() }
}
# Plan item 3: what the launcher used to run inline in its own console. Holds startup.lock, runs
# 'up', writes pool\up.rc for the waiting window, then becomes the daemon. Started by 'spawn',
# so it outlives the window that booted the pool.
function Invoke-Boot {
  Ensure-Dirs
  $h = $null
  try { $h = [IO.File]::Open((Join-Path $poolDir 'startup.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { Write-Host 'another boot is running'; return 0 }
  try {
    $rc = 1
    try { $res = @(Invoke-Up); $rc = [int]$res[-1] } catch { $rc = 1; Write-Event 'error' @{ action = 'boot-up'; error = $_.Exception.Message } }
    try { [IO.File]::WriteAllText((Join-Path $poolDir 'up.rc'), [string]$rc) } catch { }
    if (@(0, 2, 3) -contains $rc) { return (Invoke-Daemon) }
    return $rc
  } finally { if ($h) { $h.Dispose() } }
}
# Starts 'boot' or 'daemon' as a detached process (no console, no inherited handles, out of the
# caller's job) and returns at once.
function Invoke-Spawn {
  Ensure-Dirs
  Ensure-Detached
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $SelfPath + '" -Action ' + $Then + ' -State "' + $State + '" -HealthSec ' + $HealthSec
  if ($Then -eq 'boot') {
    $a += ' -Count ' + $Count + ' -PortBase ' + $PortBase + ' -DedupeTries ' + $DedupeTries + ' -LeaseMin ' + $LeaseMin + ' -BurnedTtlHours ' + $BurnedTtlHours
  }
  if ($Force) { $a += ' -Force' }
  if ($AllowWarpTunnel) { $a += ' -AllowWarpTunnel' }
  $newPid = [OpenInfinite.Detached]::Start($ps, $a, $State)
  Write-Event 'spawn' @{ then = $Then; pid = $newPid }
  Write-Host ('spawned ' + $Then + ' pid ' + $newPid)
  return 0
}
# Plan item 6: is the free limit per IP or per range? Reads pool\rotation-history.jsonl.
function Invoke-Stats {
  Ensure-Dirs
  $hist = Join-Path $poolDir 'rotation-history.jsonl'
  if (-not (Test-Path -LiteralPath $hist)) { New-Item -ItemType File -Force -Path $hist | Out-Null }
  $rows = @(Get-Content -LiteralPath $hist -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
  # v1.8: the tunnels as they are now, with their family, its score and whether it is burned.
  $fams0 = Read-Families
  $now0 = @(Get-AllSlots | Sort-Object slot | ForEach-Object {
    $ip = [string]$_.ip
    $own = '-'; if ($_.owner -and $_.owner.instance) { $own = [string]$_.owner.instance }
    [pscustomobject]@{
      Slot = [int]$_.slot; Port = [int]$_.port; IP = $(if ($ip) { $ip } else { '-' }); Family = (Get-Family $ip)
      Score = $(if ($ip) { Get-FamilyScore $ip $fams0 } else { '' }); Burned = [bool]($ip -and (Test-FamilyBad $ip)); Health = [string]$_.health; Owner = $own
    }
  })
  if ($now0.Count) {
    Write-Host 'tunnels now (family = h1:h2:*:h4::suffix; score: +1 per exit that lasted, -1 per quick limit, newest counts twice):'
    $now0 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  }
  $quick = 180
  $byPrefix = @($rows | Where-Object { $_.beforePrefix } | Group-Object beforePrefix | ForEach-Object {
    $lived = @($_.Group | Where-Object { [int]$_.livedSec -ge 0 } | ForEach-Object { [int]$_.livedSec } | Sort-Object)
    $med = -1; if ($lived.Count) { $med = $lived[[int][Math]::Floor($lived.Count / 2)] }
    [pscustomobject]@{ Prefix = $_.Name; Rotations = $_.Count; QuickRepeats = @($lived | Where-Object { $_ -lt $quick }).Count; MedianLivedSec = $med }
  } | Sort-Object Rotations -Descending)
  Write-Host ('rotations recorded: ' + $rows.Count + '   distinct /64 left: ' + $byPrefix.Count)
  $byPrefix | Select-Object -First 15 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  $quickTotal = @($rows | Where-Object { [int]$_.livedSec -ge 0 -and [int]$_.livedSec -lt $quick }).Count
  $sharedQuick = @($byPrefix | Where-Object { $_.QuickRepeats -ge 2 }).Count
  Write-Host ('exits left within ' + $quick + ' s: ' + $quickTotal + '   /64 with 2+ quick repeats: ' + $sharedQuick)
  if ($sharedQuick -ge 2 -and $DedupePrefix -ne 64 -and $FamilyDedupe -ne 1) { Write-Host 'hint: the limit seems to follow the /64; try WPOOL_DEDUPE_PREFIX=64' }
  $fams = Read-Families
  if ($fams.Count) {
    Write-Host ''
    Write-Host ('exit families (quick = limit back within ' + $FamQuickSec + ' s, good = lasted ' + $FamGoodSec + ' s+, last ' + $BurnedTtlHours + ' h; burned = 2+ quick and the last two were quick):')
    $frows = foreach ($k in @($fams.Keys | Sort-Object)) {
      $c = Get-FamilyCounts $k $fams
      [pscustomobject]@{ Family = $k; Quick = $c.quick; Good = $c.good; Burned = [bool]$c.burned }
    }
    $frows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  }
  return 0
}

# ---- dashboard (v1.6) ---------------------------------------------------------------------------
# pool\dashboard.html: one self-contained page with the tunnels, the IP families and the latest
# rotations, swaps and events. 'dashboard' writes it and opens it; the daemon rewrites it every
# cycle, and the page reloads itself every 30 s, so an open tab stays current.
function HtmlEnc([string]$s) { return [Net.WebUtility]::HtmlEncode([string]$s) }
function Fmt-Ago($when) {
  if (-not $when) { return '-' }
  try { $d = (Get-Date) - [DateTime]::Parse([string]$when) } catch { return '-' }
  if ($d.TotalSeconds -lt 90) { return ([int]$d.TotalSeconds).ToString() + ' s' }
  if ($d.TotalMinutes -lt 90) { return ([int]$d.TotalMinutes).ToString() + ' min' }
  if ($d.TotalHours -lt 48) { return ([int]$d.TotalHours).ToString() + ' h' }
  return ([int]$d.TotalDays).ToString() + ' d'
}
function Fmt-Sec([int]$s) {
  if ($s -lt 0) { return '-' }
  if ($s -lt 120) { return $s.ToString() + ' s' }
  return ([Math]::Round($s / 60.0, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) + ' min'
}
function Read-JsonLines([string]$path, [int]$last) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  $lines = @()
  try { $lines = @(Get-Content -LiteralPath $path -Tail $last -Encoding UTF8) } catch { return @() }
  return @($lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
}
function Kpi([string]$label, [string]$value, [string]$tag) {
  return '<div class="kpi ' + $tag + '"><div class="v">' + (HtmlEnc $value) + '</div><div class="l">' + (HtmlEnc $label) + '</div></div>'
}
# v1.8: how long each exit lasted, as two inline SVG charts (no script, no library):
# a timeline of every rotation of the last 7 days (y = minutes the old IP lasted, sqrt scale,
# capped at 40 min; red = limit back in under 2 min, green = lasted 5 min+) and the median
# lifetime per family. Colors come from the page tokens, so dark mode follows.
function Get-LifetimeCharts {
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $rows = @(Read-JsonLines (Join-Path $poolDir 'rotation-history.jsonl') 600)
  $now = Get-Date
  $pts = @()
  foreach ($h in $rows) {
    $lv = -1; try { $lv = [int]$h.livedSec } catch { }
    if ($lv -lt 0) { continue }
    $at = $null; try { $at = [DateTime]::Parse([string]$h.at) } catch { continue }
    if (($now - $at).TotalDays -gt 7) { continue }
    $pts += [pscustomobject]@{ at = $at; lv = $lv; fam = (Get-Family ([string]$h.before)); swap = [bool]($h.PSObject.Properties['swap'] -and $h.swap) }
  }
  if (-not $pts.Count) { return '<div class="card pad sub">Sem trocas nos &uacute;ltimos 7 dias.</div>' }
  # Timeline
  $W = 640; $H = 220; $L = 44; $R = 12; $T = 12; $B = 28
  $t0 = ($pts | Measure-Object -Property at -Minimum).Minimum
  $t1 = $now
  $span = [Math]::Max(1.0, ($t1 - $t0).TotalSeconds)
  $capMin = 40.0
  function Y([double]$min) { $v = [Math]::Sqrt([Math]::Min($capMin, [Math]::Max(0, $min)) / $capMin); return $T + ($H - $T - $B) * (1 - $v) }
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('<svg viewBox="0 0 ' + $W + ' ' + $H + '" role="img" aria-label="Dura&ccedil;&atilde;o de cada IP nos &uacute;ltimos 7 dias">')
  foreach ($m in @(0, 2, 5, 10, 20, 40)) {
    $y = (Y $m).ToString('0.#', $inv)
    $cls = $(if ($m -eq 2 -or $m -eq 5) { 'gl ref' } else { 'gl' })
    [void]$sb.Append('<line class="' + $cls + '" x1="' + $L + '" x2="' + ($W - $R) + '" y1="' + $y + '" y2="' + $y + '"/><text class="ax" x="' + ($L - 6) + '" y="' + $y + '" dy="3" text-anchor="end">' + $m + ' min</text>')
  }
  # x labels: start, middle, now
  foreach ($f in @(0.0, 0.5, 1.0)) {
    $tt = $t0.AddSeconds($span * $f)
    $x = ($L + ($W - $L - $R) * $f).ToString('0.#', $inv)
    $anchor = $(if ($f -eq 0) { 'start' } elseif ($f -eq 1) { 'end' } else { 'middle' })
    [void]$sb.Append('<text class="ax" x="' + $x + '" y="' + ($H - 8) + '" text-anchor="' + $anchor + '">' + $tt.ToString('dd/MM HH:mm') + '</text>')
  }
  foreach ($p in $pts) {
    $x = ($L + ($W - $L - $R) * (($p.at - $t0).TotalSeconds / $span)).ToString('0.#', $inv)
    $y = (Y ($p.lv / 60.0)).ToString('0.#', $inv)
    $cls = $(if ($p.lv -lt $FamQuickSec) { 'pt bad' } elseif ($p.lv -ge $FamGoodSec) { 'pt ok' } else { 'pt warn' })
    $shape = $(if ($p.swap) { '<rect class="' + $cls + '" x="' + ([double]$x - 4).ToString('0.#', $inv) + '" y="' + ([double]$y - 4).ToString('0.#', $inv) + '" width="8" height="8">' } else { '<circle class="' + $cls + '" cx="' + $x + '" cy="' + $y + '" r="4">' })
    $end = $(if ($p.swap) { '</rect>' } else { '</circle>' })
    [void]$sb.Append($shape + '<title>' + (HtmlEnc ($p.at.ToString('dd/MM HH:mm') + ' - ' + $p.fam + ' - durou ' + (Fmt-Sec $p.lv) + $(if ($p.swap) { ' (troca instantanea)' } else { '' }))) + '</title>' + $end)
  }
  [void]$sb.Append('</svg>')
  $timeline = $sb.ToString()
  # Median per family (top 8 by number of rotations)
  $groups = @($pts | Group-Object fam | Sort-Object Count -Descending | Select-Object -First 8)
  $bw = 640; $rowH = 24; $bl = 190; $bh = $rowH * $groups.Count + 8
  $sb2 = New-Object Text.StringBuilder
  [void]$sb2.Append('<svg viewBox="0 0 ' + $bw + ' ' + $bh + '" role="img" aria-label="Dura&ccedil;&atilde;o mediana por fam&iacute;lia">')
  $i = 0
  foreach ($g in $groups) {
    $vals = @($g.Group | ForEach-Object { $_.lv } | Sort-Object)
    $med = $vals[[int][Math]::Floor($vals.Count / 2)]
    $frac = [Math]::Sqrt([Math]::Min($capMin, $med / 60.0) / $capMin)
    $w = [Math]::Max(2, ($bw - $bl - 90) * $frac)
    $y = 4 + $i * $rowH
    $cls = $(if ($med -lt $FamQuickSec) { 'bar bad' } elseif ($med -ge $FamGoodSec) { 'bar ok' } else { 'bar warn' })
    [void]$sb2.Append('<text class="lab" x="' + ($bl - 8) + '" y="' + ($y + 15) + '" text-anchor="end">' + (HtmlEnc $g.Name) + '</text>')
    [void]$sb2.Append('<rect class="' + $cls + '" x="' + $bl + '" y="' + ($y + 4) + '" width="' + $w.ToString('0.#', $inv) + '" height="14" rx="3"><title>' + (HtmlEnc ($g.Name + ': mediana ' + (Fmt-Sec $med) + ' em ' + $vals.Count + ' trocas')) + '</title></rect>')
    [void]$sb2.Append('<text class="val" x="' + ($bl + $w + 6).ToString('0.#', $inv) + '" y="' + ($y + 15) + '">' + (Fmt-Sec $med) + ' &middot; ' + $vals.Count + 'x</text>')
    $i++
  }
  [void]$sb2.Append('</svg>')
  $legend = '<div class="legend"><span><i class="dot bad"></i>voltou ao limite em menos de 2 min</span><span><i class="dot warn"></i>2 a 5 min</span><span><i class="dot ok"></i>durou 5 min ou mais</span><span><i class="sq"></i>troca instant&acirc;nea</span></div>'
  return '<div class="charts"><div class="card pad"><div class="ct">Cada troca dos &uacute;ltimos 7 dias (quanto o IP antigo durou)</div>' + $timeline + $legend + '</div><div class="card pad"><div class="ct">Dura&ccedil;&atilde;o mediana por fam&iacute;lia (&uacute;ltimos 7 dias)</div>' + $sb2.ToString() + '</div></div>'
}
function Write-Dashboard {
  $fams = Read-Families
  $slots = @(Get-AllSlots | Sort-Object slot)
  $now = Get-Date
  # Tunnels
  $rowsS = New-Object Text.StringBuilder
  $famsUp = @{}
  foreach ($s in $slots) {
    $ip = [string]$s.ip
    $fam = Get-Family $ip
    $bad = ($ip -and (Test-FamilyBad $ip))
    $selfB = ($ip -and @(Get-BurnedIps $s) -contains $ip)
    $score = ''
    if ($ip) { $score = [string](Get-FamilyScore $ip $fams) }
    $owner = '-'
    if ($s.owner -and $s.owner.instance) {
      $owner = [string]$s.owner.instance
      if ((Test-OwnerAlive $s.owner) -eq $false) { $owner += ' (fechada)' }
    }
    if ($s.health -eq 'up' -and $fam) { $famsUp[$fam] = 1 }
    $tag = 'ok'; $stateLbl = 'boa'
    if ($s.health -ne 'up') { $tag = 'down'; $stateLbl = [string]$s.health }
    elseif ($bad) { $tag = 'bad'; $stateLbl = 'queimada' }
    elseif ($selfB) { $tag = 'warn'; $stateLbl = 'IP recem-queimado' }
    $since = '-'
    if ($s.PSObject.Properties['ipSince'] -and $s.ipSince) { $since = Fmt-Ago $s.ipSince }
    [void]$rowsS.Append('<tr><td class="n">' + $s.slot + '</td><td class="n">' + $s.port + '</td><td class="mono">' + (HtmlEnc $ip) + '</td><td class="mono">' + (HtmlEnc $fam) + '</td><td class="n">' + $score + '</td><td><span class="pill ' + $tag + '">' + (HtmlEnc $stateLbl) + '</span></td><td>' + (HtmlEnc $owner) + '</td><td>' + (HtmlEnc ([string]$s.colo)) + '</td><td class="n">' + $since + '</td><td class="n">' + (Fmt-Ago $s.verifiedAt) + '</td></tr>')
  }
  # Families, best first
  $famRows = @()
  foreach ($k in @($fams.Keys)) {
    $c = Get-FamilyCounts $k $fams
    $o = @(Get-FamilyOutcomes $k $fams)
    $score = 0
    foreach ($x in $o) { if ($x.k -eq 'good') { $score++ } else { $score-- } }
    if ($o.Count) { if ($o[-1].k -eq 'good') { $score++ } else { $score-- } }
    $lastT = ''
    if ($o.Count) { $lastT = $o[-1].t.ToString('o') }
    $famRows += [pscustomobject]@{ f = $k; q = $c.quick; g = $c.good; b = [bool]$c.burned; score = $score; last = $lastT; inUse = $famsUp.ContainsKey($k) }
  }
  $rowsF = New-Object Text.StringBuilder
  foreach ($r in @($famRows | Sort-Object @{ Expression = 'score'; Descending = $true }, f)) {
    $tag = 'warn'; $lbl = 'incerta'
    if ($r.b) { $tag = 'bad'; $lbl = 'queimada' } elseif ($r.score -gt 0) { $tag = 'ok'; $lbl = 'boa' }
    $use = ''
    if ($r.inUse) { $use = 'sim' }
    [void]$rowsF.Append('<tr><td class="mono">' + (HtmlEnc $r.f) + '</td><td class="n">' + $r.score + '</td><td class="n">' + $r.g + '</td><td class="n">' + $r.q + '</td><td><span class="pill ' + $tag + '">' + $lbl + '</span></td><td>' + $use + '</td><td class="n">' + (Fmt-Ago $r.last) + '</td></tr>')
  }
  # Rotations, newest first
  $hist = @(Read-JsonLines (Join-Path $poolDir 'rotation-history.jsonl') 40)
  [array]::Reverse($hist)
  $rowsR = New-Object Text.StringBuilder
  $lived24 = @(); $swaps24 = 0; $quick24 = 0
  foreach ($h in $hist) {
    $age = 999999
    try { $age = ($now - [DateTime]::Parse([string]$h.at)).TotalHours } catch { }
    $lv = -1
    try { $lv = [int]$h.livedSec } catch { }
    $isSwap = [bool]($h.PSObject.Properties['swap'] -and $h.swap)
    if ($age -lt 24) {
      if ($lv -ge 0) { $lived24 += $lv; if ($lv -lt $FamQuickSec) { $quick24++ } }
      if ($isSwap) { $swaps24++ }
    }
    $how = 'troca no proprio tunel'
    if ($isSwap) { $how = 'troca instantanea para o slot ' + $h.swap }
    $tag = 'warn'
    if ($lv -ge 0 -and $lv -lt $FamQuickSec) { $tag = 'bad' } elseif ($lv -ge $FamGoodSec) { $tag = 'ok' }
    [void]$rowsR.Append('<tr><td class="n">' + (Fmt-Ago $h.at) + '</td><td class="n">' + $h.slot + '</td><td class="mono">' + (HtmlEnc (Get-Family ([string]$h.before))) + '</td><td class="mono">' + (HtmlEnc (Get-Family ([string]$h.after))) + '</td><td class="n"><span class="pill ' + $tag + '">' + (Fmt-Sec $lv) + '</span></td><td>' + (HtmlEnc ([string]$h.reason)) + '</td><td>' + $how + '</td></tr>')
  }
  # Events worth seeing
  $want = @('swap', 'burned-replace', 'burned-replace-failed', 'family-collision', 'family-dedupe-failed', 'family-burned', 'exit-refused', 'rotate', 'rotate-failed', 'daemon-restart', 'daemon-restart-failed', 'claim', 'release', 'reap', 'families-seeded', 'daemon-start')
  $ev = @(Read-JsonLines $eventsFile 400 | Where-Object { $want -contains [string]$_.type } | Select-Object -Last 30)
  [array]::Reverse($ev)
  $rowsE = New-Object Text.StringBuilder
  foreach ($e in $ev) {
    $d = ''
    if ($e.data) { $d = (@($e.data.PSObject.Properties | ForEach-Object { $_.Name + '=' + [string]$_.Value }) -join '  ') }
    [void]$rowsE.Append('<tr><td class="n">' + (Fmt-Ago $e.timestamp) + '</td><td>' + (HtmlEnc ([string]$e.type)) + '</td><td class="mono small">' + (HtmlEnc $d) + '</td></tr>')
  }
  # Summary
  $up = @($slots | Where-Object { $_.health -eq 'up' -and $_.ip })
  $burnedUp = @($up | Where-Object { Test-FamilyBad ([string]$_.ip) }).Count
  $med = '-'
  if ($lived24.Count) { $sorted = @($lived24 | Sort-Object); $med = Fmt-Sec ([int]$sorted[[int][Math]::Floor($sorted.Count / 2)]) }
  $daemonOn = $false
  try {
    $fs = [IO.File]::Open($daemonLock, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $fs.Dispose()
  } catch { $daemonOn = $true }
  if (-not (Test-Path -LiteralPath $daemonLock)) { $daemonOn = $false }
  $tUp = 'warn'; if ($up.Count -eq $slots.Count -and $slots.Count -gt 0) { $tUp = 'ok' }
  $tFam = 'warn'; if ($famsUp.Count -ge $up.Count) { $tFam = 'ok' }
  $tBurn = 'bad'; if ($burnedUp -eq 0) { $tBurn = 'ok' }
  $tQuick = 'warn'; if ($quick24 -eq 0) { $tQuick = 'ok' }
  $vD = 'parado'; $tD = 'bad'; if ($daemonOn) { $vD = 'rodando'; $tD = 'ok' }
  $k = (Kpi 'tuneis no ar' ($up.Count.ToString() + ' / ' + $slots.Count) $tUp) +
       (Kpi 'familias diferentes em uso' ($famsUp.Count.ToString()) $tFam) +
       (Kpi 'tuneis em familia queimada' ($burnedUp.ToString()) $tBurn) +
       (Kpi 'trocas instantaneas (24 h)' ($swaps24.ToString()) '') +
       (Kpi 'quedas rapidas (24 h)' ($quick24.ToString()) $tQuick) +
       (Kpi 'duracao mediana de um IP (24 h)' $med '') +
       (Kpi 'vigia' $vD $tD)
  $css = @'
:root{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--mut:#667085;--line:#e4e7ec;--ok:#0f7b4f;--okb:#e3f5ec;--bad:#b42318;--badb:#fde8e6;--warn:#9a6700;--warnb:#fdf3d7;--down:#475467;--downb:#eef0f3}
@media (prefers-color-scheme: dark){:root{--bg:#0f1218;--card:#171b23;--fg:#e6e9ef;--mut:#98a2b3;--line:#262c38;--ok:#4ade9b;--okb:#12301f;--bad:#ff8a80;--badb:#3a1614;--warn:#f5c451;--warnb:#33290e;--down:#a3acbb;--downb:#232833}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1200px;margin:0 auto;padding:20px 16px 40px}h1{font-size:20px;margin:0 0 2px}h2{font-size:15px;margin:26px 0 8px}
.sub{color:var(--mut);font-size:12.5px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:16px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}.kpi .v{font-size:22px;font-weight:650}.kpi .l{color:var(--mut);font-size:12px}
.kpi.ok .v{color:var(--ok)}.kpi.bad .v{color:var(--bad)}.kpi.warn .v{color:var(--warn)}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;overflow-x:auto}
table{border-collapse:collapse;width:100%}th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
th{font-size:12px;color:var(--mut);font-weight:600}tr:last-child td{border-bottom:0}td.n{text-align:right;font-variant-numeric:tabular-nums}
.mono{font-family:ui-monospace,Consolas,monospace;font-size:12.5px}.small{font-size:11.5px;white-space:normal;color:var(--mut)}
.pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;font-weight:600}
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px}.pad{padding:12px 14px}.ct{font-size:12.5px;color:var(--mut);margin-bottom:6px}svg{width:100%;height:auto;display:block}.gl{stroke:var(--line);stroke-width:1}.gl.ref{stroke-dasharray:3 3;stroke:var(--mut);opacity:.5}.ax,.lab,.val{fill:var(--mut);font-size:12px;font-family:system-ui,sans-serif}.lab{fill:var(--fg);font-family:ui-monospace,Consolas,monospace;font-size:12px}.pt{stroke:var(--card);stroke-width:1.5}.pt.ok,.bar.ok{fill:var(--ok)}.pt.bad,.bar.bad{fill:var(--bad)}.pt.warn,.bar.warn{fill:var(--warn)}.legend{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:12px;color:var(--mut);margin-top:6px}.legend span{display:inline-flex;align-items:center;gap:5px}.dot{display:inline-block;width:9px;height:9px;border-radius:50%}.dot.ok{background:var(--ok)}.dot.bad{background:var(--bad)}.dot.warn{background:var(--warn)}.sq{display:inline-block;width:9px;height:9px;background:var(--mut)}
.pill.ok{color:var(--ok);background:var(--okb)}.pill.bad{color:var(--bad);background:var(--badb)}.pill.warn{color:var(--warn);background:var(--warnb)}.pill.down{color:var(--down);background:var(--downb)}
'@
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="refresh" content="30"><title>Pool de tuneis</title><style>' + $css + '</style></head><body><main>')
  [void]$sb.Append('<h1>Pool de t&uacute;neis</h1><div class="sub">Atualizado ' + (HtmlEnc ($now.ToString('dd/MM/yyyy HH:mm:ss'))) + ' &middot; recarrega a cada 30 s (o vigia regrava a p&aacute;gina a cada ciclo) &middot; warp-pool ' + $ScriptVersion + ' &middot; fam&iacute;lia = h1:h2:*:h4::sufixo</div>')
  [void]$sb.Append('<div class="kpis">' + $k + '</div>')
  [void]$sb.Append('<h2>Quanto cada IP durou</h2>' + (Get-LifetimeCharts))
  [void]$sb.Append('<h2>T&uacute;neis</h2><div class="card"><table><tr><th>Slot</th><th>Porta</th><th>IP de sa&iacute;da</th><th>Fam&iacute;lia</th><th>Nota</th><th>Estado</th><th>Janela</th><th>Colo</th><th>IP h&aacute;</th><th>Checado h&aacute;</th></tr>' + $rowsS.ToString() + '</table></div>')
  [void]$sb.Append('<h2>Fam&iacute;lias de IP (&uacute;ltimas ' + $BurnedTtlHours + ' h, melhor primeiro)</h2><div class="card"><table><tr><th>Fam&iacute;lia</th><th>Nota</th><th>Duraram 5 min+</th><th>Ca&iacute;ram em menos de 2 min</th><th>Estado</th><th>Em uso</th><th>&Uacute;ltimo resultado</th></tr>' + $rowsF.ToString() + '</table></div>')
  [void]$sb.Append('<h2>&Uacute;ltimas trocas</h2><div class="card"><table><tr><th>H&aacute;</th><th>Slot</th><th>Fam&iacute;lia antes</th><th>Fam&iacute;lia depois</th><th>O IP antigo durou</th><th>Motivo</th><th>Como</th></tr>' + $rowsR.ToString() + '</table></div>')
  [void]$sb.Append('<h2>Eventos</h2><div class="card"><table><tr><th>H&aacute;</th><th>Evento</th><th>Detalhes</th></tr>' + $rowsE.ToString() + '</table></div>')
  [void]$sb.Append('</main></body></html>')
  $path = Join-Path $poolDir 'dashboard.html'
  [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
  return $path
}
function Invoke-Dashboard {
  Ensure-Dirs
  $p = Write-Dashboard
  Write-Host ('dashboard: ' + $p)
  if (-not $NoOpen) { try { Start-Process $p } catch { } }
  return 0
}

# ---- log limits and tidy (v1.7) -----------------------------------------------------------------
# recovery-events.jsonl and rotation-history.jsonl grew without bound (the launcher, the watcher and
# the pool all append to the first). Past MaxKB the oldest lines move to <file>.1 (one generation,
# overwritten) and the newest KeepLines stay, so 'stats', the dashboard and the family seeding
# still see recent history. Checked by the daemon once per cycle and by 'tidy'.
function Limit-LogFile([string]$path, [int]$maxKB, [int]$keepLines) {
  try {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    if ((Get-Item -LiteralPath $path).Length -le ($maxKB * 1024)) { return $false }
    $all = [IO.File]::ReadAllLines($path)
    if ($all.Count -le $keepLines) { return $false }
    $cut = $all.Count - $keepLines
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines($path + '.1', [string[]]($all[0..($cut - 1)]), $enc)
    [IO.File]::WriteAllLines($path, [string[]]($all[$cut..($all.Count - 1)]), $enc)
    Write-Event 'log-trimmed' @{ file = (Split-Path -Leaf $path); moved = $cut; kept = $keepLines }
    return $true
  } catch { return $false }
}
function Limit-PoolLogs {
  Limit-LogFile $eventsFile 2048 5000 | Out-Null
  Limit-LogFile (Join-Path $poolDir 'rotation-history.jsonl') 1024 3000 | Out-Null
}
function Get-DirBytes([string]$path) {
  try { return [long](@(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) } catch { return 0 }
}
function Fmt-Bytes([long]$b) {
  if ($b -ge 1GB) { return ([Math]::Round($b / 1GB, 2)).ToString([Globalization.CultureInfo]::InvariantCulture) + ' GB' }
  if ($b -ge 1MB) { return ([Math]::Round($b / 1MB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) + ' MB' }
  return ([Math]::Round($b / 1KB, 0)).ToString() + ' KB'
}
# tidy: moves old copies made before past edits (config.env.before-*, OpenCode Infinite backup
# *.bat, watcher.ps1.before-*, ...) from the state root into backup\estado-antigo\, removes the
# pool's own leftover trace-*.out temp files, trims the logs and reports what backup\ holds.
# Nothing the launcher reads is touched and nothing is deleted except the pool's temp files.
# tidy -Prune also DELETES, inside backup\: opencode.db snapshot folders except the newest, and
# <file>.<stamp>.bak copies older than 14 days except the 2 newest per file.
function Invoke-Tidy {
  Ensure-Dirs
  $bk = Join-Path $State 'backup'
  $arch = Join-Path $bk 'estado-antigo'
  $patterns = @('config.env.*', 'config.json.*', 'patterns.conf.*', 'recovery.ps1.*', 'watcher.ps1.*', 'OpenCode Infinite backup *.bat', 'warp-state-before-*.txt')
  $moved = 0
  $cutoff = (Get-Date).AddDays(-2)
  foreach ($pat in $patterns) {
    foreach ($f in @(Get-ChildItem -LiteralPath $State -Filter $pat -File -ErrorAction SilentlyContinue)) {
      if ($f.LastWriteTime -gt $cutoff) { continue }
      # Win32 -Filter 'config.json.*' also matches 'config.json' itself: -like is the real test,
      # and the live files are never moved.
      if ($f.Name -notlike $pat) { continue }
      if (@('config.env', 'config.json', 'patterns.conf', 'recovery.ps1', 'watcher.ps1') -contains $f.Name) { continue }
      if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Force -Path $arch | Out-Null }
      $dest = Join-Path $arch $f.Name
      if (Test-Path -LiteralPath $dest) { $dest = Join-Path $arch ($f.BaseName + '.' + (Get-Date).ToString('yyyyMMddHHmmss') + $f.Extension) }
      try { Move-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop; $moved++; Write-Host ('  arquivado: ' + $f.Name) } catch { Write-Host ('  nao movido: ' + $f.Name + ' (' + $_.Exception.Message + ')') }
    }
  }
  $temps = 0
  foreach ($f in @(Get-ChildItem -LiteralPath $poolDir -Filter 'trace-*.out*' -File -ErrorAction SilentlyContinue)) {
    if ($f.LastWriteTime -gt (Get-Date).AddHours(-1)) { continue }
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $temps++ } catch { }
  }
  # families.json (/32 keys) is no longer read since 1.4.
  $oldFam = Join-Path $poolDir 'families.json'
  if (Test-Path -LiteralPath $oldFam) {
    if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Force -Path $arch | Out-Null }
    try { Move-Item -LiteralPath $oldFam -Destination (Join-Path $arch 'families-v1.json') -Force -ErrorAction Stop; $moved++; Write-Host '  arquivado: pool\families.json (formato antigo)' } catch { }
  }
  Limit-PoolLogs
  Write-Host ('arquivos antigos movidos para backup\estado-antigo: ' + $moved + '   temporarios do pool apagados: ' + $temps)
  if (-not (Test-Path -LiteralPath $bk)) { return 0 }
  # What backup\ holds, biggest first, and what -Prune would remove.
  $items = @(Get-ChildItem -LiteralPath $bk -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'estado-antigo' })
  $rows = foreach ($i in $items) {
    $size = $(if ($i.PSIsContainer) { Get-DirBytes $i.FullName } else { [long]$i.Length })
    $isDb = ($i.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $i.FullName 'opencode.db')))
    [pscustomobject]@{ Item = $i; Name = $i.Name; Size = $size; Db = $isDb; When = $i.LastWriteTime }
  }
  $toPrune = @()
  $dbs = @($rows | Where-Object { $_.Db } | Sort-Object When -Descending)
  if ($dbs.Count -gt 1) { $toPrune += @($dbs | Select-Object -Skip 1) }
  $baks = @($rows | Where-Object { -not $_.Item.PSIsContainer -and $_.Name -match '^(.+?)\.(\d{8}-\d{6})(\..*)?\.bak$' })
  foreach ($g in @($baks | Group-Object { if ($_.Name -match '^(.+?)\.\d{8}-\d{6}') { $Matches[1] } else { $_.Name } })) {
    $old = @($g.Group | Sort-Object When -Descending | Select-Object -Skip 2 | Where-Object { $_.When -lt (Get-Date).AddDays(-14) })
    $toPrune += $old
  }
  $total = [long](@($rows | Measure-Object Size -Sum).Sum)
  $pruneBytes = [long](@($toPrune | Measure-Object Size -Sum).Sum)
  Write-Host ''
  Write-Host ('backup\ ocupa ' + (Fmt-Bytes $total) + ' em ' + $rows.Count + ' itens. Maiores:')
  $rows | Sort-Object Size -Descending | Select-Object -First 8 | ForEach-Object {
    Write-Host ('  ' + (Fmt-Bytes $_.Size).PadLeft(9) + '  ' + $_.Name + $(if ($_.Db) { '   (copia do banco de chats do OpenCode)' } else { '' }))
  }
  if (-not $toPrune.Count) { Write-Host 'nada para -Prune apagar.'; return 0 }
  if (-not $Prune) {
    Write-Host ('-Prune apagaria ' + $toPrune.Count + ' itens (' + (Fmt-Bytes $pruneBytes) + '): copias antigas do banco de chats (fica a mais nova) e .bak com mais de 14 dias (ficam os 2 mais novos de cada arquivo).')
    return 0
  }
  $freed = [long]0
  foreach ($p in $toPrune) {
    try {
      Remove-Item -LiteralPath $p.Item.FullName -Recurse -Force -ErrorAction Stop
      $freed += $p.Size
      Write-Host ('  apagado: ' + $p.Name + ' (' + (Fmt-Bytes $p.Size) + ')')
    } catch { Write-Host ('  nao apagado: ' + $p.Name + ' (' + $_.Exception.Message + ')') }
  }
  Write-Event 'tidy-prune' @{ items = $toPrune.Count; freedBytes = $freed }
  Write-Host ('liberado: ' + (Fmt-Bytes $freed))
  return 0
}

# Tests dot-source this file with WPOOL_LIB_ONLY=1 to get the functions without running an action.
if ($env:WPOOL_LIB_ONLY -eq '1') { return }

try {
  Ensure-Dirs
  $code = 0
  switch ($Action) {
    'grow' { $code = Invoke-Grow }
    'boot' { $code = Invoke-Boot }
    'spawn' { $code = Invoke-Spawn }
    'stats' { $code = Invoke-Stats }
    'dashboard' { $code = Invoke-Dashboard }
    'tidy' { $code = Invoke-Tidy }
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
