# Pool de túneis (WPOOL) — como funciona por dentro

> Para usar o pool não é preciso ler isto: veja o [README](../README.md). Aqui ficam os detalhes técnicos, os comandos do `warp-pool.ps1` e os testes.

O pool cria **N túneis WARP** com **um proxy local por slot**: cada instância sai pelo seu próprio proxy/IP. Ele é o provider por trás de `EGRESS=WIREGUARD`, não um novo modo de egress.

## Como funciona

- Cada slot tem identidade wgcf própria, um `wireproxy` e um proxy HTTP local na porta `WPOOL_PORT_BASE + número do slot` (slot 1 usa `base+1`).
- O IPv4 free do WARP é CGNAT compartilhado: todos os devices saem pelo mesmo IPv4. O pool usa o **IPv6 por device** para distinguir as saídas; por isso um slot só é aceito se o trace retornar IPv6 e `warp=on`.
- O perfil é normalizado com `::/0` no `AllowedIPs`, `DNS = 1.1.1.1` e peer literal `162.159.192.1:2408` (o hostname `engage.cloudflareclient.com` resolve AAAA primeiro e o handshake morre neste host).
- O perfil ganha `PersistentKeepalive = 25`: slot parado não perde o mapeamento UDP do roteador.
- O launcher é o provider de `EGRESS=WIREGUARD`: cada janela faz `claim` do menor slot livre, `rotate` só do seu slot e `release` ao fechar.
- **Uma janela = um servidor próprio (v2.63):** no modo CLI, a janela do pool abre o OpenCode com `--standalone`, um servidor privado nascido com o proxy do seu túnel, e nunca reinicia o serviço de fundo compartilhado. Antes, cada janela reiniciava esse serviço com o próprio proxy e a última a abrir levava todas (e o Desktop) para o seu IP.
- **Desktop é um só (v2.63):** o app Desktop abre uma vez por máquina e fica com o serviço compartilhado. Com `MULTI_INSTANCE=1`, se outra janela do launcher já abriu o Desktop, a nova janela avisa e abre o OpenCode no terminal (CLI), com túnel próprio.
- **Todos os túneis ocupados (v2.63):** a janela pede mais um túnel (`-Action grow`, até `WPOOL_MAX`, padrão 8) e espera até ~1 min por um livre. Se nada vagar, ela sai pelo **WARP**, nunca direto pelo IP de casa. A fila faz o mesmo: o pedido continua na fila em vez de virar `failed_other`. Só janelas com o método **WIREGUARD** usam o pool; uma janela em WARP, Tor ou lista de proxies continua no seu egress (o `launcher.log` avisa: `only a WireGuard window takes a pool slot`).
- **Dono do claim:** o claim registra o processo que ficou vivo (a janela `cmd.exe` do launcher ou o dispatcher), por PID + horário de início. Enquanto ele vive, o slot é dele; quando ele fecha, `reap` (ou o próximo `claim`) libera. `WPOOL_LEASE_MIN` só vale para claims antigos, sem dono registrado.
- `pool\pool-status.json` guarda `up`, `distinct`, `portBase` e a tabela de slots; `pool\claims\<instância>.json` guarda `instance/slot/port/proxy/ip/owner`; `instances\<instância>\egress.json` diz por onde aquela instância sai; `pool-config.json` fixa `portBase`/`count` para os comandos seguintes não trocarem de base.
- Cada `wireproxy` nasce destacado (sem herdar handles nem console, fora do job de quem chamou): fechar a janela que subiu o pool não derruba os slots, e quem chama o script por pipe não fica esperando.
- `up` tem trava própria (`pool\up.lock`) e cada ação pega o lock do slot (`pool\slotNN.lock`): dois `up`, o daemon e um `rotate` nunca sobem dois `wireproxy` na mesma porta. Porta ocupada por outro programa falha o slot em vez de medir o proxy alheio.
- O daemon checa saúde a cada `WPOOL_HEALTH_SEC`. Um trace perdido só marca `degraded`; a segunda falha seguida reconstrói o slot (processo morto, `warp=off` ou porta fechada reconstroem na hora). Falhas repetidas têm backoff e, a cada 4 ciclos, tentam identidade nova. Colisão de IP gira o slot mais novo. `down` grava `stop.flag` para o daemon não ressuscitar os túneis.
- **Medido:** o IPv6 de saída de um túnel vivo muda sozinho de tempos em tempos (mesmo processo, IP novo depois de um rehandshake). Os slots continuam com IPs distintos entre si; o daemon registra `ip-drift` e atualiza claim e `egress.json`.
- **App WARP:** em **modo proxy** (`warp-cli settings` → `Mode: WarpProxy`, como neste projeto) os túneis do pool saem pela rota normal e nunca passam pelo app: não há conflito. Só o **modo túnel** pode capturar o UDP do pool; com `WPOOL_ALLOW_WARP_TUNNEL=0` o `up` recusa (exit 6) enquanto o app estiver conectado em modo túnel. Medido: 5 MB a ~15 MB/s e upload de 2 MB em 0,6 s por um slot; `opencode.ai` vê o IPv6 do slot.
- **Checagem no host da API (v2.63):** o trace do pool e o pré-voo da fila usam `https://opencode.ai/cdn-cgi/trace`, o mesmo host da API: um slot aprovado prova que o OpenCode vê o IP daquele túnel.
- **Vigia destacado (v2.63):** o boot (`up` + `daemon`) nasce com `-Action spawn`, fora do console da janela. Fechar a janela que subiu o pool não derruba mais o vigia.
- **Limite por IP ou por faixa? (v2.63):** cada rotação grava `pool\rotation-history.jsonl` com o `/64` do IP antigo e do novo e quanto tempo o antigo durou. `-Action stats` resume isso. Com a deduplicação por família (1.4, padrão) a dica de `WPOOL_DEDUPE_PREFIX=64` não aparece mais: a família já é mais larga que o `/64`.
- **Famílias queimadas (v2.63.1, histórico; a regra atual é a da 1.4 abaixo):** medido em 26/11: IPs `2a09:bac5:…` duraram 8 a 22 min de uso, enquanto **todo** IP `2a09:bac1:…:36a8` (a faixa que o app WARP também entrega, compartilhada por muita gente) bateu o limite de novo em 10 s, e a janela ficava num loop de trocas a cada 10 s. Agora o launcher informa o motivo da troca (`-Reason quota|watcher`) e o pool guarda, por família (os primeiros 32 bits do IPv6), quantos IPs bateram o limite em menos de 2 min e quantos duraram 5 min ou mais (`pool\families.json`). Família com 2+ quedas rápidas e nenhum sucesso nas últimas 2 h é **queimada**: a troca recusa esses IPs (até 4 reconexões trocando de endpoint, depois identidade nova), o `claim` entrega primeiro túneis de família boa e o `status` marca `(burned)`. Recusas aparecem como `exit-refused` em `recovery-events.jsonl`; `-Action stats` mostra a tabela de famílias.
- **Família = faixa estreita (warp-pool 1.4):** os primeiros 32 bits misturavam faixas boas e ruins. Medido em 26/11 (25 trocas): dentro de `2a09:bac5` o grupo `…:243c::39c:N` caía em 8 a 89 s, enquanto `…:297d::422:N`, `…:1c8c::2d8:N` e `…:1c96::2d9:N` duravam de 5 a 35 min. Agora a família é `h1:h2:*:h4::sufixo` (ex.: `2a09:bac5:*:243c::39c`; o 3º hextet só acompanha o endpoint). A memória fica em `pool\families-v2.json`, semeada na primeira execução a partir de `rotation-history.jsonl`. **Queimada** = 2+ quedas rápidas nas últimas `WPOOL_BURNED_TTL_HOURS` (72 h desde a 1.9; era 24 h) e as duas últimas foram rápidas; uma família que funcionou de manhã e passou a queimar é recusada logo, e um IP que dura a libera de novo.
- **Túnel livre em família queimada é trocado (1.4):** no `up` e a cada ciclo do vigia, um slot sem dono numa família queimada gira para uma família boa (evento `burned-replace`). Em 27/11, depois de religar o PC, os 4 túneis voltaram em famílias queimadas.
- **4 túneis = 4 famílias (1.4):** com `WPOOL_FAMILY_DEDUPE=1` (padrão), dois slots livres na mesma família contam como repetidos e o de cima gira (evento `family-collision`). Slot em uso nunca é girado por isso. Trocas automáticas têm pausa de 10 min por slot, para não registrar identidades em loop quando não há família livre.
- **Troca instantânea (1.5):** quando o limite volta (`-Reason quota|watcher`), a janela Desktop passa `-Swap -Instance` no `rotate`. Se houver um slot **livre**, `up`, numa família boa e diferente da que queimou, o claim muda para ele na hora (nova porta; o launcher reinicia o serviço com o proxy novo). O slot antigo fica livre com o IP em `burned[]`, vai para o fim da fila do `claim` e o vigia o gira em segundo plano. Sem reserva boa, cai na troca normal. Eventos: `swap` em `recovery-events.jsonl` e linha com `"swap": N` em `rotation-history.jsonl`. Janela no terminal não usa (o servidor `--standalone` nasceu com a porta antiga). Desligar: `WPOOL_FAST_SWAP=0`.
- **Melhor família primeiro (1.5):** cada família tem uma nota dentro da memória de `WPOOL_BURNED_TTL_HOURS` (72 h) (+1 por IP que durou, −1 por queda rápida, o resultado mais recente conta em dobro). O `claim` e a troca instantânea escolhem a maior nota; família desconhecida vale 0.
- **Logs com limite (1.7):** `recovery-events.jsonl` passa de 2 MB → as linhas antigas vão para `recovery-events.jsonl.1` e ficam as 5000 mais novas; `rotation-history.jsonl` faz o mesmo a partir de 1 MB (fica 3000). O vigia confere a cada ciclo.
- **Slot em uso (1.7):** trocas que o pool faz sozinho (faixa queimada, dedupe por família) também respeitam claims sem processo dono conhecido (`lease`), não só os de processo vivo.
- **Limpeza (v2.63):** túneis acima da quantidade configurada são parados e apagados no `up`, a menos que uma janela viva ainda os use. A primeira subida mostra o progresso (`pool\up-progress.json`).
- **Limitação:** destino IPv4-only sai pelo IPv4 compartilhado (CGNAT); IP próprio por instância exige IPv6 no destino (`opencode.ai` tem AAAA).

## Como rodar

Ligue em **Definições** (grupo **Pool de túneis**, em inglês *Egress pool*): `WPOOL_ENABLE=1`, `WPOOL_COUNT=4`, `WPOOL_PORT_BASE=42000`, e escolha **WIREGUARD** em *Ligação → Método de ligação*. Para várias janelas, também `MULTI_INSTANCE=1` (*Várias janelas*). Reinicie o launcher: o boot sobe `up` + `daemon` uma vez, com trava em `pool\startup.lock`. Os scripts ficam em `%LOCALAPPDATA%\opencode-infinite\` depois do instalador.

Na mão:

```powershell
powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\opencode-infinite\warp-pool.ps1" -Action status
powershell ... -File warp-pool.ps1 -Action up -Count 4 -PortBase 42000
powershell ... -File warp-pool.ps1 -Action claim -Instance janela01
powershell ... -File warp-pool.ps1 -Action rotate -Slot 1
powershell ... -File warp-pool.ps1 -Action down
```

Listar todas as ações: `up|status|claim|release|rotate|verify|down|daemon|reap|grow|boot|spawn|stats|dashboard`. `dashboard` grava `pool\dashboard.html` e abre no navegador (`-NoOpen` só grava); o vigia regrava a página a cada ciclo. `tidy` arquiva cópias antigas da raiz do estado (`config.env.before-*`, `OpenCode Infinite backup *.bat`, `watcher.ps1.before-*`...) em `backup\estado-antigo\` e lista o que ocupa espaço em `backup\`; `tidy -Prune` **apaga** as cópias antigas do banco de chats (`opencode.db`, fica a mais nova) e `.bak` com mais de 14 dias (ficam os 2 mais novos de cada arquivo). `grow` abre mais um túnel (até `-Max`/`WPOOL_MAX`); `spawn -Then boot|daemon` inicia o boot ou o vigia destacado; `stats` mostra o histórico de rotações por faixa `/64`. `-State` aponta a raiz do estado (padrão: `%LOCALAPPDATA%\opencode-infinite`), `-Slot` escolhe o slot no `rotate` e no `down` parcial, `-Instance` identifica a janela no `claim`/`release`. `-Force` no `rotate` gera identidade nova em vez de só reconectar. `-OwnerPid` no `claim` diz qual processo é o dono (padrão: quem chamou o script). `-AllowWarpTunnel` força o `up` com o app WARP conectado mesmo com `WPOOL_ALLOW_WARP_TUNNEL=0`.

Códigos de saída: `0` ok, `2` sem IP novo/distinto, `3` slot ou processo morto, `4` trava ocupada, `6` app WARP em modo túnel e não permitido, `7` nenhum slot livre, `8` pool já no máximo (`WPOOL_MAX`).

Memória medida (máquina com 63 GB): cada túnel ~28 MB físicos (~65 MB reservados), o Desktop ~1,2 GB (app + serviço), o vigia ~130 MB. Uma janela CLI deve ficar perto de 0,6 GB (estimativa pelo serviço do OpenCode). 8 túneis com 1 Desktop + 7 CLI dão ~6 GB; o limite prático é o Cloudflare e a sua internet, não a RAM.

Pool de CLIs em paralelo:

```powershell
powershell ... -File queue-add.ps1 -Prompt "resuma X"
powershell ... -File multi-dispatcher.ps1 -Pool on -Count 4 -Drain
```

No dispatcher, `auto` desativa o pool se `up=0` (volta ao caminho antigo), `on` exige slots up e aborta se não houver, e `off` mantém o caminho antigo. Cada worker recebe `HTTP_PROXY`/`HTTPS_PROXY` (e `http_proxy`/`https_proxy`) próprios, `NO_PROXY=127.0.0.1,localhost,::1` e `XDG_DATA_HOME`/`XDG_STATE_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` dentro da pasta do worker — um `XDG_*` herdado venceria o `USERPROFILE` isolado. Antes de cada lançamento o dispatcher faz um trace pelo proxy do worker; slot morto é girado uma vez e, se continuar morto, o item espera a próxima volta em vez de sair direto pelo IP da casa. `worker_start` registra `slot`, `ip` e `proxy`.

## Testes

**Automáticos (sem túnel, sem rede):** `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`. Confere a sintaxe de todo `.ps1` e dos blocos PowerShell dentro do launcher e testa o `warp-pool.ps1` numa pasta de estado descartável, com o histórico real de 26/11 (`tests\fixtures`): família, regra de queimada, nota, dedupe, troca instantânea, `claim`, painel, limite de log e `tidy`. Não precisa de módulo nenhum. O GitHub Actions (`.github/workflows/testes.yml`) roda os mesmos testes a cada push, no Windows PowerShell 5.1 (e no 7, só como aviso).

**Na mão, com túneis de verdade:**

Use `-State` apontando para `%TEMP%\wpool-teste` (nunca o estado real) e portas altas, ex.: `43500`, para não conflitar com o pool de produção.

Sintaxe antes de qualquer coisa:

```powershell
$e=$null; [System.Management.Automation.Language.Parser]::ParseFile('warp-pool.ps1',[ref]$null,[ref]$e); $e.Count  # esperado: 0
git diff --check   # esperado: EXIT=0
```

Sequência mínima:

```powershell
powershell ... -File warp-pool.ps1 -Action up -Count 2 -PortBase 43500 -State "$env:TEMP\wpool-teste"
powershell ... -File warp-pool.ps1 -Action status -State "$env:TEMP\wpool-teste"
```

Espere uma tabela com 2 slots `up`, IPs IPv6 **distintos**, `warp=on` e, no `pool-status.json`, `up=2`, `distinct=2`, `portBase=43500`.

Depois: `claim -Instance a1` e `claim -Instance a2` devem dar slots/portas distintos. `rotate -Slot 1` (sem `-PortBase`) mantém a porta, troca o IP e faz `claims\a1.json.ip` igualar `slot01\slot.json.ip`; o slot 2 fica intocado. O `status` deve levar segundos, não minutos (o trace tem teto de 8 s por slot).

`down` → portas fechadas, nenhum `wireproxy` do teste vivo e `stop.flag` presente em `pool\`. Limpe `%TEMP%\wpool-teste` no fim.

Dono e reap: rode `claim -Instance a1 -OwnerPid <pid de um processo seu>`; com o dono vivo, `reap` não libera nem com o `at` do claim envelhecido à mão; mate o dono e `reap` libera o claim e o `instances\a1\egress.json`.

Pipe: `powershell ... -Action rotate -Slot 1 -State ... 2>&1 | Out-String` tem que voltar em segundos (na v2.62.0 ficava preso até o `wireproxy` morrer).

Daemon: com `-Action daemon -HealthSec 5` rodando, mate o `wireproxy` de um slot; em ~15 s o slot volta `up` com PID novo (`daemon-restart` em `recovery-events.jsonl`).

Dispatcher: `-DryRun -Pool off` com fila de 1 e de 2 itens deve processar cada id uma vez. Com o pool de teste de pé, `-DryRun -Pool on` deve dar proxy distinto por worker, `NO_PROXY=127.0.0.1,localhost,::1` e `XDG_*` dentro de `instances\instNN\data`.

Se algo falhar, olhe `recovery-events.jsonl`, `pool\pool-status.json` e `instances\egress\slotNN\slot.json` (todos dentro de `-State`).
