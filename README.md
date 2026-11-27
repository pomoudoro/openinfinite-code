<div align="center">

# ♾️ OpenInfinite Code

**OpenCode sem parar no limite grátis.**
Bateu o limite? Troca o IP pelo Cloudflare WARP e o chat continua sozinho, no mesmo ponto.
Quer várias conversas ao mesmo tempo, cada uma com o próprio IP? Ligue o **pool de túneis**.

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)
![OpenCode](https://img.shields.io/badge/OpenCode-Desktop%20%2B%20CLI-111111)
![Modelo](https://img.shields.io/badge/modelo-DeepSeek%20V4.1%20Flash%20(max)-4D6BFE)
![WARP](https://img.shields.io/badge/egress-Cloudflare%20WARP-F38020?logo=cloudflare&logoColor=white)
![Licença](https://img.shields.io/badge/licen%C3%A7a-GPL--3.0-blue)

</div>

---

## ⚡ Começo rápido

**1. Baixe o projeto** (um dos dois):

```powershell
git clone https://github.com/pomoudoro/openinfinite-code.git
```

ou, sem Git: no GitHub, **Code → Download ZIP** e extraia a pasta (por exemplo em `Documentos\openinfinite-code`).

**2. Dê dois cliques em `INSTALAR.bat`.** Ele confere o que falta (Python, WARP, OpenCode Desktop, Node.js) e oferece instalar. No fim aparece **"Pronto"** ou a lista do que ainda falta, com os links. Instale o que faltar e rode o `INSTALAR.bat` de novo até aparecer "Pronto".

**3. Dê dois cliques em `INICIAR.bat`** e siga o caminho **2 → 1 → 1**:

> [!TIP]
> ### ✅ Caminho recomendado: `2 - 1 - 1`
> | Tela | Escolha |
> |---|---|
> | Início | **[2] Iniciar o OpenCode** |
> | Conexão | **[1] WARP** |
> | Menu | **[1] Nova IP e iniciar o OpenCode** |
>
> Use **2-1-1** e não 1-1-1. O `[1] opencode automático` da tela inicial pula tudo e abre uma sessão nova; o `[2]` passa pela escolha da conexão e pega um IP novo antes de abrir o OpenCode Desktop, que é o caminho testado com a retomada automática.
> O modo Desktop já vem salvo pelo instalador, por isso não aparece tela de modo nem de pasta (o próprio Desktop escolhe o projeto). Se o Desktop não estiver instalado, aparece a tela de modo antes da conexão.

---

## 🪟 Várias janelas, cada uma com o próprio IP (pool de túneis)

Com o WARP normal, o PC inteiro tem **um** IP: quando uma conversa bate o limite, todas param até trocar. Com o pool, o launcher mantém vários túneis ao mesmo tempo (padrão: 4), cada um com um IP diferente. Cada janela pega o seu túnel, e quando ela bate o limite **só ela** troca de IP; as outras continuam.

**Ligar (uma vez só):** abra o `INICIAR.bat` → **5. Definições** e ajuste:

| Grupo | Opção | Valor |
|---|---|---|
| Ligação | Método de ligação | **WIREGUARD** |
| Pool de túneis | Usar o pool de túneis | **Ativado** |
| Pool de túneis | Túneis no pool | **4** (até 16) |
| Inicialização | Várias janelas | **Ativado** |

Feche e abra o `INICIAR.bat` de novo. Na primeira vez ele leva até ~2 minutos criando os túneis (mostra o progresso).

**Usar:** `INICIAR.bat` → **2 - 5 - 1** (*Iniciar o OpenCode* → *WIREGUARD* → *Nova IP e iniciar o OpenCode*). Para outra conversa em paralelo, abra o `INICIAR.bat` de novo e repita. A primeira janela abre o app Desktop; as seguintes abrem o OpenCode no terminal (o Desktop só abre uma vez por máquina), cada uma no seu túnel.

| Situação | O que acontece |
|---|---|
| Uma janela bate o limite grátis | Só o túnel dela troca de IP e o chat continua sozinho. |
| Todos os túneis ocupados | A nova janela abre mais um túnel (até 8, opção *Máximo de túneis*); se não der, espera ~1 min e usa o WARP — nunca o IP direto da sua casa. |
| Um túnel trava | O vigia percebe em segundos e reabre o túnel em outro servidor do Cloudflare. |
| A troca cai numa faixa de IP "queimada" | O pool aprende: faixa cujos IPs batem o limite em segundos é recusada nas próximas trocas (veja abaixo). |
| Você fecha uma janela | O túnel dela fica livre para a próxima. |

**Atalhos:** `POOL.bat` (menu: ver o estado dos túneis, ligar, desligar, trocar o IP de um túnel) e `FILA.bat` (manda pedidos para rodarem sozinhos em paralelo, cada um no seu túnel: `FILA.bat "resuma o arquivo X"` e depois `FILA.bat dispatcher` dentro da pasta do projeto). Os dois ficam em `%LOCALAPPDATA%\opencode-infinite\`.

> [!NOTE]
> Os túneis do pool também são do Cloudflare WARP (identidades WireGuard próprias, criadas com o `wgcf`). A diferença é ter vários IPs ao mesmo tempo, separados do app WARP. > O limite grátis é do OpenCode: se um dia ele passar a valer por conta, e não por IP, o pool não ajuda.

---

## 🎁 O que vem no pacote

| | Recurso | Detalhe |
|---|---|---|
| 🌐 | **WARP** | Cloudflare WARP em modo proxy, só para o OpenCode. O resto do PC (navegador, outros apps) continua na conexão normal. |
| 🧠 | **DeepSeek V4.1 Flash Free (max)** | `opencode/deepseek-v4.1-flash-free#max` como modelo padrão do OpenCode e da retomada. |
| 🪟 | **Pool de túneis** | Vários túneis WARP ao mesmo tempo, um IP por janela. Veja [Várias janelas](#-várias-janelas-cada-uma-com-o-próprio-ip-pool-de-túneis). |
| 🔁 | **Retomada automática** | Quando aparece *"You've used today's free messages"*, o launcher troca o IP e manda no mesmo chat: **"voltamos, pode continuar e retomar de onde parou"**. Nunca envia a mesma mensagem duas vezes. |
| 🎯 | **Orquestrador** | Agentes `orchestrator`, `builder`, `tester`, `reviewer`, `researcher`, `reverser`, `ask` e `debug`, instalados para todos os projetos. Veja [orchestrator/](orchestrator/README.md). |
| 🤝 | **Bridge Claude Code** *(opcional)* | O Claude Code delega tarefas ao DeepSeek pelo OpenCode Infinite (MCP). Veja [claude-bridge/](claude-bridge/README.md). |
| 🚫 | **Sem update de terceiros** | A autoatualização do launcher original foi removida: nada substitui esta versão por baixo dos panos. |

Também continuam disponíveis Tor (portátil, instalado sozinho), proxies HTTP grátis, WireGuard e VPN Gate.

---

## 📦 O que precisa estar instalado

O `INSTALAR.bat` confere tudo e oferece instalar o que faltar pelo **winget**. Se preferir baixar à mão:

| Programa | Para quê | Obrigatório? | Link direto | winget |
|---|---|---|---|---|
| **OpenCode Desktop** | o app onde você conversa | ✅ (modo 2) | <https://opencode.ai/download> | — |
| **Cloudflare WARP** | troca de IP | ✅ | <https://1.1.1.1/> · [MSI 64-bit](https://downloads.cloudflareclient.com/v1/download/windows/ga) | `winget install -e --id Cloudflare.Warp` |
| **Python 3** | acha o chat que bateu o limite | ✅ | <https://www.python.org/downloads/windows/> *(marque "Add python.exe to PATH")* | `winget install -e --id Python.Python.3.12` |
| **Node.js LTS** | CLI do OpenCode via npm e o bridge | recomendado | <https://nodejs.org/en/download> | `winget install -e --id OpenJS.NodeJS.LTS` |
| **Git** | clonar e atualizar este repositório | recomendado | <https://git-scm.com/download/win> | `winget install -e --id Git.Git` |
| **Claude Code** | só para o bridge | opcional | <https://claude.com/claude-code> | — |

PowerShell 5.1 e `curl` já vêm no Windows 10/11.

---

## 🛠️ O que o `INSTALAR.bat` faz

Pode rodar de novo quantas vezes quiser. Antes de trocar qualquer arquivo, ele guarda um backup em `%LOCALAPPDATA%\opencode-infinite\backup\`.

1. **Dependências:** confere Python, Node.js, WARP e OpenCode Desktop, e oferece instalar.
2. **Launcher:** copia `launcher\*` para `%LOCALAPPDATA%\opencode-infinite\app\`, junto com os idiomas e temas (assim a interface já abre em português, sem baixar nada).
3. **Padrões do launcher** (`config.json`): WARP, português, modelo `deepseek-v4.1-flash-free#max`, mensagem de retomada, rotação automática, update de terceiros desligado. Num `config.json` que já existe, preenche só o que estiver vazio.
4. **Modelo padrão do OpenCode** (`%USERPROFILE%\.config\opencode\opencode.json`): grava `opencode/deepseek-v4.1-flash-free#max`. Se você já tem outro modelo, ele pergunta antes.
5. **Orquestrador:** copia os agentes para `%USERPROFILE%\.config\opencode\agents\`.
6. **Bridge Claude Code** *(opcional)*: `npm install` e `claude mcp add` (só se o `claude` existir).
7. **Resumo:** termina com "Pronto" ou com a lista do que ainda falta instalar.

Opções: `INSTALAR.bat -Sim` (responde sim a tudo) · `INSTALAR.bat -SemDependencias` (pula a etapa 1).

---

## 🌐 Pool de egress (WPOOL)

O pool cria **N túneis WARP** com **um proxy local por slot**: cada instância sai pelo seu próprio proxy/IP. Ele é o provider por trás de `EGRESS=WIREGUARD`, não um novo modo de egress.

### Como funciona

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
- **Limite por IP ou por faixa? (v2.63):** cada rotação grava `pool\rotation-history.jsonl` com o `/64` do IP antigo e do novo e quanto tempo o antigo durou. `-Action stats` resume isso; se o limite voltar rápido na mesma faixa, ele sugere `WPOOL_DEDUPE_PREFIX=64` (dois túneis com o mesmo `/64` passam a contar como o mesmo IP).
- **Famílias queimadas (v2.63.1):** medido em 26/11: IPs `2a09:bac5:…` duraram 8 a 22 min de uso, enquanto **todo** IP `2a09:bac1:…:36a8` (a faixa que o app WARP também entrega, compartilhada por muita gente) bateu o limite de novo em 10 s, e a janela ficava num loop de trocas a cada 10 s. Agora o launcher informa o motivo da troca (`-Reason quota|watcher`) e o pool guarda, por família (os primeiros 32 bits do IPv6), quantos IPs bateram o limite em menos de 2 min e quantos duraram 5 min ou mais (`poolamilies.json`). Família com 2+ quedas rápidas e nenhum sucesso nas últimas 2 h é **queimada**: a troca recusa esses IPs (até 4 reconexões trocando de endpoint, depois identidade nova), o `claim` entrega primeiro túneis de família boa e o `status` marca `(burned)`. Recusas aparecem como `exit-refused` em `recovery-events.jsonl`; `-Action stats` mostra a tabela de famílias.
- **Família = faixa estreita (warp-pool 1.4):** os primeiros 32 bits misturavam faixas boas e ruins. Medido em 26/11 (25 trocas): dentro de `2a09:bac5` o grupo `…:243c::39c:N` caía em 8 a 89 s, enquanto `…:297d::422:N`, `…:1c8c::2d8:N` e `…:1c96::2d9:N` duravam de 5 a 35 min. Agora a família é `h1:h2:*:h4::sufixo` (ex.: `2a09:bac5:*:243c::39c`; o 3º hextet só acompanha o endpoint). A memória fica em `poolamilies-v2.json`, semeada na primeira execução a partir de `rotation-history.jsonl`. **Queimada** = 2+ quedas rápidas nas últimas `WPOOL_BURNED_TTL_HOURS` (24 h) e as duas últimas foram rápidas; uma família que funcionou de manhã e passou a queimar é recusada logo, e um IP que dura a libera de novo.
- **Túnel livre em família queimada é trocado (1.4):** no `up` e a cada ciclo do vigia, um slot sem dono numa família queimada gira para uma família boa (evento `burned-replace`). Em 27/11, depois de religar o PC, os 4 túneis voltaram em famílias queimadas.
- **4 túneis = 4 famílias (1.4):** com `WPOOL_FAMILY_DEDUPE=1` (padrão), dois slots livres na mesma família contam como repetidos e o de cima gira (evento `family-collision`). Slot em uso nunca é girado por isso. Trocas automáticas têm pausa de 10 min por slot, para não registrar identidades em loop quando não há família livre.
- **Limpeza (v2.63):** túneis acima da quantidade configurada são parados e apagados no `up`, a menos que uma janela viva ainda os use. A primeira subida mostra o progresso (`pool\up-progress.json`).
- **Limitação:** destino IPv4-only sai pelo IPv4 compartilhado (CGNAT); IP próprio por instância exige IPv6 no destino (`opencode.ai` tem AAAA).

### Como rodar

Ligue em **Definições** (grupo **Pool de túneis**, em inglês *Egress pool*): `WPOOL_ENABLE=1`, `WPOOL_COUNT=4`, `WPOOL_PORT_BASE=42000`, e escolha **WIREGUARD** em *Ligação → Método de ligação*. Para várias janelas, também `MULTI_INSTANCE=1` (*Várias janelas*). Reinicie o launcher: o boot sobe `up` + `daemon` uma vez, com trava em `pool\startup.lock`. Os scripts ficam em `%LOCALAPPDATA%\opencode-infinite\` depois do instalador.

Na mão:

```powershell
powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\opencode-infinite\warp-pool.ps1" -Action status
powershell ... -File warp-pool.ps1 -Action up -Count 4 -PortBase 42000
powershell ... -File warp-pool.ps1 -Action claim -Instance janela01
powershell ... -File warp-pool.ps1 -Action rotate -Slot 1
powershell ... -File warp-pool.ps1 -Action down
```

Listar todas as ações: `up|status|claim|release|rotate|verify|down|daemon|reap|grow|boot|spawn|stats`. `grow` abre mais um túnel (até `-Max`/`WPOOL_MAX`); `spawn -Then boot|daemon` inicia o boot ou o vigia destacado; `stats` mostra o histórico de rotações por faixa `/64`. `-State` aponta a raiz do estado (padrão: `%LOCALAPPDATA%\opencode-infinite`), `-Slot` escolhe o slot no `rotate` e no `down` parcial, `-Instance` identifica a janela no `claim`/`release`. `-Force` no `rotate` gera identidade nova em vez de só reconectar. `-OwnerPid` no `claim` diz qual processo é o dono (padrão: quem chamou o script). `-AllowWarpTunnel` força o `up` com o app WARP conectado mesmo com `WPOOL_ALLOW_WARP_TUNNEL=0`.

Códigos de saída: `0` ok, `2` sem IP novo/distinto, `3` slot ou processo morto, `4` trava ocupada, `6` app WARP em modo túnel e não permitido, `7` nenhum slot livre, `8` pool já no máximo (`WPOOL_MAX`).

Memória medida (máquina com 63 GB): cada túnel ~28 MB físicos (~65 MB reservados), o Desktop ~1,2 GB (app + serviço), o vigia ~130 MB. Uma janela CLI deve ficar perto de 0,6 GB (estimativa pelo serviço do OpenCode). 8 túneis com 1 Desktop + 7 CLI dão ~6 GB; o limite prático é o Cloudflare e a sua internet, não a RAM.

Pool de CLIs em paralelo:

```powershell
powershell ... -File queue-add.ps1 -Prompt "resuma X"
powershell ... -File multi-dispatcher.ps1 -Pool on -Count 4 -Drain
```

No dispatcher, `auto` desativa o pool se `up=0` (volta ao caminho antigo), `on` exige slots up e aborta se não houver, e `off` mantém o caminho antigo. Cada worker recebe `HTTP_PROXY`/`HTTPS_PROXY` (e `http_proxy`/`https_proxy`) próprios, `NO_PROXY=127.0.0.1,localhost,::1` e `XDG_DATA_HOME`/`XDG_STATE_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` dentro da pasta do worker — um `XDG_*` herdado venceria o `USERPROFILE` isolado. Antes de cada lançamento o dispatcher faz um trace pelo proxy do worker; slot morto é girado uma vez e, se continuar morto, o item espera a próxima volta em vez de sair direto pelo IP da casa. `worker_start` registra `slot`, `ip` e `proxy`.

### Testes

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

---

## ▶️ Uso no dia a dia

| Quero... | Faço |
|---|---|
| Abrir normalmente | `INICIAR.bat` → **2 - 1 - 1** |
| Abrir com IP próprio, em paralelo (pool) | `INICIAR.bat` → **2 - 5 - 1**, uma vez por janela |
| Ver os túneis e os IPs | `POOL.bat` → **1** |
| Rodar pedidos sozinhos em paralelo | `FILA.bat "pedido"` e `FILA.bat dispatcher` |
| Abrir num projeto específico | arraste a pasta do projeto em cima do `INICIAR.bat` |
| Abrir pelo terminal | `opencodeinf` (criado no primeiro setup do launcher) |
| Trocar o IP na mão | *Iniciar o OpenCode* → *Trocar IP (teste)* |
| Mudar a mensagem de retomada, o modelo etc. | menu → **5. Definições** |

**Quando o limite grátis chega:** o launcher detecta a mensagem, pega um IP novo no WARP, confere que o IP mudou e envia a mensagem de retomada no **mesmo chat** que parou. Você não precisa fazer nada.

---

## ⚙️ Padrões

| Configuração | Valor | Onde mudar |
|---|---|---|
| Conexão | `WARP` (`WIREGUARD` para o pool) | Definições → Ligação → Método de ligação |
| Pool de túneis | desligado, 4 túneis, máximo 8 | Definições → Pool de túneis |
| Modelo da retomada | `opencode/deepseek-v4.1-flash-free#max` | Definições → Sessão → Modelo de retoma |
| Mensagem de retomada | `voltamos, pode continuar e retomar de onde parou` | Definições → Sessão |
| Ação no limite | `rotate` (troca o IP e continua) | Definições → Troca de IP |
| O que cada erro faz | limite grátis → troca o IP · limite do provedor/créditos → pergunta · contexto/modelo → nada | `%LOCALAPPDATA%\opencode-infinite\patterns.conf` |
| Idioma do OpenCode | qualquer um | — |
| Atualização do launcher | desligada | — |
| Idioma | português | Definições → Aparência |

Os arquivos de estado ficam em `%LOCALAPPDATA%\opencode-infinite\` (`config.json`, `launcher.log`, `resume.err`).

---

## 🔄 Atualizar

```powershell
cd openinfinite-code
git pull
```

Depois é só abrir o `INICIAR.bat`: ele percebe que os arquivos da pasta mudaram e atualiza a cópia instalada. Para reaplicar os padrões, rode o `INSTALAR.bat` de novo.

---

## 🧯 Problemas comuns

| Sintoma | Solução |
|---|---|
| *"O Windows protegeu o computador"* ao abrir um `.bat` do ZIP | Clique em **Mais informações → Executar assim mesmo**. Acontece com qualquer `.bat` baixado da internet; o instalador libera os outros arquivos da pasta. |
| O `INSTALAR.bat` instalou o Python/Node mas ainda diz que falta | Feche a janela e abra o `INSTALAR.bat` de novo: o Windows só atualiza o PATH em janelas novas. |
| *"WARP is not usable - OpenCode was not started"* | Abra o app do Cloudflare WARP uma vez e aceite os termos. Depois, no terminal: `warp-cli registration new` e `warp-cli connect`. |
| A retomada não acha o chat | Confira `python --version` no terminal. Se abrir a Microsoft Store, instale o Python pelo link acima marcando *Add to PATH*. |
| Desktop app aparece como *not installed* | Instale pelo <https://opencode.ai/download> e, no menu de modo, use *Detect the desktop app again*. |
| Bateu o limite e o launcher **perguntou** em vez de trocar o IP | O seu `patterns.conf` é antigo. Rode o `INSTALAR.bat`: ele guarda um backup e volta aos padrões. |
| Funciona com o OpenCode em português? | Sim. O launcher não lê o texto da tela: ele procura o código do erro (`provider.free-limit` / `Free usage limit reached`) no log e no banco do OpenCode, e isso é gravado em inglês em qualquer idioma da interface. |
| A janela do pool abriu no WARP | Todos os túneis estavam ocupados e o pool já estava no máximo. Feche uma janela ou aumente *Máximo de túneis*. |
| *ECONNRESET* e "Attempt 2 - retrying" | Um túnel travou e o vigia o reabriu; o OpenCode tenta de novo sozinho em segundos. |
| Quero ver os túneis | `POOL.bat` → 1, ou `%LOCALAPPDATA%\opencode-infinite\pool\pool-status.json` |
| Quero ver o que aconteceu | `%LOCALAPPDATA%\opencode-infinite\launcher.log` (o pool grava em `recovery-events.jsonl`) |
| Aparece pedido de atualização do launcher | Você está rodando uma cópia antiga: rode o `INSTALAR.bat` desta pasta. |
| Rodei um `.bat` baixado do projeto original | Ele pode substituir a cópia instalada se tiver versão maior. Rode o `INSTALAR.bat` desta pasta de novo para voltar a esta versão. |

---

## 📁 Estrutura

```text
openinfinite-code/
├── INSTALAR.bat            instala / atualiza tudo
├── INICIAR.bat             abre o launcher (caminho 2-1-1)
├── POOL.bat                menu do pool de túneis
├── FILA.bat                fila de pedidos em paralelo
├── launcher/
│   ├── OpenCode Infinite.bat   o launcher (WARP, rotação, retomada)
│   ├── warp-pool.ps1           pool de túneis (wgcf + wireproxy)
│   ├── multi-dispatcher.ps1    roda a fila, um túnel por worker
│   ├── queue-add.ps1           põe pedidos na fila
│   ├── device-reset.ps1        identidade separada por worker
│   ├── resume-runner.ps1       retomada pela CLI
│   ├── desktop-resume.ps1      retomada pelo serviço do Desktop
│   ├── resume-target.py        acha o chat que bateu o limite
│   ├── langs/  themes/
├── orchestrator/           agentes do orquestrador + guia
├── claude-bridge/          MCP Claude Code → OpenCode (opcional)
└── scripts/instalar.ps1    lógica do instalador
```

---

## 🗒️ Versões

### warp-pool.ps1 1.4
- Família de IP estreita (`h1:h2:*:h4::sufixo`), túnel livre em família queimada é trocado no `up` e pelo vigia, e os túneis livres ficam em famílias diferentes. `WPOOL_FAMILY_DEDUPE=0` volta ao comportamento antigo de dedupe.

### Launcher v2.63.1
- **Loop de 10 s no limite corrigido:** o pool aprende quais famílias de IP do WARP já chegam com o limite estourado (ex.: `2a09:bac1:…:36a8`) e não troca mais para elas; a troca desiste de um IP ruim em 2 medições em vez de esperar 20 s. `warp-pool.ps1` 1.3.

### Launcher v2.63.0
Pool WPOOL (`warp-pool.ps1` 1.2), as 8 correções do plano de revisão:

- **Várias janelas, vários IPs de verdade:** janela CLI do pool usa `--standalone` (servidor próprio) e não reinicia mais o serviço compartilhado; o Desktop fica com ele.
- **Desktop único:** uma segunda janela em modo Desktop vira CLI, com aviso, em vez de reaproveitar o app da outra janela (e o IP dela).
- **5ª janela nunca sai direto:** pede mais um túnel (`grow`, até `WPOOL_MAX`), espera ~1 min e, se não houver, usa o WARP.
- **Vigia destacado:** fechar a janela que subiu o pool não mata mais o vigia (`spawn -Then boot`).
- **Fila não perde pedidos:** worker sem túnel tenta de novo e o pedido fica na fila.
- **Checagem no `opencode.ai`** em vez de `www.cloudflare.com`.
- **Medição do limite por faixa:** `rotation-history.jsonl`, `-Action stats` e a opção `WPOOL_DEDUPE_PREFIX=64`.
- **Detecção do app WARP corrigida:** só o modo túnel conta como conflito; o modo proxy é sempre compatível.
- **Tradução** das opções do pool para português, limpeza de túneis extras e progresso na primeira subida.

### Launcher v2.62.1
Correções do pool WPOOL (`warp-pool.ps1` 1.1), medidas nesta máquina antes e depois:

- **Claim não expira mais com a janela viva:** na 2.62.0 o `reap` do daemon liberava todo claim depois de `WPOOL_LEASE_MIN` (15 min), mesmo em uso, e outra janela podia pegar o mesmo slot e o mesmo IP. Agora o dono é o processo da janela/dispatcher e só sai quando ele fecha.
- **Detecção do app WARP:** o `warp-cli` atual escreve `Status update: Connected`, que a 2.62.0 não reconhecia. Nova chave `WPOOL_ALLOW_WARP_TUNNEL` (padrão 1) decide se o pool roda por dentro do app.
- **Slots não morrem mais em cadeia:** o daemon reiniciava um slot sem parar o `wireproxy` antigo e sem o lock do slot, e dois `up` ao mesmo tempo registravam identidades por cima um do outro. Agora há `up.lock`, lock por slot, parada antes de subir, checagem de porta e só um restart depois de duas falhas seguidas.
- **`wireproxy` destacado:** o dispatcher não trava mais no `rotate` (handle herdado pelo pipe) e fechar a janela que subiu o pool não derruba os slots.
- **Rotate respeita `burned[]`**, colisão de IP gira o slot de verdade (antes só marcava `degraded`), e `instances\<instância>\egress.json` existe como no plano.
- **Launcher:** rotate sem IP novo mantém o slot da janela (antes caía no caminho antigo sem `.conf` e perguntava "continuar direto?"); o boot para de esperar assim que o `up` falha (`pool\up.rc`); o daemon também sobe quando o `up` termina com colisão ou sem slot.
- **Dispatcher:** `XDG_*` e proxy em minúsculas por worker, `::1` no `NO_PROXY`, trace pelo proxy antes de lançar, `slot`/`ip` no `worker_start`.
- **`PersistentKeepalive = 25`** nos perfis do pool.
- **Túnel travado reabre rápido e em outro endpoint:** às vezes o Cloudflare para de responder ao handshake de um slot por alguns minutos (medido: a mesma identidade responde em outros endpoints). O vigia confirma a falha na hora (segunda medição 3 s depois) e reabre o slot no próximo endpoint da lista (`162.159.192.1:2408`, `188.114.97.1:2408`, `162.159.195.1:2408`, `162.159.192.1:4500`, `188.114.96.1:500`). Antes, a janela ficava ~1 min pendurada até levar `ECONNRESET`. O endpoint atual aparece em `slotNN\slot.json` (`endpoint`).

### Launcher v2.62.0
O pool de egress WARP passou a fazer parte do launcher (os comentários do código usam `v2.62`):

- **Pool de egress WARP por slot:** cada janela sai pelo seu próprio túnel, com proxy local e saída IPv6 própria — o IPv4 free do WARP é CGNAT compartilhado, então o IPv6 é o que distingue os slots.
- **Chaves `WPOOL_*` no Settings:** `WPOOL_ENABLE`, `WPOOL_COUNT`, portas, lease e health check configuráveis pela interface; com o pool habilitado, ele sobe automaticamente no boot do launcher.
- **Claim / rotate / release por janela:** cada instância faz claim, rotação e release apenas do seu slot, sem lock global; o fechamento libera o slot; uma claim órfã pode ser limpa com warp-pool.ps1 -Action reap depois do lease.
- **`multi-dispatcher.ps1` com proxy por worker** e opção `-Pool on|off|auto` para escolher se cada worker usa o pool.
- **Correção da fila com 1 item:** o dispatcher não travava mais quando a fila tinha um único item.
- **Correção do claim após rotação:** depois da rotação, a janela passa a usar o novo IP/porta do seu slot em vez do claim antigo.

### Launcher v2.61.0
Correções trazidas do projeto original (até a 2.60.28), sem mexer nas nossas personalizações:

- **Checagem de TLS antes de abrir:** se o IP novo passa no teste do WARP mas o opencode.ai recusa a conexão segura ("SSL handshake failed"), troca de IP em vez de abrir num chat que vai cair. Esse erro no log também passa a disparar a troca.
- **Esperas com `ping` em vez de `timeout`:** o `timeout` aborta sem teclado ligado e podia matar uma troca de IP automática.
- **Loop ao sair** quando existe `config.json`.
- **Retomada mais segura:** só confia no resultado do ajudante do chat quando ele terminou sem erro.
- **Serviço do WARP checado pelo PowerShell**, o que funciona em qualquer idioma do Windows.
- **Banco de chats incompatível** é renomeado para `opencode.db.incompatible-*` (nunca apagado) e o OpenCode abre limpo.
- Pequenas correções: aspas do `%PSX%`, IP lido dentro de bloco, aviso quando o modo Auto falha de forma inesperada, variáveis de ambiente ausentes.

- **Limite grátis troca o IP sozinho já na primeira instalação:** antes, sem um `patterns.conf` pronto, o launcher criava um que só perguntava.

A versão subiu para **2.61.0**, acima de qualquer 2.60.x do original, para um `.bat` deles não substituir a cópia instalada por ser "mais novo".

---

## 📜 Créditos e licença

Baseado no [OpenCode Infinite](https://gitlab.com/jekooo/opencode-infinite) (GPL-3.0), com retomada pelo Desktop, padrões em português, DeepSeek V4.1 max, orquestrador, bridge para o Claude Code e sem a autoatualização do projeto original.
Distribuído sob a mesma licença: [GPL-3.0](LICENSE). Não é um projeto oficial do OpenCode nem da Cloudflare.
