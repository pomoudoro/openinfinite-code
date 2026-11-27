# run-tests.ps1 - tests for launcher\warp-pool.ps1 with no external module (Windows PowerShell 5.1+).
# Runs on a throwaway state folder: no tunnel, no network, no wireproxy. The functions that touch
# processes or the network (Measure-Slot, Test-SlotProcess, Test-Port, Start/Stop-SlotProcess)
# are replaced by stubs after the script is loaded with WPOOL_LIB_ONLY=1.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Exit code: 0 = all passed, 1 = at least one failure.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$poolScript = Join-Path $repo 'launcher\warp-pool.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\rotation-history-2026-11-26.jsonl'
$script:fails = 0
$script:passes = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
  if ($cond) { $script:passes++; Write-Host ('  ok    ' + $name) }
  else { $script:fails++; Write-Host ('  FALHA ' + $name + $(if ($detail) { '  -> ' + $detail } else { '' })) -ForegroundColor Red }
}
function New-TestState {
  $d = Join-Path ([IO.Path]::GetTempPath()) ('wpool-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path (Join-Path $d 'pool\claims') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $d 'instances\egress') | Out-Null
  return $d
}

# ---- 0. syntax of every .ps1 in the repo --------------------------------------------------------
Write-Host 'sintaxe'
foreach ($f in @(Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.ps1' -File | Where-Object { $_.FullName -notmatch '\\node_modules\\' })) {
  $e = $null
  [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
  Check ('parse ' + $f.FullName.Substring($repo.Length + 1)) ($e.Count -eq 0) (@($e | Select-Object -First 1 | ForEach-Object { $_.Message + ' @' + $_.Extent.StartLineNumber }) -join '')
}
# PowerShell blocks embedded in the launcher (#>>>OC_X_PS ... #>>>OC_ENDX).
$bat = Join-Path $repo 'launcher\OpenCode Infinite.bat'
$lines = [IO.File]::ReadAllLines($bat)
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^#>>>(OC_[A-Z]+?)(_PS)?$' -and $lines[$i] -notmatch '^#>>>OC_END') {
    $tag = $Matches[1]
    $end = -1
    for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -match '^#>>>') { $end = $j; break } }
    if ($end -lt 0) { continue }
    if ($lines[$end] -notmatch '^#>>>OC_END') { continue }
    $code = ($lines[($i + 1)..($end - 1)]) -join "`n"
    $e = $null
    [void][Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$e)
    Check ('parse bloco ' + $tag + ' do launcher') ($e.Count -eq 0) (@($e | Select-Object -First 1 | ForEach-Object { $_.Message + ' @+' + $_.Extent.StartLineNumber }) -join '')
  }
}

# ---- load warp-pool.ps1 as a library ------------------------------------------------------------
$st = New-TestState
$env:WPOOL_LIB_ONLY = '1'
. $poolScript -State $st -Action status
$env:WPOOL_LIB_ONLY = ''
# Stubs: no process, no network.
$script:fakeTrace = @{}
function Test-SlotProcess($s) { return $true }
function Test-Port([int]$port) { return $true }
function Start-SlotProcess([int]$n) { throw 'Start-SlotProcess must not run in tests' }
function Stop-SlotProcess([int]$n) { return $true }
function Measure-Slot($s, [int]$timeoutSec = 8) {
  $ip = [string]$s.ip
  if ($script:fakeTrace.ContainsKey([int]$s.slot)) { $ip = $script:fakeTrace[[int]$s.slot] }
  return @{ ok = $true; reason = ''; trace = [pscustomobject]@{ ip = $ip; colo = 'GRU'; warp = 'on' } }
}
$BurnedTtlHours = 1000000   # the fixture is from 26/11: keep it inside the window
function Set-TestSlot([int]$n, [string]$ip, $owner = $null) {
  $s = Get-Slot $n
  $s.ip = $ip; $s.health = 'up'; $s.colo = 'GRU'; $s.warp = 'on'; $s.owner = $owner; $s.pid = 4242
  if ($s.PSObject.Properties['ipSince']) { $s.ipSince = (Get-Date).AddSeconds(-30).ToString('o') }
  else { $s | Add-Member -NotePropertyName ipSince -NotePropertyValue ((Get-Date).AddSeconds(-30).ToString('o')) }
  Save-Slot $s
}

# ---- 1. Get-Family -------------------------------------------------------------------------------
Write-Host 'familia'
Check 'bac5 243c' ((Get-Family '2a09:bac5:f43:243c::39c:4') -eq '2a09:bac5:*:243c::39c') (Get-Family '2a09:bac5:f43:243c::39c:4')
Check 'bac1 36a8' ((Get-Family '2a09:bac1:1140:36a8::39c:2') -eq '2a09:bac1:*:36a8::39c')
Check 'hextet 3 nao conta' ((Get-Family '2a09:bac5:f41:297d::422:3d') -eq (Get-Family '2a09:bac5:f47:297d::422:76'))
Check 'sufixo diferente = familia diferente' ((Get-Family '2a09:bac1:1160:36a8::4d1:45') -ne (Get-Family '2a09:bac1:1160:36a8::39c:2'))
Check 'interface completa' ((Get-Family '2001:db8:1:2:3:4:5:6') -eq '2001:db8:*:2::3:4:5') (Get-Family '2001:db8:1:2:3:4:5:6')
Check 'ipv4 = vazio' ((Get-Family '104.28.1.1') -eq '')
Check 'lixo = vazio' ((Get-Family 'nada') -eq '')

# ---- 2. seeding from the 26/11 history ----------------------------------------------------------
Write-Host 'memoria de familias (historico de 26/11)'
Copy-Item -LiteralPath $fixture -Destination (Join-Path $poolDir 'rotation-history.jsonl')
$fams = Read-Families
Check 'semeou families-v2.json' (Test-Path -LiteralPath $familiesFile)
Check '36a8::39c queimada' (Test-FamilyBad '2a09:bac1:1100:36a8::39c:1')
Check '243c::39c queimada (as duas ultimas foram rapidas)' (Test-FamilyBad '2a09:bac5:f40:243c::39c:1')
Check '297d::422 boa' (-not (Test-FamilyBad '2a09:bac5:f40:297d::422:1'))
Check '1c8c::2d8 boa' (-not (Test-FamilyBad '2a09:bac5:f40:1c8c::2d8:1'))
$s297 = Get-FamilyScore '2a09:bac5:f40:297d::422:1'
$s243 = Get-FamilyScore '2a09:bac5:f40:243c::39c:1'
$s36 = Get-FamilyScore '2a09:bac1:1100:36a8::39c:1'
Check 'nota 297d > 243c > 36a8' ($s297 -gt $s243 -and $s243 -gt $s36) ("297d=$s297 243c=$s243 36a8=$s36")
Check 'familia desconhecida nota 0' ((Get-FamilyScore '2a09:dead:1:2::3:4') -eq 0)

# ---- 3. burned rule ----------------------------------------------------------------------------
Write-Host 'regra de queimada'
function Set-Outcomes([string]$fam, [string[]]$seq) {
  $all = Read-Families
  $q = @(); $g = @(); $t = (Get-Date).AddMinutes(-60)
  foreach ($k in $seq) { $t = $t.AddMinutes(5); if ($k -eq 'q') { $q += $t.ToString('o') } else { $g += $t.ToString('o') } }
  $all[$fam] = [ordered]@{ quick = $q; good = $g }
  Write-Json $familiesFile $all
}
Set-Outcomes '2001:db8:*:1::1' @('q', 'q');      Check 'q q = queimada' (Test-FamilyBad '2001:db8:0:1::1:9')
Set-Outcomes '2001:db8:*:1::1' @('q', 'q', 'g'); Check 'q q g = liberada por um IP que durou' (-not (Test-FamilyBad '2001:db8:0:1::1:9'))
Set-Outcomes '2001:db8:*:1::1' @('g', 'g', 'q', 'q'); Check 'g g q q = queimada (voltou a queimar)' (Test-FamilyBad '2001:db8:0:1::1:9')
Set-Outcomes '2001:db8:*:1::1' @('q');           Check 'uma queda so nao queima' (-not (Test-FamilyBad '2001:db8:0:1::1:9'))

# ---- 4. dedupe key ----------------------------------------------------------------------------
Write-Host 'dedupe'
$FamilyDedupe = 1
Check 'mesma familia = mesma chave' ((DedupeKey '2a09:bac5:f42:243c::39c:1') -eq (DedupeKey '2a09:bac5:f43:243c::39c:4'))
$FamilyDedupe = 0
Check 'sem dedupe por familia = IP inteiro' ((DedupeKey '2a09:bac5:f42:243c::39c:1') -ne (DedupeKey '2a09:bac5:f43:243c::39c:4'))
$FamilyDedupe = 1

# ---- 5. in-use rule ----------------------------------------------------------------------------
Write-Host 'slot em uso'
Check 'sem dono = livre' (-not (Test-SlotInUse ([pscustomobject]@{ owner = $null })))
Check 'dono lease = em uso' (Test-SlotInUse ([pscustomobject]@{ owner = [pscustomobject]@{ instance = 'x'; kind = 'lease' } }))
Check 'dono processo morto = livre' (-not (Test-SlotInUse ([pscustomobject]@{ owner = [pscustomobject]@{ instance = 'x'; kind = 'process'; pid = 999999; ticks = 1 } })))

# ---- 6. fast swap ------------------------------------------------------------------------------
Write-Host 'troca instantanea'
$own = [ordered]@{ instance = 'tst'; kind = 'lease'; at = (Get-Date).ToString('o'); renewedAt = (Get-Date).ToString('o') }
Set-TestSlot 1 '2a09:bac1:1140:36a8::39c:9' $own
Set-TestSlot 2 '2a09:bac5:f44:243c::39c:5'
Set-TestSlot 3 '2a09:bac5:f41:297d::422:7'
Set-TestSlot 4 '2a09:bac5:f41:1c96::2d9:7'
$Count = 4
Write-Json (Join-Path $claimsDir 'tst.json') ([ordered]@{ instance = 'tst'; slot = 1; port = 42001; ip = '2a09:bac1:1140:36a8::39c:9'; at = (Get-Date).ToString('o'); owner = $own })
$Swap = [switch]$true; $Instance = 'tst'; $Reason = 'quota'; $FastSwap = 1
$to = Invoke-SwapToSpare 1
Check 'trocou para a melhor familia (slot 3, 297d)' ($to -eq 3) ("foi para $to")
$c = Read-Json (Join-Path $claimsDir 'tst.json')
Check 'claim aponta para o slot novo' ([int]$c.slot -eq 3 -and [int]$c.port -eq (SlotPort 3))
Check 'slot novo tem o dono' ([string](Get-Slot 3).owner.instance -eq 'tst')
Check 'slot antigo ficou livre' ($null -eq (Get-Slot 1).owner)
Check 'IP antigo no burned[] do slot antigo' (@(Get-BurnedIps (Get-Slot 1)) -contains '2a09:bac1:1140:36a8::39c:9')
$last = Get-Content -LiteralPath (Join-Path $poolDir 'rotation-history.jsonl') -Tail 1 | ConvertFrom-Json
Check 'historico registra a troca' ([int]$last.swap -eq 3 -and [int]$last.slot -eq 1)
$Reason = 'exit'
Check 'motivo que nao e limite nao troca' ((Invoke-SwapToSpare 3) -eq 0)
$Reason = 'quota'; $FastSwap = 0
Check 'WPOOL_FAST_SWAP=0 nao troca' ((Invoke-SwapToSpare 3) -eq 0)
$FastSwap = 1
# Only burned spares left: no swap.
Set-TestSlot 4 '2a09:bac1:1100:36a8::39c:3'
Write-Json (Join-Path $claimsDir 'tst.json') ([ordered]@{ instance = 'tst'; slot = 3; port = (SlotPort 3); ip = '2a09:bac5:f41:297d::422:7'; at = (Get-Date).ToString('o'); owner = $own })
Check 'sem reserva boa nao troca' ((Invoke-SwapToSpare 3) -eq 0)
$Swap = [switch]$false

# ---- 7. claim picks the best family ------------------------------------------------------------
Write-Host 'claim'
foreach ($n in 1..4) { $s = Get-Slot $n; $s.owner = $null; $s.burned = @(); Save-Slot $s }
Get-ChildItem -LiteralPath $claimsDir -Filter '*.json' -File | Remove-Item -Force
Set-TestSlot 1 '2a09:bac1:1140:36a8::39c:9'
Set-TestSlot 2 '2a09:bac5:f44:1c96::2d9:5'
Set-TestSlot 3 '2a09:bac5:f41:297d::422:7'
Set-TestSlot 4 '2a09:bac5:f41:243c::39c:7'
$Instance = 'nova'; $OwnerPid = $PID
$rc = Invoke-Claim
$c = Read-Json (Join-Path $claimsDir 'nova.json')
Check 'claim pega a familia de maior nota (297d no slot 3)' ($rc -eq 0 -and [int]$c.slot -eq 3) ("rc=$rc slot=" + $c.slot)

# ---- 8. dashboard ------------------------------------------------------------------------------
Write-Host 'painel'
$p = Write-Dashboard
$html = [IO.File]::ReadAllText($p)
Check 'painel gerado' ($html -like '*Pool de t&uacute;neis*')
Check 'painel lista os IPs' ($html -like '*2a09:bac5:f41:297d::422:7*' -and $html -like '*2a09:bac1:1140:36a8::39c:9*')
Check 'painel marca queimada' ($html -like '*queimada*')
Check 'painel tem os dois graficos' (([regex]::Matches($html, '<svg ')).Count -ge 2)
Check 'painel sem acento quebrado' ($html -notmatch 'Ã')
$noAscii = @([IO.File]::ReadAllText($poolScript).ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
Check 'warp-pool.ps1 so tem ASCII (o PowerShell 5.1 le .ps1 sem BOM como ANSI)' ($noAscii -eq 0) ("$noAscii caracteres")

# ---- 8b. translations ------------------------------------------------------------------------
Write-Host 'traducoes'
# pt.json has keys that differ only by case ('Yes'/'yes'), which ConvertFrom-Json rejects: plain text search.
$ptText = [IO.File]::ReadAllText((Join-Path $repo 'launcher\langs\pt.json'), [Text.Encoding]::UTF8)
foreach ($key in @('One tunnel per IP family', 'Instant swap on limit', 'Egress pool')) {
  Check ('pt.json traduz "' + $key + '"') ($ptText.Contains('"' + $key + '": "'))
}
$t396 = ([IO.File]::ReadAllLines($bat) | Where-Object { $_ -like 'set "T_396=*' } | Select-Object -First 1)
$t396key = ($t396 -replace '^set "T_396=', '' -replace '"$', '' -replace '%%', '%')
Check 'pt.json traduz a mensagem T_396 do --pool' ($ptText.Contains('"' + $t396key + '": "')) $t396key

# ---- 9. log limit ------------------------------------------------------------------------------
Write-Host 'limite de log'
$log = Join-Path $st 'big.jsonl'
[IO.File]::WriteAllLines($log, [string[]](1..300 | ForEach-Object { '{"n":' + $_ + ',"pad":"' + ('x' * 20) + '"}' }))
$r = Limit-LogFile $log 1 50
Check 'cortou' ($r -eq $true)
Check 'ficaram as 50 linhas mais novas' (@([IO.File]::ReadAllLines($log)).Count -eq 50 -and ([IO.File]::ReadAllLines($log))[-1] -like '*"n":300,*')
Check 'as antigas foram para .1' (@([IO.File]::ReadAllLines($log + '.1')).Count -eq 250)
Check 'arquivo pequeno nao mexe' ((Limit-LogFile $log 1024 10) -eq $false)

# ---- 10. tidy ----------------------------------------------------------------------------------
Write-Host 'tidy'
$old = (Get-Date).AddDays(-5)
foreach ($n in @('config.json', 'config.env', 'config.json.before-x.bak', 'config.env.before-y', 'OpenCode Infinite backup v1 1.bat', 'patterns.conf')) {
  $f = Join-Path $State $n; Set-Content -LiteralPath $f -Value 'x'; (Get-Item -LiteralPath $f).LastWriteTime = $old
}
New-Item -ItemType Directory -Force -Path (Join-Path $State 'backup\db-old') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $State 'backup\db-new') | Out-Null
Set-Content -LiteralPath (Join-Path $State 'backup\db-old\opencode.db') -Value 'old'
Set-Content -LiteralPath (Join-Path $State 'backup\db-new\opencode.db') -Value 'new'
(Get-Item -LiteralPath (Join-Path $State 'backup\db-old')).LastWriteTime = $old
$Prune = [switch]$false
Invoke-Tidy | Out-Null
Check 'config.json ficou' (Test-Path -LiteralPath (Join-Path $State 'config.json'))
Check 'config.env ficou' (Test-Path -LiteralPath (Join-Path $State 'config.env'))
Check 'patterns.conf ficou' (Test-Path -LiteralPath (Join-Path $State 'patterns.conf'))
Check 'config.json.before-x.bak arquivado' ((-not (Test-Path -LiteralPath (Join-Path $State 'config.json.before-x.bak'))) -and (Test-Path -LiteralPath (Join-Path $State 'backup\estado-antigo\config.json.before-x.bak')))
Check 'backup .bat antigo arquivado' (Test-Path -LiteralPath (Join-Path $State 'backup\estado-antigo\OpenCode Infinite backup v1 1.bat'))
Check 'sem -Prune nada e apagado' ((Test-Path -LiteralPath (Join-Path $State 'backup\db-old')) -and (Test-Path -LiteralPath (Join-Path $State 'backup\db-new')))
$Prune = [switch]$true
Invoke-Tidy | Out-Null
Check '-Prune apaga a copia antiga do banco' (-not (Test-Path -LiteralPath (Join-Path $State 'backup\db-old')))
Check '-Prune mantem a copia mais nova' (Test-Path -LiteralPath (Join-Path $State 'backup\db-new\opencode.db'))
$Prune = [switch]$false

# ---- 11. hidden resume ------------------------------------------------------------------------
Write-Host 'retomada invisivel'
$env:OC_RESUME_LIB_ONLY = '1'
. (Join-Path $repo 'launcher\desktop-resume.ps1')
$env:OC_RESUME_LIB_ONLY = ''
$ht = Get-HiddenResumeText
Check 'texto oculto em portugues com acento certo' ($ht -like '*j' + [char]0xE1 + ' foi feito.') $ht
$sb = Get-SyntheticBody $ht | ConvertFrom-Json
Check 'corpo sintetico sem description (description faz o Desktop mostrar)' (-not $sb.PSObject.Properties['description'])
Check 'corpo sintetico com texto e metadata' ($sb.text -eq $ht -and $sb.metadata.source -eq 'openinfinite')
$env:OC_RESUME_HIDDEN_TEXT = 'texto proprio'
Check 'OC_RESUME_HIDDEN_TEXT troca o texto' ((Get-HiddenResumeText) -eq 'texto proprio')
$env:OC_RESUME_HIDDEN_TEXT = ''
foreach ($f in @('desktop-resume.ps1', 'resume-runner.ps1', 'warp-pool.ps1')) {
  $n = @([IO.File]::ReadAllText((Join-Path $repo ('launcher\' + $f))).ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
  Check ($f + ' so tem ASCII') ($n -eq 0) ("$n caracteres")
}
$launcherText = [IO.File]::ReadAllText($bat)
Check 'launcher tem a opcao RESUME_HIDDEN (padrao, validacao, Definicoes)' (([regex]::Matches($launcherText, 'RESUME_HIDDEN')).Count -ge 6)
Check 'launcher so esconde no modo continue' ($launcherText -match 'if "%RESUME_HIDDEN%"=="1" if /i not "%RESUME_MODE%"=="last" if /i not "%RESUME_MODE%"=="custom" set "OC_RESUME_HIDDEN=1"')

# Terminal windows: resume-runner.ps1 (private server + synthetic message).
$deskText = Get-HiddenResumeText
$deskBody = Get-SyntheticBody $deskText
$env:OC_RESUME_LIB_ONLY = '1'
. (Join-Path $repo 'launcher\resume-runner.ps1')
$env:OC_RESUME_LIB_ONLY = ''
Check 'terminal usa o mesmo texto oculto do Desktop' ((Get-HiddenResumeText) -eq $deskText)
Check 'terminal usa o mesmo corpo sintetico do Desktop' ((Get-SyntheticBody (Get-HiddenResumeText)) -eq $deskBody)
$fl = Get-ResumeFlags '-s ses_abc --standalone --auto -m opencode/deepseek-v4.1-flash-free#max'
Check 'flags: sessao, standalone, auto e modelo' ($fl.session -eq 'ses_abc' -and $fl.standalone -and $fl.auto -and $fl.model -eq 'opencode/deepseek-v4.1-flash-free#max')
$fl2 = Get-ResumeFlags '-c --auto'
Check 'flags sem -s: sem sessao (modo oculto nao roda)' (-not $fl2.session -and -not $fl2.standalone)
$mb = Get-ModelBody 'opencode/deepseek-v4.1-flash-free#max' | ConvertFrom-Json
Check 'corpo do modelo aninhado em "model"' ($mb.model.id -eq 'deepseek-v4.1-flash-free' -and $mb.model.providerID -eq 'opencode' -and $mb.model.variant -eq 'max')
Check 'modelo sem variante' (((Get-ModelBody 'opencode/x') | ConvertFrom-Json).model.PSObject.Properties['variant'] -eq $null)
Check 'modelo invalido = sem troca' ((Get-ModelBody 'semprovedor') -eq '')
Check 'launcher liga o oculto no terminal so com sessao e --standalone' ($launcherText -match 'if "%RESUME_HIDDEN%"=="1" if defined CAP_STANDALONE if /i not "%RESUME_MODE%"=="last" if /i not "%RESUME_MODE%"=="custom" if defined RT_SESS set "OC_RESUME_HIDDEN=1"')

# resume-target.py check: a hidden resume waiting in session_inbox, or already a synthetic message,
# counts as sent; a plain user message still counts; other text does not.
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if ($py) {
  $dd = Join-Path $st 'ocdata'
  New-Item -ItemType Directory -Force -Path $dd | Out-Null
  $mk = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table session_message (id text, session_id text, type text, data text, time_created integer)")
con.execute("create table session_inbox (id text, session_id text, type text, payload text, delivery text, enqueued_seq integer, time_created integer)")
con.execute("insert into session_message values ('m1','ses_a','idle','{\"error\":\"Free usage limit reached\"}',1000)")
con.execute("insert into session_inbox values ('m2','ses_a','synthetic','{\"text\":\"O limite gratuito foi atingido e o IP foi trocado. Continue\"}','queue',1,2000)")
con.execute("insert into session_message values ('m3','ses_b','synthetic','{\"text\":\"O limite gratuito foi atingido e o IP foi trocado. Continue\"}',3000)")
con.execute("insert into session_message values ('m4','ses_c','user','{\"text\":\"voltamos, pode continuar\"}',4000)")
con.commit()
'@
  $mkPath = Join-Path $st 'mk.py'
  [IO.File]::WriteAllText($mkPath, $mk)
  & $py -I $mkPath (Join-Path $dd 'opencode.db')
  $env:OC_DATA_DIR = $dd
  $rt = Join-Path $repo 'launcher\resume-target.py'
  $q = 'O limite gratuito foi atingido e o IP foi trocado. Continue'
  $a = (& $py -I $rt check --session ses_a --since-ms 0 --text $q) | ConvertFrom-Json
  $b = (& $py -I $rt check --session ses_b --since-ms 0 --text $q) | ConvertFrom-Json
  $c = (& $py -I $rt check --session ses_c --since-ms 0 --text 'voltamos, pode continuar') | ConvertFrom-Json
  $d = (& $py -I $rt check --session ses_a --since-ms 0 --text 'outra coisa') | ConvertFrom-Json
  $env:OC_DATA_DIR = ''
  Check 'retomada oculta na fila conta como enviada' ([bool]$a.already_sent)
  Check 'retomada oculta ja no chat conta como enviada' ([bool]$b.already_sent)
  Check 'mensagem normal continua contando' ([bool]$c.already_sent)
  Check 'outro texto nao conta' (-not [bool]$d.already_sent)
} else { Write-Host '  (python ausente: checagem do resume-target.py pulada)' }

Remove-Item -LiteralPath $st -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('passaram: ' + $script:passes + '   falharam: ' + $script:fails)
if ($script:fails -gt 0) { exit 1 }
exit 0
