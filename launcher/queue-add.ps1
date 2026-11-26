# queue-add.ps1 — append a prompt to the multi-dispatcher queue.
# Usage:
#   queue-add.ps1 -Prompt "oi, resuma X" -Model opencode/deepseek-v4.1-flash-free
#   queue-add.ps1 -File prompts.txt     # one prompt per line
param(
 [string]$Prompt = '',
 [string]$Model = '',
 [string]$File = ''
)
$ErrorActionPreference = 'Stop'
$State    = Join-Path $env:LOCALAPPDATA 'opencode-infinite'
$QueueDir = Join-Path $State 'queue'
$Queue    = Join-Path $QueueDir 'pending.jsonl'
New-Item -ItemType Directory -Force -Path $QueueDir | Out-Null
$items = @()
if ($File) {
  if (-not (Test-Path -LiteralPath $File)) { throw "file not found: $File" }
  $items += @(Get-Content -LiteralPath $File -Encoding UTF8 | Where-Object { $_.Trim() })
} elseif ($Prompt) { $items += $Prompt }
else { throw 'pass -Prompt "..." or -File path' }
foreach ($p in $items) {
  $obj = [ordered]@{
    id      = [guid]::NewGuid().ToString('N')
    prompt  = $p
    model   = $Model
    status  = 'queued'
    added   = [DateTime]::UtcNow.ToString('o')
    retries = 0
  }
  $line = (ConvertTo-Json -InputObject $obj -Compress -Depth 8) + [Environment]::NewLine
  [IO.File]::AppendAllText($Queue, $line, [Text.UTF8Encoding]::new($false))
  Write-Output $obj.id
}
