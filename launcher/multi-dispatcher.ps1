# multi-dispatcher.ps1 — runs N OpenCode CLI "standalone" workers in parallel against a prompt queue.
# Each worker gets its own data dir (fresh device fingerprint) and rotates WARP when it hits the free limit.
# With -Pool on/auto each instNN claims its own warp-pool slot/proxy and rotates only that slot on quota.
# -Pool off keeps the original shared-WARP path (warp-rotate.ps1 + warp-rotate.lock) unchanged.
# Queue format (JSONL, one object per line):
#   { "id": "uuid", "prompt": "text", "model": "opencode/deepseek-v4.1-flash-free", "status": "queued" }
# Workers update status to sending -> done | failed_quota | failed_other and append output path.
# Usage:
#   powershell -NoProfile -File multi-dispatcher.ps1 -Count 3 -Project 'C:\path\to\project'
#   multi-dispatcher.ps1 -Count 6 -QueuePath custom.jsonl -Drain  # process everything and exit
param(
  [int]$Count = 3,
  [int]$Min = 2,
  [int]$Max = 12,
  [int]$RamBudgetMB = 8000,
  [string]$Project = (Get-Location).Path,
  [string]$QueuePath = '',
  [string]$Model = 'opencode/deepseek-v4.1-flash-free',
  [int]$PollSeconds = 2,
  [switch]$Drain,
  [switch]$DryRun,
  [string]$State = (Join-Path $env:LOCALAPPDATA 'opencode-infinite'),
  [ValidateSet('auto','on','off')][string]$Pool = 'auto'
)
$ErrorActionPreference = 'Stop'
# PS 5.1 cannot pass a live Process through Start-Job (it deserializes to a PSObject), so capture
# stdout/stderr with async handlers in this process. The StringBuilders are drained by WaitForExit()
# after the process exits; .NET guarantees the handlers have finished at that point.
if (-not ('OpenInfinite.AsyncCapture' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
namespace OpenInfinite {
  public sealed class AsyncCapture {
    private readonly Process _proc;
    private readonly StringBuilder _out = new StringBuilder();
    private readonly StringBuilder _err = new StringBuilder();
    private readonly object _outLock = new object();
    private readonly object _errLock = new object();
    public AsyncCapture(Process proc) {
      _proc = proc;
      _proc.OutputDataReceived += OnOut;
      _proc.ErrorDataReceived += OnErr;
    }
    private void OnOut(object sender, DataReceivedEventArgs e) {
      if (e.Data != null) { lock (_outLock) { _out.AppendLine(e.Data); } }
    }
    private void OnErr(object sender, DataReceivedEventArgs e) {
      if (e.Data != null) { lock (_errLock) { _err.AppendLine(e.Data); } }
    }
    public void Begin() { _proc.BeginOutputReadLine(); _proc.BeginErrorReadLine(); }
    public void Finish() { _proc.WaitForExit(); }
    public string Out { get { lock (_outLock) { return _out.ToString(); } } }
    public string Err { get { lock (_errLock) { return _err.ToString(); } } }
    public void Save(string outFile, string errFile) {
      File.WriteAllText(outFile, Out, new UTF8Encoding(false));
      File.WriteAllText(errFile, Err, new UTF8Encoding(false));
    }
  }
}
'@
}
$Root     = Join-Path $State 'instances'
$QueueDir = Join-Path $State 'queue'
$Events   = Join-Path $State 'recovery-events.jsonl'
$Cli      = Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\resources\opencode-cli.exe'
$WarpCli  = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
if (-not $QueuePath) { $QueuePath = Join-Path $QueueDir 'pending.jsonl' }
$PoolScript     = Join-Path $State 'warp-pool.ps1'
$PoolStatusFile = Join-Path $State 'pool\pool-status.json'
$PoolAvailable  = (Test-Path -LiteralPath $PoolScript) -and (Test-Path -LiteralPath $PoolStatusFile)
$PoolUp = -1
if ($PoolAvailable) {
  try { $PoolUp = [int]((Get-Content -LiteralPath $PoolStatusFile -Raw -Encoding UTF8 | ConvertFrom-Json).up) }
  catch { $PoolUp = -1 }
}
$PoolDowngradeReason = ''
if ($Pool -eq 'on' -and (-not $PoolAvailable -or $PoolUp -lt 1)) {
  $why = if (-not $PoolAvailable) { 'missing-pool-files' } elseif ($PoolUp -lt 0) { 'unreadable-status' } else { 'no-up-slots' }
  Write-Host ("Pool=on requires {0}, {1} and at least one up slot ({2}); aborting." -f $PoolScript, $PoolStatusFile, $why)
  exit 2
}
if ($Pool -eq 'auto') {
  if (-not $PoolAvailable) { $PoolDowngradeReason = 'missing-pool-files' }
  elseif ($PoolUp -lt 0) { $PoolDowngradeReason = 'unreadable-status' }
  elseif ($PoolUp -lt 1) { $PoolDowngradeReason = 'no-up-slots' }
}
$PoolActive = ($Pool -ne 'off') -and $PoolAvailable -and ($PoolUp -ge 1)
New-Item -ItemType Directory -Force -Path $Root, $QueueDir | Out-Null

function Emit($Type, $Data) {
  $obj = [ordered]@{ timestamp=[DateTime]::UtcNow.ToString('o'); type=$Type; data=$Data }
  $line = (ConvertTo-Json -InputObject $obj -Compress -Depth 8) + [Environment]::NewLine
  [IO.File]::AppendAllText($Events, $line, [Text.UTF8Encoding]::new($false))
}
function Read-Queue {
  if (-not (Test-Path -LiteralPath $QueuePath)) { return ,@() }
  # Keep the outer comma: PowerShell would unwrap a single-item array into a scalar,
  # and [Array]::FindIndex below needs an array even when the queue has one item.
  return ,@(Get-Content -LiteralPath $QueuePath -Encoding UTF8 | Where-Object { $_.Trim() } |
    ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
}
function Write-Queue($Items) {
  $tmp = $QueuePath + '.tmp.' + [guid]::NewGuid().ToString('N')
  $lines = @($Items | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 10 })
  [IO.File]::WriteAllText($tmp, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $tmp -Destination $QueuePath -Force
}
function Ensure-Instance($Idx) {
  $name = 'inst{0:D2}' -f $Idx
  $instDir = Join-Path $Root $name
  $dataDir = Join-Path $instDir 'data'
  $outDir  = Join-Path $instDir 'out'
  New-Item -ItemType Directory -Force -Path $instDir, $dataDir, $outDir | Out-Null
  return [pscustomobject]@{ name=$name; dir=$instDir; data=$dataDir; out=$outDir }
}
function Memory-Budget-OK {
  $rss = 0
  Get-Process -Name 'opencode*' -ErrorAction SilentlyContinue | ForEach-Object { $rss += ($_.WorkingSet64 / 1MB) }
  return ($rss -lt $RamBudgetMB)
}
function Rotate-Warp {
  $script = Join-Path $State 'warp-rotate.ps1'
  if (Test-Path -LiteralPath $script) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Tries 5 -WaitSeconds 4 -JitterSeconds 3
    return $LASTEXITCODE
  }
  return 1
}
function Invoke-PoolScript {
  param([string]$Action, [string]$Instance = '', [int]$SlotNumber = 0)
  $rc = 1
  $oldEa = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $argv = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PoolScript,'-Action',$Action,'-State',$State)
    if ($Instance) { $argv += @('-Instance',$Instance) }
    if ($SlotNumber -gt 0) { $argv += @('-Slot',[string]$SlotNumber) }
    & powershell.exe @argv 2>&1 | Out-Null
    $rc = $LASTEXITCODE
  } catch { $rc = 1 }
  finally { $ErrorActionPreference = $oldEa }
  return $rc
}
function Read-PoolClaim {
  param([string]$Instance)
  $path = Join-Path (Join-Path $State 'pool\claims') ($Instance + '.json')
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $c = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $c -or -not $c.proxy -or -not $c.slot) { return $null }
    return $c
  } catch { return $null }
}
function Claim-PoolSlot {
  param([string]$Instance)
  for ($try = 1; $try -le 3; $try++) {
    $rc = Invoke-PoolScript -Action 'claim' -Instance $Instance
    $claim = $null
    if ($rc -eq 0) { $claim = Read-PoolClaim $Instance }
    if ($claim) { return $claim }
    if ($try -lt 3) { Start-Sleep -Seconds 1 }
  }
  Emit 'worker_claim_failed' @{ worker=$Instance; pool=$Pool; tries=3 }
  return $null
}
function Release-PoolClaims {
  foreach ($kk in @($workers.Keys)) {
    $ww = $workers[$kk]
    if (-not $PoolActive -or -not $ww.claimed) { continue }
    $rc = Invoke-PoolScript -Action 'release' -Instance $kk
    Emit 'pool_released' @{ worker=$kk; slot=[int]$ww.slot; exit=$rc }
    $ww.claimed = $false
  }
}
$workers = @{}
for ($i = 1; $i -le $Count; $i++) {
  $inst = Ensure-Instance $i
  $workers[$inst.name] = @{ inst=$inst; busy=$false; proc=$null; capture=$null; item=$null; startedAt=$null; outFile=$null; errFile=$null }
  if ($PoolActive) {
    $w0 = $workers[$inst.name]
    $w0['claimed'] = $false; $w0['slot'] = 0; $w0['proxy'] = ''; $w0['ip'] = ''
    $claim = Claim-PoolSlot $inst.name
    if ($claim) {
      $w0['claimed'] = $true
      $w0['slot'] = [int]$claim.slot
      $w0['proxy'] = [string]$claim.proxy
      $w0['ip'] = [string]$claim.ip
      Emit 'worker_claimed' @{ worker=$inst.name; slot=[int]$claim.slot; ip=[string]$claim.ip }
    }
  }
}
Emit 'dispatcher_start' @{ count=$Count; min=$Min; max=$Max; project=$Project; queue=$QueuePath; drain=[bool]$Drain; dry_run=[bool]$DryRun }
if ($PoolActive) { Emit 'pool_mode' @{ mode=$Pool; script=$PoolScript; status=$PoolStatusFile; up=$PoolUp } }
elseif ($PoolDowngradeReason) { Emit 'pool_mode' @{ mode='off'; requested=$Pool; reason=$PoolDowngradeReason; script=$PoolScript; status=$PoolStatusFile; up=$PoolUp } }

try {
  while ($true) {
    # 1) Poll completed workers.
    foreach ($k in @($workers.Keys)) {
      $w = $workers[$k]
      if ($w.busy -and $w.proc -and $w.proc.HasExited) {
        $exit = $w.proc.ExitCode
        # Finish() waits only for the async handlers to flush (the process has already exited),
        # then persist both streams so the quota regex below sees the complete captured text.
        if ($w.capture) { $w.capture.Finish(); $w.capture.Save($w.outFile, $w.errFile) }
        $outFull = ''
        try { if (Test-Path -LiteralPath $w.outFile) { $outFull = Get-Content -LiteralPath $w.outFile -Raw -Encoding UTF8 } } catch {}
        $errFull = ''
        try { if (Test-Path -LiteralPath $w.errFile) { $errFull = Get-Content -LiteralPath $w.errFile -Raw -Encoding UTF8 } } catch {}
        $limited = ($errFull -match '(?i)(free usage limit|free message|today.{0,10}free messages?|they reset at|quota exceeded|daily (free )?limit)') -or
                   ($outFull -match '(?i)(free usage limit|free message|today.{0,10}free messages?|they reset at|quota exceeded|daily (free )?limit)')
        $items = Read-Queue
        $idx = [Array]::FindIndex($items, [Predicate[object]]{ param($x) $x.id -eq $w.item.id })
        if ($idx -ge 0) {
          if ($exit -eq 0 -and -not $limited) { $items[$idx].status = 'done' }
          elseif ($limited) { $items[$idx].status = 'quota'; $items[$idx].retries = [int]($items[$idx].retries) + 1 }
          else { $items[$idx].status = 'failed_other'; $items[$idx].retries = [int]($items[$idx].retries) + 1 }
          $items[$idx] | Add-Member -NotePropertyName last_worker -NotePropertyValue $k -Force
          $items[$idx] | Add-Member -NotePropertyName last_exit -NotePropertyValue $exit -Force
          Write-Queue $items
        }
        Emit 'worker_done' @{ worker=$k; id=$w.item.id; exit=$exit; limited=[bool]$limited; duration_ms=[int]((Get-Date) - $w.startedAt).TotalMilliseconds }
        if ($limited) {
          Emit 'worker_hit_quota' @{ worker=$k }
          if ($PoolActive) {
            $beforeIp = [string]$w.ip
            $beforeSlot = [int]$w.slot
            $rc = 1
            if ($beforeSlot -gt 0) { $rc = Invoke-PoolScript -Action 'rotate' -SlotNumber $beforeSlot }
            if ($rc -eq 0) {
              $claim = Read-PoolClaim $k
              if ($claim) {
                $w['slot'] = [int]$claim.slot
                $w['proxy'] = [string]$claim.proxy
                $w['ip'] = [string]$claim.ip
                Emit 'worker_rotate_pool' @{ worker=$k; slot=$w.slot; ip_before=$beforeIp; ip_after=$w.ip; proxy_after=$w.proxy; ok=$true }
              } else {
                Emit 'worker_rotate_pool' @{ worker=$k; slot=$beforeSlot; ip_before=$beforeIp; ip_after=$beforeIp; ok=$false }
                Emit 'worker_rotate_failed' @{ worker=$k; slot=$beforeSlot; reason='claim-unreadable' }
              }
            } else {
              Emit 'worker_rotate_pool' @{ worker=$k; slot=$beforeSlot; ip_before=$beforeIp; ip_after=$beforeIp; ok=$false }
              Emit 'worker_rotate_failed' @{ worker=$k; slot=$beforeSlot; reason='rotate-exit'; exit=$rc }
            }
          } else {
            # Rotate shared WARP (serialized by recovery.lock inside warp-rotate.ps1 is not enforced, so serialize here).
            $lockPath = Join-Path $State 'warp-rotate.lock'
            $lock = $null
            try {
              $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
              Rotate-Warp | Out-Null
            } catch { Emit 'worker_rotate_skipped' @{ worker=$k; reason='lock-busy' } }
            finally { if ($lock) { $lock.Dispose() } }
          }
          # Also reset this worker's device identity.
          $reset = Join-Path $State 'device-reset.ps1'
          if (Test-Path -LiteralPath $reset) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reset -Instance ($k -replace '^inst','') -State $State | Out-Null
          }
        }
        $w.busy = $false; $w.proc = $null; $w.item = $null
      }
    }

    # 2) Assign queued items to idle workers.
    $items = Read-Queue
    $queued = @($items | Where-Object { $_.status -eq 'queued' -or $_.status -eq 'quota' })
    foreach ($k in @($workers.Keys)) {
      if ($queued.Count -eq 0) { break }
      $w = $workers[$k]
      if ($w.busy) { continue }
      if (-not (Memory-Budget-OK)) { Emit 'worker_skipped_ram' @{ worker=$k }; break }
      $item = $queued[0]
      if ($queued.Count -gt 1) { $queued = $queued[1..($queued.Count-1)] } else { $queued = @() }
      if ($PoolActive -and -not $w.claimed) {
        $bad = [Array]::FindIndex($items, [Predicate[object]]{ param($x) $x.id -eq $item.id })
        if ($bad -ge 0) {
          $items[$bad].status = 'failed_other'
          $items[$bad].retries = [int]($items[$bad].retries) + 1
          $items[$bad] | Add-Member -NotePropertyName last_worker -NotePropertyValue $k -Force
          $items[$bad] | Add-Member -NotePropertyName last_exit -NotePropertyValue $null -Force
          Write-Queue $items
        }
        Emit 'worker_skipped_no_proxy' @{ worker=$k; id=$item.id; pool=$Pool }
        continue
      }
      $w.item = $item
      $w.outFile = Join-Path $w.inst.out ('run-' + $item.id + '.out')
      $w.errFile = Join-Path $w.inst.out ('run-' + $item.id + '.err')
      $modelArg = if ($item.model) { $item.model } else { $Model }
      $prompt = [string]$item.prompt
      $argLine = @(
        'run','--standalone',
        '--log-level','warn',
        '--prompt', ('"' + ($prompt -replace '"','\"') + '"')
      ) -join ' '
      # Build env: OPENCODE data dir and local HOME override so device identity stays isolated per worker.
      $envBlock = @{
        'LOCALAPPDATA' = $w.inst.data
        'APPDATA'      = $w.inst.data
        'USERPROFILE'  = $w.inst.data
        'HOME'         = $w.inst.data
        'OC_WORKER'    = $k
        'OC_MODEL'     = $modelArg
      }
      if ($PoolActive) {
        $envBlock['HTTP_PROXY'] = [string]$w.proxy
        $envBlock['HTTPS_PROXY'] = [string]$w.proxy
        $envBlock['NO_PROXY'] = 'localhost,127.0.0.1'
        $envBlock['OC_WPOOL_SLOT'] = [string]$w.slot
        $envBlock['OC_WPOOL_IP'] = [string]$w.ip
      }
      if ($DryRun) {
        Emit 'worker_dry_run' @{ worker=$k; id=$item.id; cwd=$Project; env=$envBlock; args=$argLine }
        $idx = [Array]::FindIndex($items, [Predicate[object]]{ param($x) $x.id -eq $item.id })
        if ($idx -ge 0) { $items[$idx].status = 'done'; Write-Queue $items }
        continue
      }
      # Flip status to sending before launch, so a crash doesn't reclaim it in parallel.
      $idx = [Array]::FindIndex($items, [Predicate[object]]{ param($x) $x.id -eq $item.id })
      if ($idx -ge 0) { $items[$idx].status = 'sending'; $items[$idx] | Add-Member -NotePropertyName worker -NotePropertyValue $k -Force; Write-Queue $items }
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $Cli
      $psi.Arguments = $argLine
      $psi.WorkingDirectory = $Project
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      foreach ($kk in $envBlock.Keys) { $psi.EnvironmentVariables[$kk] = [string]$envBlock[$kk] }
      $proc = [System.Diagnostics.Process]::Start($psi)
      # Drain both pipes asynchronously in this process (no PS 5.1 job deserialization).
      $w['capture'] = New-Object OpenInfinite.AsyncCapture($proc)
      $w.capture.Begin()
      $w.busy = $true; $w.proc = $proc; $w.startedAt = Get-Date
      Emit 'worker_start' @{ worker=$k; id=$item.id; pid=$proc.Id; model=$modelArg }
    }

    # 3) Drain exit.
    if ($Drain) {
      $items = Read-Queue
      $pending = @($items | Where-Object { $_.status -in @('queued','sending','quota') })
      $anyBusy = @($workers.Values | Where-Object { $_.busy }).Count -gt 0
      if ($pending.Count -eq 0 -and -not $anyBusy) {
        Emit 'dispatcher_drain_done' @{}
        Release-PoolClaims
        break
      }
    }
    Start-Sleep -Seconds $PollSeconds
  }
} catch {
  if ($PoolActive) {
    Emit 'dispatcher_error' @{ error=$_.Exception.Message }
    Release-PoolClaims
  }
  throw
}
