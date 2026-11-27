# Versões

O que mudou em cada versão do launcher e do `warp-pool.ps1`, da mais nova para a mais antiga.

## Em desenvolvimento

- **Correção: `INICIAR-POOL.bat` não achava o `desktop-resume.ps1`.** O `shift` da leitura dos argumentos (`--pool`, `--warp`...) também desloca o `%0`, então o `%~dp0` passava a apontar para a pasta atual e a retomada pelo Desktop caía no caminho de terminal. O launcher agora guarda a própria pasta (`OCI_DIR`) antes de ler os argumentos.
- **Memória de faixa queimada: 72 h** (era 24). Medido em 27/11: a faixa `2a09:bac1:*:36a8::39c`, queimada em 26/11 às 08:50, foi esquecida às 08:50 do dia seguinte, e a troca instantânea das 09:50 voltou direto para ela.
- **O vigia do pool se atualiza sozinho:** quando o `INICIAR.bat` copia um `warp-pool.ps1` novo, o vigia em execução percebe, sai e sobe a versão nova (antes ficava com o código antigo até reiniciar o PC). `warp-pool.ps1` 1.9.
- **Túnel reaberto pelo vigia também foge de faixa queimada** (`warp-pool.ps1` 1.9.1): em 27/11 09:57 um túnel livre que perdeu a conexão voltou em `36a8::39c`. Se só uma faixa queimada responder, o túnel volta assim mesmo e é trocado depois.
- Primeira retomada invisível no terminal num limite de verdade (27/11 09:50): 6 permissões aprovadas sozinho, resposta concluída em 75 s.
- **Retomada invisível nas janelas de terminal:** em vez de `opencode run` (que grava uma mensagem de usuário), o `resume-runner.ps1` sobe um servidor privado (`opencode serve`, com o proxy do túnel e senha gerada na hora), troca o modelo da conversa se for preciso, manda a retomada como mensagem *synthetic*, aprova permissões sozinho quando o `--auto` está ligado, espera a resposta terminar e encerra o servidor. Testado no OpenCode 2.3.2: a resposta termina em ~2 s e nenhuma mensagem de usuário fica no chat. Se o servidor não subir ou a conversa não existir, volta para o `opencode run` visível sem mandar nada antes.

## v2.64.0

Primeira versão publicada como release, com `SHA256SUMS`. Reúne tudo desde a 2.63.1:

- **Retomada invisível no Desktop:** depois da troca de IP, a IA recebe uma instrução oculta (mensagem *synthetic* do OpenCode oficial, sem `description`, que o Desktop não mostra) e continua de onde parou. Sem rota sintética, volta sozinho para a mensagem normal. Opção *Retomada invisível* em Definições → Sessão (ligada); vale com o modo de retomada *continue*. A checagem de envio repetido também enxerga a mensagem oculta.
- **Releases com `SHA256SUMS`:** ZIP versionado e checksums publicados pelo GitHub Actions a cada tag `v*`.
- **Pool de túneis:** família de IP estreita, troca de túnel em faixa queimada, um túnel por família, troca instantânea, melhor família primeiro, painel com gráficos, `stats` por túnel, `tidy`, logs com limite (`warp-pool.ps1` 1.4 a 1.8).
- **Uso:** `INICIAR-POOL.bat` e `--pool`, instalador que liga o pool, README para o usuário, comparação com o original, traduções sincronizadas pelo `INICIAR.bat`.
- **Qualidade:** testes automáticos e GitHub Actions.

## warp-pool.ps1 1.8
- **Gráficos no painel:** cada troca dos últimos 7 dias (quanto o IP antigo durou; vermelho = limite em menos de 2 min, verde = 5 min ou mais, quadrado = troca instantânea) e a duração mediana por família. SVG dentro da página, sem biblioteca, segue o tema claro/escuro.
- **`stats`** começa pela tabela dos túneis de agora com família, nota e queimada.
- **Traduções:** as opções novas do pool e o aviso do `--pool` em português (`langs\pt.json`); o `INICIAR.bat` passa a copiar as traduções para a instalação (antes só o `INSTALAR.bat` copiava).
- `warp-pool.ps1` só com ASCII (o PowerShell 5.1 lê `.ps1` sem BOM como ANSI e quebrava os acentos); um teste garante isso. 72 verificações no total.

## warp-pool.ps1 1.7
- **Testes automáticos** (`tests\run-tests.ps1`, sem dependências) e **GitHub Actions**.
- **Logs com limite** (`recovery-events.jsonl` 2 MB, `rotation-history.jsonl` 1 MB; o excesso vai para `.1`).
- **`-Action tidy`** / `POOL.bat` → **L**: arquiva cópias antigas da pasta de estado; `-Prune` apaga cópias antigas do banco de chats e `.bak` velhos.
- Correção: trocas automáticas não mexem mais em slot com claim `lease`.

## warp-pool.ps1 1.6
- **Painel:** `-Action dashboard` (ou `POOL.bat` → 9) gera `pool\dashboard.html` com túneis (IP, família, nota, estado, janela), famílias por nota, últimas trocas (quanto cada IP durou, troca instantânea ou não) e eventos. O vigia regrava a página a cada ciclo e ela recarrega a cada 30 s. Tema claro e escuro.
- **Atalho direto:** `INICIAR-POOL.bat` e a opção `--pool` do launcher abrem no caminho 2-5-1 sem menus. Com o pool desligado, avisa e não abre.
- `POOL.bat` ganhou **8 - stats** e **9 - painel** (também `POOL.bat stats` e `POOL.bat painel`).

## warp-pool.ps1 1.5
- **Troca instantânea:** no limite, a janela Desktop pula na hora para um túnel livre já verificado numa família boa; o túnel antigo gira em segundo plano. `WPOOL_FAST_SWAP=0` desliga.
- **Melhor família primeiro:** `claim` e troca instantânea escolhem a família com melhor histórico; túnel livre com o IP no próprio `burned[]` vai para o fim da fila.
- Duas opções novas no menu Definições → Pool de túneis: *One tunnel per IP family* e *Instant swap on limit*.

## warp-pool.ps1 1.4
- Família de IP estreita (`h1:h2:*:h4::sufixo`), túnel livre em família queimada é trocado no `up` e pelo vigia, e os túneis livres ficam em famílias diferentes. `WPOOL_FAMILY_DEDUPE=0` volta ao comportamento antigo de dedupe.

## Launcher v2.63.1
- **Loop de 10 s no limite corrigido:** o pool aprende quais famílias de IP do WARP já chegam com o limite estourado (ex.: `2a09:bac1:…:36a8`) e não troca mais para elas; a troca desiste de um IP ruim em 2 medições em vez de esperar 20 s. `warp-pool.ps1` 1.3.

## Launcher v2.63.0
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

## Launcher v2.62.1
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

## Launcher v2.62.0
O pool de egress WARP passou a fazer parte do launcher (os comentários do código usam `v2.62`):

- **Pool de egress WARP por slot:** cada janela sai pelo seu próprio túnel, com proxy local e saída IPv6 própria — o IPv4 free do WARP é CGNAT compartilhado, então o IPv6 é o que distingue os slots.
- **Chaves `WPOOL_*` no Settings:** `WPOOL_ENABLE`, `WPOOL_COUNT`, portas, lease e health check configuráveis pela interface; com o pool habilitado, ele sobe automaticamente no boot do launcher.
- **Claim / rotate / release por janela:** cada instância faz claim, rotação e release apenas do seu slot, sem lock global; o fechamento libera o slot; uma claim órfã pode ser limpa com warp-pool.ps1 -Action reap depois do lease.
- **`multi-dispatcher.ps1` com proxy por worker** e opção `-Pool on|off|auto` para escolher se cada worker usa o pool.
- **Correção da fila com 1 item:** o dispatcher não travava mais quando a fila tinha um único item.
- **Correção do claim após rotação:** depois da rotação, a janela passa a usar o novo IP/porta do seu slot em vez do claim antigo.

## Launcher v2.61.0
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
