# OpenInfinite Code - instalador
# Chamado pelo INSTALAR.bat. Pode rodar de novo quantas vezes quiser: nada e apagado,
# tudo que ja existe e mantido (com backup antes de qualquer troca).
param(
    [switch]$Sim,          # responde "sim" para tudo (instalacao sem perguntas)
    [switch]$SemDependencias
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root     = Split-Path -Parent $PSScriptRoot
$Launcher = Join-Path $Root 'launcher'
$State    = Join-Path $env:LOCALAPPDATA 'opencode-infinite'
$App      = Join-Path $State 'app'
$Backup   = Join-Path $State 'backup'
$OcCfgDir = Join-Path $env:USERPROFILE '.config\opencode'
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'

$DefaultModel = 'opencode/deepseek-v4.1-flash-free#max'
$ResumeMsg    = 'voltamos, pode continuar e retomar de onde parou'

function Titulo([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string]$t)     { Write-Host "   [ok] $t" -ForegroundColor Green }
function Aviso([string]$t)  { Write-Host "   [!]  $t" -ForegroundColor Yellow }
function Info([string]$t)   { Write-Host "        $t" }
function Pergunta([string]$t) {
    if ($Sim) { return $true }
    while ($true) {
        $r = Read-Host "   $t [S/N]"
        if ($r -match '^(s|sim|y|yes)$') { return $true }
        if ($r -match '^(n|nao|no)$')    { return $false }
    }
}
function Atualiza-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}
function Tem-Winget { return [bool](Get-Command winget -ErrorAction SilentlyContinue) }
function Winget-Instala([string]$Id, [string]$Nome) {
    if (-not (Tem-Winget)) {
        Aviso "winget nao encontrado. Instale $Nome pelo link do README."
        return $false
    }
    Info "instalando $Nome via winget ($Id)..."
    & winget install -e --id $Id --accept-source-agreements --accept-package-agreements
    Atualiza-Path
    return ($LASTEXITCODE -eq 0)
}
function Backup-Arquivo([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    New-Item -ItemType Directory -Force -Path $Backup | Out-Null
    $dest = Join-Path $Backup ((Split-Path -Leaf $Path) + ".$Stamp.bak")
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    Info "backup: $dest"
}
function Le-Json([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    return $raw | ConvertFrom-Json
}
function Grava-Json($Obj, [string]$Path) {
    $json = $Obj | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host '  ___                   ___       __ _      _ _       ' -ForegroundColor Magenta
Write-Host ' / _ \ _ __  ___ _ _   |_ _|_ _  / _(_)_ _ (_) |_ ___ ' -ForegroundColor Magenta
Write-Host '| (_) | ''_ \/ -_) '' \   | || '' \|  _| | '' \| |  _/ -_)' -ForegroundColor Magenta
Write-Host ' \___/| .__/\___|_||_| |___|_||_|_| |_|_||_|_|\__\___|' -ForegroundColor Magenta
Write-Host '      |_|                       OpenInfinite Code - instalador' -ForegroundColor Magenta

if (-not (Test-Path -LiteralPath (Join-Path $Launcher 'OpenCode Infinite.bat'))) {
    Aviso "nao achei launcher\OpenCode Infinite.bat. Rode o INSTALAR.bat de dentro da pasta do repositorio."
    exit 1
}
# Arquivos baixados como .zip vem marcados como "da internet"; libera para o PowerShell rodar.
Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ 1. dependencias
if (-not $SemDependencias) {
    Titulo '1/6  Dependencias'

    # Python (o resume-target.py le o banco de sessoes do OpenCode para achar o chat que bateu o limite)
    $py = $null
    try { $py = (& python -c "import sqlite3,sys;print(sys.version.split()[0])" 2>$null) } catch {}
    if ($py) { Ok "Python $py" }
    else {
        Aviso 'Python 3 nao encontrado (precisa estar no PATH como "python").'
        if (Pergunta 'Instalar Python 3.12 agora?') { [void](Winget-Instala 'Python.Python.3.12' 'Python 3.12') }
        else { Info 'link: https://www.python.org/downloads/windows/ (marque "Add python.exe to PATH")' }
    }

    # Node.js (CLI do OpenCode via npm e o bridge do Claude Code)
    $node = $null
    try { $node = (& node --version 2>$null) } catch {}
    if ($node) { Ok "Node.js $node" }
    else {
        Aviso 'Node.js nao encontrado.'
        if (Pergunta 'Instalar Node.js LTS agora?') { [void](Winget-Instala 'OpenJS.NodeJS.LTS' 'Node.js LTS') }
        else { Info 'link: https://nodejs.org/en/download' }
    }

    # Cloudflare WARP (troca de IP)
    $warp = Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe'
    if (Test-Path -LiteralPath $warp) { Ok 'Cloudflare WARP' }
    else {
        Aviso 'Cloudflare WARP nao encontrado (sem ele nao ha rotacao de IP pelo WARP).'
        if (Pergunta 'Instalar Cloudflare WARP agora? (pede permissao de administrador)') { [void](Winget-Instala 'Cloudflare.Warp' 'Cloudflare WARP') }
        else { Info 'link: https://1.1.1.1/  (ou o launcher oferece instalar na primeira vez)' }
    }

    # OpenCode Desktop (modo recomendado) - o launcher tambem instala a CLI sozinho se faltar
    $desk = Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop'
    if (Test-Path -LiteralPath $desk) { Ok 'OpenCode Desktop' }
    else {
        Aviso 'OpenCode Desktop nao encontrado.'
        Info  'baixe e instale em: https://opencode.ai/download'
        Info  '(sem o Desktop o launcher usa a CLI no terminal e instala ela sozinho se faltar)'
        if (Pergunta 'Abrir a pagina de download agora?') { Start-Process 'https://opencode.ai/download' }
    }
}

# ------------------------------------------------------------------ 2. launcher
Titulo '2/6  Launcher (OpenCode Infinite)'
New-Item -ItemType Directory -Force -Path $App | Out-Null
$files = @('OpenCode Infinite.bat', 'resume-runner.ps1', 'desktop-resume.ps1', 'resume-target.py')
foreach ($f in $files) {
    $src = Join-Path $Launcher $f
    $dst = Join-Path $App $f
    if ((Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $src).Hash)) {
        Backup-Arquivo $dst
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
Ok "copiado para $App"

# ------------------------------------------------------------------ 3. configuracao do launcher
Titulo '3/6  Padroes: WARP, DeepSeek V4.1 max, mensagem de retomada'
$cfgPath = Join-Path $State 'config.json'
$defaults = [ordered]@{
    OC_EGRESS_DEFAULT = 'WARP'
    OCUI_LANG         = 'pt'
    OC_MODEL          = $DefaultModel
    RESUME_MSG        = $ResumeMsg
    RESUME_MODE       = 'continue'
    RESUME_AUTO       = 1
    QUOTA_RESUME      = 1
    AUTO_ROTATE       = 1
    LIMIT_ACTION      = 'rotate'
    LIMIT_ROT_MAX     = 0
    WATCH             = 1
    UPDATE_ASK        = 'never'   # nao puxar o launcher original por cima desta versao
}
if (Test-Path -LiteralPath $cfgPath) {
    Backup-Arquivo $cfgPath
    try { $cfg = Le-Json $cfgPath } catch { Aviso 'config.json ilegivel; mantido como esta.'; $cfg = $null }
    if ($cfg) {
        if (-not $cfg.PSObject.Properties['version'])  { $cfg | Add-Member -NotePropertyName version -NotePropertyValue 1 }
        if (-not $cfg.PSObject.Properties['settings']) { $cfg | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{}) }
        $added = @()
        foreach ($k in $defaults.Keys) {
            $cur = $cfg.settings.PSObject.Properties[$k]
            if (-not $cur -or [string]::IsNullOrEmpty([string]$cur.Value)) {
                if ($cur) { $cur.Value = $defaults[$k] } else { $cfg.settings | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
                $added += $k
            }
        }
        Grava-Json $cfg $cfgPath
        if ($added.Count) { Ok ("config.json existente: preenchido " + ($added -join ', ')) }
        else { Ok 'config.json existente ja tinha todos os valores (nada alterado)' }
    }
} else {
    New-Item -ItemType Directory -Force -Path $State | Out-Null
    Grava-Json ([pscustomobject]@{ version = 1; settings = [pscustomobject]$defaults }) $cfgPath
    Ok "config.json criado em $State"
}
Info "modelo da retomada : $DefaultModel"
Info "mensagem de retomada: $ResumeMsg"

# ------------------------------------------------------------------ 4. modelo padrao do OpenCode
Titulo '4/6  Modelo padrao do OpenCode'
New-Item -ItemType Directory -Force -Path $OcCfgDir | Out-Null
$ocJson = Join-Path $OcCfgDir 'opencode.json'
$oc = $null
if (Test-Path -LiteralPath $ocJson) {
    try { $oc = Le-Json $ocJson } catch { Aviso "opencode.json ilegivel ($ocJson); nao alterado." }
} else {
    $oc = [pscustomobject]@{ '$schema' = 'https://opencode.ai/config.json' }
}
if ($oc) {
    $curModel = if ($oc.PSObject.Properties['model']) { [string]$oc.model } else { '' }
    if ($curModel -eq $DefaultModel) { Ok "ja esta em $DefaultModel" }
    elseif (-not $curModel -or (Pergunta "Trocar o modelo padrao '$curModel' por '$DefaultModel'?")) {
        Backup-Arquivo $ocJson
        if ($oc.PSObject.Properties['model']) { $oc.model = $DefaultModel } else { $oc | Add-Member -NotePropertyName model -NotePropertyValue $DefaultModel }
        Grava-Json $oc $ocJson
        Ok "modelo padrao: $DefaultModel"
    } else { Info "mantido: $curModel" }
}

# ------------------------------------------------------------------ 5. orquestrador
Titulo '5/6  Orquestrador (agentes orchestrator, builder, tester, reviewer...)'
$agentsDst = Join-Path $OcCfgDir 'agents'
New-Item -ItemType Directory -Force -Path $agentsDst | Out-Null
foreach ($a in Get-ChildItem -LiteralPath (Join-Path $Root 'orchestrator\agents') -Filter '*.md') {
    $dst = Join-Path $agentsDst $a.Name
    if ((Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $a.FullName).Hash)) {
        Backup-Arquivo $dst
    }
    Copy-Item -LiteralPath $a.FullName -Destination $dst -Force
}
Ok "agentes globais em $agentsDst"
Info 'no OpenCode, troque o agente com Tab e escolha "orchestrator".'

# ------------------------------------------------------------------ 6. bridge Claude Code (opcional)
Titulo '6/6  Bridge Claude Code -> OpenCode (opcional)'
$claude = Get-Command claude -ErrorAction SilentlyContinue
$npm    = Get-Command npm -ErrorAction SilentlyContinue
if (-not $claude) { Info 'Claude Code nao encontrado: pulei o bridge (veja o README para instalar depois).' }
elseif (-not $npm) { Aviso 'npm nao encontrado: instale o Node.js e rode o INSTALAR.bat de novo para o bridge.' }
elseif (Pergunta 'Instalar o bridge MCP (Claude Code delega tarefas ao DeepSeek pelo OpenCode Infinite)?') {
    $bridgeDst = Join-Path $State 'claude-bridge'
    New-Item -ItemType Directory -Force -Path $bridgeDst | Out-Null
    foreach ($f in @('bridge.mjs', 'oc-api.ps1', 'package.json', 'package-lock.json')) {
        Copy-Item -LiteralPath (Join-Path $Root "claude-bridge\$f") -Destination (Join-Path $bridgeDst $f) -Force
    }
    $userInstr = Join-Path $Root 'claude-bridge\instructions.md'
    if (Test-Path -LiteralPath $userInstr) { Copy-Item -LiteralPath $userInstr -Destination $bridgeDst -Force }
    Push-Location $bridgeDst
    try { & npm install --omit=dev --no-audit --no-fund | Out-Host } finally { Pop-Location }
    $bridgeJs = Join-Path $bridgeDst 'bridge.mjs'
    $list = (& claude mcp list 2>$null) -join "`n"
    if ($list -match '(?m)^opencode-infinite:') {
        Ok 'MCP "opencode-infinite" ja esta registrado no Claude Code (mantido).'
        Info "para apontar para esta copia: claude mcp remove opencode-infinite -s user  e rode o INSTALAR.bat de novo"
    } else {
        & claude mcp add --transport stdio --scope user opencode-infinite -- node "$bridgeJs"
        if ($LASTEXITCODE -eq 0) { Ok 'MCP "opencode-infinite" registrado (escopo user).' } else { Aviso 'claude mcp add falhou; veja o README.' }
    }
}

# ------------------------------------------------------------------ fim
Titulo 'Pronto'
Info 'Para usar: de dois cliques em INICIAR.bat (ou arraste uma pasta de projeto em cima dele).'
Info 'Na primeira execucao o launcher faz o setup dele (atalhos, comando opencodeinf, WARP).'
Write-Host ''
exit 0
