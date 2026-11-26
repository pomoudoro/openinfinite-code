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
    # Enter = sim. Tres respostas invalidas (ou entrada fechada) = nao, nunca fica preso.
    for ($i = 0; $i -lt 3; $i++) {
        $r = Read-Host "   $t [S/n]"
        if ($null -eq $r) { return $false }
        $r = $r.Trim()
        if ($r -eq '' -or $r -match '^(s|sim|y|yes)$') { return $true }
        if ($r -match '^(n|nao|no)$') { return $false }
    }
    return $false
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
$Faltando = New-Object System.Collections.ArrayList
function Tem-Python { $v = $null; try { $v = (& python -c "import sqlite3,sys;print(sys.version.split()[0])" 2>$null) } catch {}; return $v }
function Tem-Node   { $v = $null; try { $v = (& node --version 2>$null) } catch {}; return $v }
function Tem-Warp   { return (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe')) }
function Tem-Desk   { return (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop')) }

if (-not $SemDependencias) {
    Titulo '1/6  Dependencias'

    # Python (o resume-target.py le o banco de sessoes do OpenCode para achar o chat que bateu o limite)
    $py = Tem-Python
    if (-not $py) {
        Aviso 'Python 3 nao encontrado (precisa estar no PATH como "python").'
        if (Pergunta 'Instalar Python 3.12 agora?') { [void](Winget-Instala 'Python.Python.3.12' 'Python 3.12'); $py = Tem-Python }
    }
    if ($py) { Ok "Python $py" } else { [void]$Faltando.Add(@('Python 3 (obrigatorio: retomada no mesmo chat)', 'https://www.python.org/downloads/windows/  (marque "Add python.exe to PATH")')) }

    # Node.js (CLI do OpenCode via npm e o bridge do Claude Code)
    $node = Tem-Node
    if (-not $node) {
        Aviso 'Node.js nao encontrado.'
        if (Pergunta 'Instalar Node.js LTS agora?') { [void](Winget-Instala 'OpenJS.NodeJS.LTS' 'Node.js LTS'); $node = Tem-Node }
    }
    if ($node) { Ok "Node.js $node" } else { [void]$Faltando.Add(@('Node.js (recomendado: CLI do OpenCode e bridge)', 'https://nodejs.org/en/download')) }

    # Cloudflare WARP (troca de IP)
    if (-not (Tem-Warp)) {
        Aviso 'Cloudflare WARP nao encontrado (sem ele nao ha rotacao de IP pelo WARP).'
        if (Pergunta 'Instalar Cloudflare WARP agora? (pede permissao de administrador)') { [void](Winget-Instala 'Cloudflare.Warp' 'Cloudflare WARP') }
    }
    if (Tem-Warp) { Ok 'Cloudflare WARP' } else { [void]$Faltando.Add(@('Cloudflare WARP (obrigatorio: troca de IP)', 'https://1.1.1.1/  (ou aceite quando o launcher oferecer instalar)')) }

    # OpenCode Desktop (caminho 2-1-1) - sem ele o launcher usa a CLI e instala ela sozinho
    if (Tem-Desk) { Ok 'OpenCode Desktop' }
    else {
        Aviso 'OpenCode Desktop nao encontrado.'
        Info  'baixe e instale em: https://opencode.ai/download'
        if (Pergunta 'Abrir a pagina de download agora?') { Start-Process 'https://opencode.ai/download' }
        [void]$Faltando.Add(@('OpenCode Desktop (obrigatorio no caminho 2-1-1)', 'https://opencode.ai/download'))
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

# Scripts do pool de egress: ficam na raiz de $State, nao em $App (e o dispatcher os chama por la).
$poolFiles = @('warp-pool.ps1', 'multi-dispatcher.ps1', 'queue-add.ps1', 'device-reset.ps1')
$poolCopiados = @()
foreach ($f in $poolFiles) {
    $src = Join-Path $Launcher $f
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $State $f
    if ((Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $src).Hash)) {
        Backup-Arquivo $dst
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $poolCopiados += $f
}
if ($poolCopiados.Count -gt 0) { Ok ("copiado para {0}: {1}" -f $State, ($poolCopiados -join ', ')) }

# Idiomas e temas ficam locais: o launcher baixaria do GitLab do projeto original na primeira execucao
# (e cai para ingles quando o GitLab recusa). So preenche o que falta; nao troca copia existente.
$batText = [IO.File]::ReadAllText((Join-Path $Launcher 'OpenCode Infinite.bat'))
$langVer = if ($batText -match "\`$LangVer = '([^']+)'") { $matches[1] } else { '' }
if ($langVer) {
    $langDir = Join-Path $State 'lang'
    New-Item -ItemType Directory -Force -Path $langDir | Out-Null
    foreach ($lf in Get-ChildItem -LiteralPath (Join-Path $Launcher 'langs') -Filter '*.json') {
        $dst = Join-Path $langDir $lf.Name
        $ver = $dst + '.ver'
        $cur = if (Test-Path -LiteralPath $ver) { ([IO.File]::ReadAllText($ver)).Trim() } else { '' }
        if (-not (Test-Path -LiteralPath $dst) -or $cur -ne $langVer) {
            Copy-Item -LiteralPath $lf.FullName -Destination $dst -Force
            [IO.File]::WriteAllText($ver, $langVer)
        }
    }
}
$themeDir = Join-Path $State 'themes'
$themeDst = Join-Path $themeDir 'themes.txt'
if (-not (Test-Path -LiteralPath $themeDst)) {
    New-Item -ItemType Directory -Force -Path $themeDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $Launcher 'themes\themes.txt') -Destination $themeDst -Force
    [IO.File]::WriteAllText($themeDst + '.ver', '1')
}
Ok 'idiomas (pt e outros) e temas instalados localmente'

# ------------------------------------------------------------------ 3. configuracao do launcher
Titulo '3/6  Padroes: WARP, DeepSeek V4.1 max, mensagem de retomada'
$cfgPath = Join-Path $State 'config.json'
$defaults = [ordered]@{
    OC_EGRESS_DEFAULT = 'WARP'
    OC_MODE_DEFAULT   = 'DESKTOP' # pula a tela de modo: o caminho fica 2-1-1
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
# patterns.conf decide o que cada erro faz. O limite gratis precisa estar em rotate= (troca o IP sozinho);
# um arquivo antigo com ele em ask= so perguntaria. Sem o arquivo, o launcher cria um com os padroes certos.
$patPath = Join-Path $State 'patterns.conf'
if (Test-Path -LiteralPath $patPath) {
    $patText = [IO.File]::ReadAllText($patPath)
    $rotLine = ([regex]::Match($patText, '(?m)^rotate=(.*)$')).Groups[1].Value
    if ($rotLine -notmatch 'free usage limit') {
        Backup-Arquivo $patPath
        Remove-Item -LiteralPath $patPath -Force
        Ok 'patterns.conf antigo (limite gratis so perguntava) trocado pelos padroes: agora troca o IP sozinho'
    } else { Ok 'patterns.conf: limite gratis troca o IP sozinho' }
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
if ($Faltando.Count) {
    Titulo 'Instalado, mas ainda falta:'
    foreach ($f in $Faltando) { Aviso $f[0]; Info $f[1] }
    Info 'Instale o que falta e rode o INSTALAR.bat de novo para conferir.'
} else {
    Titulo 'Pronto'
}
Info 'Para usar: de dois cliques em INICIAR.bat e siga 2 - 1 - 1 (Launch OpenCode, WARP, New IP).'
Info 'Na primeira execucao o launcher faz o setup dele (atalhos, comando opencodeinf).'
Write-Host ''
exit 0
