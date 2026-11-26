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
  [ValidateSet('up','status','claim','release','rotate','verify','down','daemon','reap','grow','boot','spawn','stats')]
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
$ScriptVersion = '1.3'

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
if (-not $PSBoundParameters.ContainsKey('BurnedTtlHours')) { $BurnedTtlHours = [int](CfgVal 'WPOOL_BURNED_TTL_HOURS' 24) }
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
# A "family" is the first 32 bits of the IPv6 exit. The pool remembers, per family, exits that
# hit the limit quickly and exits that lasted, and refuses exits from a family that only burns.
$FamQuickSec = 120
$FamGoodSec = 300
$familiesFile = Join-Path $poolDir 'families.json'
function Get-Family([string]$ip) {
  $p = Get-Prefix64 $ip
  if (-not $p) { return '' }
  $h = $p -split ':'
  return ($h[0] + ':' + $h[1])
}
function Read-Families {
  $o = Read-Json $familiesFile
  $h = @{}
  if ($o) { foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
  return $h
}
function Get-FamilyCounts([string]$fam) {
  $r = @{ quick = 0; good = 0 }
  if (-not $fam) { return $r }
  $all = Read-Families
  if (-not $all.ContainsKey($fam)) { return $r }
  $f = $all[$fam]
  $ttl = [Math]::Max(1, $BurnedTtlHours)
  $now = Get-Date
  foreach ($t in @($f.quick)) { try { if (($now - [DateTime]::Parse([string]$t)).TotalHours -lt $ttl) { $r.quick++ } } catch { } }
  foreach ($t in @($f.good)) { try { if (($now - [DateTime]::Parse([string]$t)).TotalHours -lt 2) { $r.good++ } } catch { } }
  return $r
}
# Burned = 2+ quick limits within the TTL and nothing that lasted in the last 2 hours.
function Test-FamilyBad([string]$ip) {
  $fam = Get-Family $ip
  if (-not $fam) { return $false }
  $c = Get-FamilyCounts $fam
  return ($c.quick -ge 2 -and $c.good -eq 0)
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
function Wait-SlotHealthy([int]$n, [int]$seconds, [string[]]$avoid = @(), [switch]$AvoidBadFamily) {
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
      if (-not $isOld -and -not $isBad) { return $m }
      $last = $m
      # The exit of a live tunnel rarely changes within seconds: two refusals in a row are enough,
      # the caller moves on to the next endpoint or identity instead of waiting out the timeout.
      $refused++
      if ($refused -ge 2) {
        if ($isBad) { Write-Event 'exit-refused' @{ slot = $n; ip = $ip; family = (Get-Family $ip); endpoint = [string]$s.endpoint } }
        return @{ ok = $false; reason = $(if ($isBad) { 'burned family' } else { 'same ip' }); trace = $m.trace }
      }
    }
    Start-Sleep -Milliseconds 1000
  }
  if ($last) { return @{ ok = $false; reason = 'same ip'; trace = $last.trace } }
  return @{ ok = $false; reason = 'no trace'; trace = $null }
}
function Start-Slot([int]$n, [switch]$NewIdentity, [string]$PrevIp = '', [int]$WaitSec = 25, [switch]$AvoidBurned, [switch]$NextEndpoint, [switch]$AvoidBadFamily) {
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
  $m = Wait-SlotHealthy $n $WaitSec $avoid -AvoidBadFamily:$AvoidBadFamily
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
      $r = Start-Slot $n -PrevIp $oldIp -WaitSec $WaitSec -AvoidBurned -AvoidBadFamily -NextEndpoint:($i -ge 2)
      if ($r.ok) { $lastIp = [string]$r.ip; $success = $true; break }
    }
  }
  if (-not $success -and -not $manual) {
    for ($i = 1; $i -le $MaxIdentity; $i++) {
      $r = Start-Slot $n -NewIdentity -PrevIp $oldIp -WaitSec 25 -AvoidBurned -AvoidBadFamily -NextEndpoint
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
    $ips = @(Get-AllSlots | Where-Object { [int]$_.slot -le $Count -and $_.health -eq 'up' -and $_.ip } | ForEach-Object { UniqKey ([string]$_.ip) })
    if ($ips.Count -eq @($ips | Sort-Object -Unique).Count) { break }
    Invoke-DaemonDedupe
  }
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
  # Free slots whose exit is in a burned family go last: a new window starts on an exit that works.
  $good = @(); $bad = @()
  foreach ($n in $nums) {
    if ($order -contains $n) { continue }
    if (Test-FamilyBad ([string](Get-Slot $n).ip)) { $bad += $n } else { $good += $n }
  }
  $order += $good + $bad
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
        if (-not $r.ok) { Write-Event 'dedupe-failed' @{ slot = $n; ip = $ip } }
      } catch {
        Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message }
      } finally { $lk.Dispose() }
    }
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
    Write-Event 'daemon-start' @{ pid = $PID; healthSec = $HealthSec }
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
          $r = Start-Slot $n -WaitSec 30 -NextEndpoint
          # The same identity keeps failing: a fresh wgcf device (a manual .conf in WgDir still wins).
          if (-not $r.ok -and ($fails[$n] % 4) -eq 0) {
            Write-Event 'daemon-new-identity' @{ slot = $n; reason = $r.reason }
            $r = Start-Slot $n -NewIdentity -NextEndpoint -WaitSec 30
          }
          if ($r.ok) { $fails[$n] = 0; Refresh-ClaimIp $n }
          else { Write-Event 'daemon-restart-failed' @{ slot = $n; reason = $r.reason } }
        } catch {
          Write-Event 'daemon-error' @{ slot = $n; error = $_.Exception.Message }
        } finally { $lk.Dispose() }
      }
      Invoke-DaemonDedupe
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
  if ($sharedQuick -ge 2 -and $DedupePrefix -ne 64) { Write-Host 'hint: the limit seems to follow the /64; try WPOOL_DEDUPE_PREFIX=64' }
  $fams = Read-Families
  if ($fams.Count) {
    Write-Host ''
    Write-Host ('exit families (quick = limit back within ' + $FamQuickSec + ' s, good = lasted ' + $FamGoodSec + ' s+; burned = 2+ quick and no good in 2 h):')
    $frows = foreach ($k in @($fams.Keys | Sort-Object)) {
      $c = Get-FamilyCounts $k
      [pscustomobject]@{ Family = $k; Quick = $c.quick; GoodLast2h = $c.good; Burned = ($c.quick -ge 2 -and $c.good -eq 0) }
    }
    $frows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  }
  return 0
}

try {
  Ensure-Dirs
  $code = 0
  switch ($Action) {
    'grow' { $code = Invoke-Grow }
    'boot' { $code = Invoke-Boot }
    'spawn' { $code = Invoke-Spawn }
    'stats' { $code = Invoke-Stats }
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
