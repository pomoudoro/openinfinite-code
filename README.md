<div align="center">

# ♾️ OpenInfinite Code

**OpenCode sem parar no limite grátis.**
Bateu o limite? O IP é trocado sozinho e o chat continua no mesmo ponto, sem você fazer nada.

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)
![OpenCode](https://img.shields.io/badge/OpenCode-Desktop%20%2B%20CLI-111111)
![Modelo](https://img.shields.io/badge/modelo-DeepSeek%20V4.1%20Flash%20(max)-4D6BFE)
![WARP](https://img.shields.io/badge/egress-Cloudflare%20WARP-F38020?logo=cloudflare&logoColor=white)
![Licença](https://img.shields.io/badge/licen%C3%A7a-GPL--3.0-blue)

</div>

---

## 💡 Como funciona, em 30 segundos

- O OpenCode tem modelos grátis, mas com um **limite de mensagens por IP**. Quando ele chega, aparece *"You've used today's free messages"*.
- O OpenInfinite Code fica de olho nisso. Quando o limite chega, ele **troca o IP** (pelo Cloudflare WARP, de graça) e manda no **mesmo chat**: *"voltamos, pode continuar e retomar de onde parou"*.
- Só o OpenCode passa pelo IP trocado. O navegador e o resto do PC continuam na sua conexão normal.

> [!NOTE]
> Isso funciona porque hoje o limite é contado **por IP**. Se um dia o OpenCode passar a contar por conta, trocar de IP não ajuda mais.

---

## 🧭 WARP ou pool de túneis? Qual usar

Há dois jeitos de trocar o IP. O instalador pergunta qual você quer, e dá para mudar depois.

| | **Pool de túneis** *(recomendado)* | **WARP simples** |
|---|---|---|
| Para quem | Quer **várias conversas ao mesmo tempo**, ou só quer a troca mais rápida | Usa **uma conversa por vez** |
| IPs | Cada janela tem o **próprio IP** (4 túneis prontos, até 8) | Um IP só, para o OpenCode inteiro |
| Quando o limite chega | Só a janela que bateu troca. A janela do Desktop pula **na hora** para um túnel reserva já testado | Troca o IP de tudo; leva de alguns segundos a ~1 min |
| Faixas de IP "queimadas" | Aprende quais faixas do WARP voltam ao limite em segundos e foge delas | Pode cair de novo numa faixa ruim |
| Precisa instalar algo a mais? | Não. Na primeira vez baixa sozinho o `wgcf` e o `wireproxy` (~2 min) | Não |
| Como abrir | `INICIAR-POOL.bat` (direto) ou `INICIAR.bat` → **2 - 5 - 1** | `INICIAR.bat` → **2 - 1 - 1** |

> [!TIP]
> No menu do launcher o pool aparece com o nome **WIREGUARD** (opção 5). É o mesmo WARP da Cloudflare, mas com vários túneis WireGuard próprios em vez do app.

O launcher também tem **Tor**, **proxies HTTP grátis** e **VPN Gate**. Use só se o WARP não funcionar na sua rede: são mais lentos ou menos estáveis, e o VPN Gate pede administrador.

---

## 🆚 Este projeto ou o OpenCode Infinite original?

Este projeto nasceu do [OpenCode Infinite](https://gitlab.com/jekooo/opencode-infinite) e traz as correções do launcher dele até a versão mais recente (**2.60.28**). A diferença é o caminho: o original apostou num **app Desktop próprio** (um OpenCode modificado), e este aposta no **launcher com o OpenCode oficial** e em **várias conversas em paralelo**.

*Comparado com o original v2.60.31 / Desktop 2.2.32, em 27/11/2026.*

| Recurso | Este | Original | Vence |
|---|:-:|:-:|---|
| Troca o IP sozinho no limite e continua no mesmo chat | ✅ | ✅ | empate |
| Testa o IP novo num chat temporário antes de retomar | ✅ | ✅ | empate |
| WARP, Tor, proxies grátis, SOCKS5, VPN Gate | ✅ | ✅ | empate |
| **Várias conversas ao mesmo tempo, cada uma com IP próprio** (pool de túneis) | ✅ | ❌ | **este** |
| **Aprende faixas de IP "queimadas"** e foge delas | ✅ | ❌ (só lembra IPs já usados) | **este** |
| **Troca instantânea** para um túnel reserva já testado | ✅ | ❌ | **este** |
| Painel com gráfico de quanto cada IP durou | ✅ | ❌ | **este** |
| Fila de pedidos rodando em paralelo (`FILA.bat`) | ✅ | ❌ | **este** |
| Instalador que confere e instala Python, WARP, Node e Desktop | ✅ | ❌ | **este** |
| Em português, com DeepSeek V4.1 max e mensagem de retomada já configurados | ✅ | parcial (tem tradução) | **este** |
| Orquestrador de agentes e bridge para o Claude Code | ✅ | ❌ | **este** |
| Usa o **OpenCode Desktop oficial** (atualiza pela própria OpenCode) | ✅ | ❌ (app modificado, instalador sem assinatura) | **este** |
| Só scripts que dá para ler; nada se atualiza sozinho por baixo dos panos | ✅ | ❌ (tem atualizador próprio) | **este** |
| Testes automáticos a cada push | ✅ | ❌ | **este** |
| App com botões (Auto, Reset limit, Status, Stop) em vez de menu de terminal | ❌ | ✅ | **original** |
| Funciona **sem o app Cloudflare WARP** instalado (WARP embutido) | ❌ | ✅ | **original** |
| Linux e macOS | ❌ (só Windows) | ✅ | **original** |
| Retomada invisível (sem mensagem no chat) | ❌ (manda "voltamos, pode continuar…") | ✅ | **original** |
| Mullvad, Windscribe e Route64 | ❌ | ✅ (no app) | **original** |
| Provedores DeepAI e OmniRoute prontos | ❌ | ✅ | **original** |
| Releases com `SHA256SUMS` para conferir o download | ❌ (clone ou ZIP do GitHub) | ✅ | **original** |

**Use este se:** você está no Windows, quer **mais de uma conversa ao mesmo tempo**, quer que a troca de IP **não caia de novo numa faixa ruim**, e prefere o OpenCode oficial com scripts que dá para ler.

**Use o original se:** você está no Linux ou no Mac, quer um app com botões, ou não quer instalar o app do Cloudflare WARP.

---

## 📦 O que precisa ter

Só Windows 10 ou 11. O `INSTALAR.bat` confere tudo e oferece instalar o que faltar (pelo **winget**).

| Programa | Para quê | Precisa? |
|---|---|---|
| **Cloudflare WARP** | trocar o IP | ✅ sim — <https://1.1.1.1/> |
| **Python 3** | achar o chat que bateu o limite para continuar nele | ✅ sim — <https://www.python.org/downloads/windows/> *(marque "Add python.exe to PATH")* |
| **OpenCode Desktop** | o app onde você conversa | ✅ sim — <https://opencode.ai/download> |
| **Node.js LTS** | bridge do Claude Code (opcional) | recomendado — <https://nodejs.org/en/download> |
| **Git** | clonar e atualizar | só se for clonar (dá para baixar o ZIP) — <https://git-scm.com/download/win> |

O comando `opencode` (a versão de terminal) não precisa ser instalado à mão: se faltar, o launcher baixa sozinho.

---

## ⚡ Instalar

**1. Baixe o projeto** (um dos dois):

```powershell
git clone https://github.com/pomoudoro/openinfinite-code.git
```

ou, sem Git: no GitHub, **Code → Download ZIP** e extraia a pasta (por exemplo em `Documentos\openinfinite-code`).

**2. Dê dois cliques em `INSTALAR.bat`.** Ele:
- confere Python, WARP, OpenCode Desktop e Node.js, e oferece instalar o que faltar;
- copia o launcher para `%LOCALAPPDATA%\opencode-infinite\`;
- grava os padrões: português, modelo `deepseek-v4.1-flash-free#max`, troca de IP automática e a mensagem de retomada;
- **pergunta se você quer o pool de túneis** (Enter = sim) e já deixa tudo ligado;
- termina com **"Pronto"** ou com a lista do que ainda falta, com os links.

Instale o que faltar e rode o `INSTALAR.bat` de novo até aparecer "Pronto". Ele pode rodar quantas vezes você quiser: nada é apagado e tudo que ele troca ganha um backup antes.

> [!IMPORTANT]
> **Primeira vez com o WARP:** abra o app **Cloudflare WARP** uma vez e aceite os termos. Sem isso, o launcher avisa *"WARP is not usable"*.

---

## ▶️ Primeiro uso

**Com o pool (recomendado):** dois cliques em **`INICIAR-POOL.bat`**.
- Na primeira vez ele prepara os túneis, o que pode levar ~2 minutos (mostra o progresso). Das próximas vezes é rápido.
- Abre o OpenCode Desktop já num túnel próprio.
- **Quer outra conversa ao mesmo tempo?** Abra o `INICIAR-POOL.bat` de novo. A segunda janela em diante abre o OpenCode no terminal (o Desktop só abre uma vez por PC), cada uma com o seu IP.

**Sem o pool:** dois cliques em **`INICIAR.bat`** e siga **2 → 1 → 1**:

| Tela | Escolha |
|---|---|
| Início | **[2] Iniciar o OpenCode** |
| Conexão | **[1] WARP** |
| Menu | **[1] Nova IP e iniciar o OpenCode** |

> [!TIP]
> Use o **[2]** da tela inicial, não o [1] *opencode automático*: o [1] pula as escolhas e abre uma sessão nova, enquanto o [2] passa pela conexão e pega um IP novo antes de abrir o Desktop, que é o caminho testado com a retomada automática.

Depois é só conversar. **Quando o limite chegar, você não precisa fazer nada:** o launcher troca o IP, confere que mudou e manda a mensagem de retomada no mesmo chat.

---

## 🗓️ Dia a dia

| Quero... | Faço |
|---|---|
| Abrir | `INICIAR-POOL.bat` (pool) ou `INICIAR.bat` → **2 - 1 - 1** (WARP) |
| Abrir num projeto específico | arraste a pasta do projeto em cima do `INICIAR-POOL.bat` ou do `INICIAR.bat` |
| Outra conversa em paralelo | abra o `INICIAR-POOL.bat` de novo |
| Ver os túneis e os IPs | `POOL.bat` → **1** |
| Acompanhar o pool numa página | `POOL.bat` → **9**: gráfico de quanto cada IP durou, túneis, faixas boas e queimadas, últimas trocas. Recarrega sozinha |
| Ver faixas de IP boas e queimadas | `POOL.bat` → **8** |
| Arrumar a pasta de estado | `POOL.bat` → **L** (arquiva cópias antigas; não apaga nada) |
| Rodar pedidos sozinhos em paralelo | `FILA.bat "pedido"` e depois `FILA.bat dispatcher` dentro da pasta do projeto |
| Trocar o IP na mão | no `INICIAR.bat`: *Iniciar o OpenCode* → *Trocar IP (teste)* |
| Mudar modelo, mensagem de retomada etc. | `INICIAR.bat` → **5. Definições** |

**Ligar ou desligar o pool depois:** rode o `INSTALAR.bat` de novo (ele pergunta), ou em `INICIAR.bat` → **5. Definições**:

| Grupo | Opção | Pool ligado |
|---|---|---|
| Ligação | Método de ligação | **WIREGUARD** |
| Pool de túneis | Usar o pool de túneis | **Ativado** |
| Pool de túneis | Túneis no pool | **4** (até 16) |
| Inicialização | Várias janelas | **Ativado** |

Cada janela extra usa cerca de 0,6 GB de RAM; cada túnel, uns 30 MB.

---

## 🔄 Atualizar

```powershell
cd openinfinite-code
git pull
```

Depois é só abrir o `INICIAR.bat` ou o `INICIAR-POOL.bat`: eles percebem que os arquivos mudaram e atualizam a cópia instalada sozinhos (inclusive as traduções). Quem baixou o ZIP baixa de novo e roda o `INSTALAR.bat`.

---

## 🧯 Problemas comuns

| Sintoma | Solução |
|---|---|
| *"O Windows protegeu o computador"* ao abrir um `.bat` do ZIP | **Mais informações → Executar assim mesmo**. Acontece com qualquer `.bat` baixado da internet; o instalador libera os outros arquivos da pasta. |
| O `INSTALAR.bat` instalou o Python/Node mas ainda diz que falta | Feche a janela e abra o `INSTALAR.bat` de novo: o Windows só atualiza o PATH em janelas novas. |
| *"WARP is not usable - OpenCode was not started"* | Abra o app do Cloudflare WARP uma vez e aceite os termos. Se continuar, no terminal: `warp-cli registration new` e `warp-cli connect`. |
| O `INICIAR-POOL.bat` diz que o pool está desligado | Rode o `INSTALAR.bat` e responda sim ao pool, ou ligue nas Definições (tabela acima). |
| No 2-5-1 o launcher pede arquivos `.conf` ou pergunta "continuar direto?" | O pool está desligado: o WIREGUARD sem pool procura arquivos `.conf` seus. Responda **N** e ligue o pool. |
| A janela do pool abriu no WARP | Todos os túneis estavam ocupados e o pool já estava no máximo. Feche uma janela ou aumente *Máximo de túneis*. |
| A retomada não acha o chat | Confira `python --version` no terminal. Se abrir a Microsoft Store, instale o Python pelo link acima marcando *Add to PATH*. |
| Desktop app aparece como *not installed* | Instale pelo <https://opencode.ai/download> e, no menu de modo, use *Detect the desktop app again*. |
| Bateu o limite e o launcher **perguntou** em vez de trocar o IP | O seu `patterns.conf` é antigo. Rode o `INSTALAR.bat`: ele guarda um backup e volta aos padrões. |
| *ECONNRESET* e "Attempt 2 - retrying" | Um túnel travou e o vigia o reabriu; o OpenCode tenta de novo sozinho em segundos. |
| Funciona com o OpenCode em português? | Sim. O launcher procura o código do erro no log e no banco do OpenCode, que fica em inglês em qualquer idioma da interface. |
| Quero ver o que aconteceu | `%LOCALAPPDATA%\opencode-infinite\launcher.log` (o pool grava em `recovery-events.jsonl`). |
| Aparece pedido de atualização do launcher, ou rodei um `.bat` do projeto original | Rode o `INSTALAR.bat` desta pasta de novo para voltar a esta versão. |

---

## 🎁 Extras que vêm junto

| | Recurso | Detalhe |
|---|---|---|
| 🧠 | **DeepSeek V4.1 Flash Free (max)** | modelo padrão do OpenCode e da retomada. Para trocar: **5. Definições → Sessão**. |
| 🎯 | **Orquestrador** | agentes `orchestrator`, `builder`, `tester`, `reviewer`, `researcher`, `reverser`, `ask` e `debug`. No OpenCode, troque com **Tab**. Veja [orchestrator/](orchestrator/README.md). |
| 🤝 | **Bridge Claude Code** *(opcional)* | o Claude Code delega tarefas ao DeepSeek pelo OpenCode Infinite. Veja [claude-bridge/](claude-bridge/README.md). |
| 🚫 | **Sem update de terceiros** | a autoatualização do launcher original foi removida: nada troca esta versão por baixo dos panos. |

---

## 🛠️ Para quem quer mexer no projeto

- **Como o pool funciona por dentro**, comandos do `warp-pool.ps1` e testes manuais: [docs/pool.md](docs/pool.md)
- **O que mudou em cada versão:** [CHANGELOG.md](CHANGELOG.md)
- **Testes automáticos** (sem túnel, sem rede): `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1`. O GitHub Actions roda os mesmos testes a cada push.
- **Onde ficam os dados:** `%LOCALAPPDATA%\opencode-infinite\` (`config.json`, `launcher.log`, `pool\`, `backup\`).

```text
openinfinite-code/
├── INSTALAR.bat            instala / atualiza / liga o pool
├── INICIAR.bat             abre o launcher (menu)
├── INICIAR-POOL.bat        abre direto no pool, sem menus
├── POOL.bat                menu do pool: túneis, painel, stats, limpeza
├── FILA.bat                fila de pedidos em paralelo
├── launcher/               o launcher, o pool (warp-pool.ps1), a retomada, idiomas e temas
├── orchestrator/           agentes do orquestrador
├── claude-bridge/          MCP Claude Code → OpenCode (opcional)
├── scripts/instalar.ps1    lógica do instalador
├── docs/                   documentação técnica
└── tests/                  testes automáticos
```

---

## 📜 Créditos e licença

Baseado no [OpenCode Infinite](https://gitlab.com/jekooo/opencode-infinite) (GPL-3.0), com retomada pelo Desktop, pool de túneis, padrões em português, DeepSeek V4.1 max, orquestrador, bridge para o Claude Code e sem a autoatualização do projeto original.
Distribuído sob a mesma licença: [GPL-3.0](LICENSE). Não é um projeto oficial do OpenCode nem da Cloudflare.
