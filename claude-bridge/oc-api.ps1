param(
    [Parameter(Mandatory=$true)][ValidateSet('status','api')][string]$Action,
    [string]$Method,
    [string]$ApiPath,
    [string]$DataFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Resolve-OpenCodeCli {
    if ($env:OPENCODE_CLI -and (Test-Path -LiteralPath $env:OPENCODE_CLI)) {
        return $env:OPENCODE_CLI
    }

    # OpenCode Infinite writes the real CLI path here after discovery.
    $stateRoot = Join-Path $env:LOCALAPPDATA 'opencode-infinite'
    $stateFiles = @()
    $rootPathFile = Join-Path $stateRoot 'opencode_path.txt'
    if (Test-Path -LiteralPath $rootPathFile) { $stateFiles += Get-Item -LiteralPath $rootPathFile }
    $instancesDir = Join-Path $stateRoot 'instances'
    if (Test-Path -LiteralPath $instancesDir) {
        $stateFiles += @(Get-ChildItem -LiteralPath $instancesDir -Filter 'opencode_path.txt' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    }
    foreach ($stateFile in $stateFiles) {
        $candidate = (Get-Content -LiteralPath $stateFile.FullName -Raw).Trim().Trim('"')
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    $commands = @(Get-Command opencode -All -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandType -eq 'Application' -and $_.Source -and
        $_.Source -notmatch '\\opencode-infinite\\bin\\opencode\.(cmd|bat)$'
    })
    if ($commands.Count -gt 0) { return $commands[0].Source }

    throw 'OpenCode CLI real nao encontrado. Abra o OpenCode Infinite pelo .bat pelo menos uma vez ou defina OPENCODE_CLI com o caminho do CLI real.'
}

try {
    $cli = Resolve-OpenCodeCli

    if ($Action -eq 'status') {
        $lines = & $cli service status 2>&1
        $code = $LASTEXITCODE
        $message = ($lines | Out-String).Trim()
        if ($message) { [Console]::Out.WriteLine($message) }
        if ($code -ne 0) { exit $code }
        if ($message -match '(?i)\b(not running|no service|stopped|unavailable)\b') { exit 3 }
        exit 0
    }

    if (-not $Method -or -not $ApiPath) { throw 'Method e ApiPath sao obrigatorios.' }
    if ($DataFile) {
        $json = Get-Content -LiteralPath $DataFile -Raw -Encoding UTF8
        $lines = & $cli api $Method $ApiPath --data $json 2>&1
    } else {
        $lines = & $cli api $Method $ApiPath 2>&1
    }
    $code = $LASTEXITCODE
    foreach ($line in $lines) { [Console]::Out.WriteLine([string]$line) }
    exit $code
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
