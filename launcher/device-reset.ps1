# device-reset.ps1 — rotate OpenCode's local device identity by using an isolated data dir per instance.
# Strategy (safer than mutating opencode.db live):
#   - Each "instance" of OpenCode gets its own OPENCODE_DATA_DIR / --cwd pointing to instances\instNN\data\.
#   - Reset just means: delete that instance's data subtree so next run generates a fresh device fingerprint.
#   - Original user data under %LOCALAPPDATA%\opencode\ is NEVER touched.
# Usage:
#   device-reset.ps1 -Instance 02           # resets inst02 only
#   device-reset.ps1 -Instance 02 -Keep log # preserves log subdir
param(
 [Parameter(Mandatory=$true)][string]$Instance,
 [string[]]$Keep = @(),
 [string]$State = (Join-Path $env:LOCALAPPDATA 'opencode-infinite')
)
$ErrorActionPreference = 'Stop'
if ($Instance -notmatch '^[A-Za-z0-9_-]{1,32}$') {
  Write-Host ('Refusing invalid -Instance: ' + $Instance + ' (allowed: ^[A-Za-z0-9_-]{1,32}$)')
  exit 2
}
$Root     = Join-Path $State 'instances'
$InstDir  = Join-Path $Root ('inst' + $Instance)
$DataDir  = Join-Path $InstDir 'data'
$Events   = Join-Path $State 'recovery-events.jsonl'
function Emit($Type, $Data) {
  $obj = [ordered]@{ timestamp=[DateTime]::UtcNow.ToString('o'); type=$Type; data=$Data }
  $line = (ConvertTo-Json -InputObject $obj -Compress -Depth 8) + [Environment]::NewLine
  [IO.File]::AppendAllText($Events, $line, [Text.UTF8Encoding]::new($false))
}
if (-not (Test-Path -LiteralPath $DataDir)) {
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  Emit 'device_reset_new' @{ instance=$Instance; path=$DataDir }
  Write-Output $DataDir
  exit 0
}
Get-ChildItem -LiteralPath $DataDir -Force | ForEach-Object {
  if ($Keep -contains $_.Name) { return }
  try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
  catch { Emit 'device_reset_warn' @{ instance=$Instance; path=$_.FullName; error=$_.Exception.Message } }
}
Emit 'device_reset_done' @{ instance=$Instance; path=$DataDir; kept=$Keep }
Write-Output $DataDir
exit 0
