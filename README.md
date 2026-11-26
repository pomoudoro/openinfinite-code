<div align="center">

# ♾️ OpenInfinite Code

**OpenCode sem parar no limite grátis.**
Bateu o limite? Troca o IP pelo Cloudflare WARP e o chat continua sozinho, no mesmo ponto.

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
> | Início | **[2] Launch OpenCode** |
> | Conexão | **[1] WARP** |
> | Menu | **[1] New IP and start OpenCode** |
>
> Use **2-1-1** e não 1-1-1. O `[1] Auto opencode` da tela inicial pula tudo e abre uma sessão nova; o `[2]` passa pela escolha da conexão e pega um IP novo antes de abrir o OpenCode Desktop, que é o caminho testado com a retomada automática.
> O modo Desktop já vem salvo pelo instalador, por isso não aparece tela de modo nem de pasta (o próprio Desktop escolhe o projeto). Se o Desktop não estiver instalado, aparece a tela de modo antes da conexão.

---

## 🎁 O que vem no pacote

| | Recurso | Detalhe |
|---|---|---|
| 🌐 | **WARP** | Cloudflare WARP em modo proxy, só para o OpenCode. O resto do PC (navegador, outros apps) continua na conexão normal. |
| 🧠 | **DeepSeek V4.1 Flash Free (max)** | `opencode/deepseek-v4.1-flash-free#max` como modelo padrão do OpenCode e da retomada. |
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

O pool cria **N túneis WARP** com **um proxy local por slot**: cada instância sai pelo seu próprio proxy/IP. Como o IPv4 free do WARP é CGNAT compartilhado, o pool usa **IPv6 por device** para dar uma saída distinta a cada slot.

Ligue com `WPOOL_ENABLE=1` e `WPOOL_COUNT` no *Settings* (ou no `config.json`) e reinicie o launcher: ele sobe o pool e faz **claim / rotate / release** por janela automaticamente.

Na mão: `powershell -File warp-pool.ps1 -Action up|status|rotate|down` (use `-State "$env:LOCALAPPDATA\opencode-infinite"` para apontar outro diretório). No dispatcher: `powershell -File multi-dispatcher.ps1 -Pool on -Count N`.

**Limitação:** destino IPv4-only sai pelo IP compartilhado (CGNAT); para IP próprio por instância, o destino precisa falar IPv6.

---

## ▶️ Uso no dia a dia

| Quero... | Faço |
|---|---|
| Abrir normalmente | `INICIAR.bat` → **2 - 1 - 1** |
| Abrir num projeto específico | arraste a pasta do projeto em cima do `INICIAR.bat` |
| Abrir pelo terminal | `opencodeinf` (criado no primeiro setup do launcher) |
| Trocar o IP na mão | menu principal → *Change IP* |
| Mudar a mensagem de retomada, o modelo etc. | menu → *Settings* |

**Quando o limite grátis chega:** o launcher detecta a mensagem, pega um IP novo no WARP, confere que o IP mudou e envia a mensagem de retomada no **mesmo chat** que parou. Você não precisa fazer nada.

---

## ⚙️ Padrões

| Configuração | Valor | Onde mudar |
|---|---|---|
| Conexão | `WARP` | Settings → Connection |
| Modelo da retomada | `opencode/deepseek-v4.1-flash-free#max` | Settings → Session → Resume model |
| Mensagem de retomada | `voltamos, pode continuar e retomar de onde parou` | Settings → Session |
| Ação no limite | `rotate` (troca o IP e continua) | Settings → IP rotation |
| O que cada erro faz | limite grátis → troca o IP · limite do provedor/créditos → pergunta · contexto/modelo → nada | `%LOCALAPPDATA%\opencode-infinite\patterns.conf` |
| Idioma do OpenCode | qualquer um | — |
| Atualização do launcher | desligada | — |
| Idioma | português | Settings |

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
| Quero ver o que aconteceu | `%LOCALAPPDATA%\opencode-infinite\launcher.log` |
| Aparece pedido de atualização do launcher | Você está rodando uma cópia antiga: rode o `INSTALAR.bat` desta pasta. |
| Rodei um `.bat` baixado do projeto original | Ele pode substituir a cópia instalada se tiver versão maior. Rode o `INSTALAR.bat` desta pasta de novo para voltar a esta versão. |

---

## 📁 Estrutura

```text
openinfinite-code/
├── INSTALAR.bat            instala / atualiza tudo
├── INICIAR.bat             abre o launcher (caminho 2-1-1)
├── launcher/
│   ├── OpenCode Infinite.bat   o launcher (WARP, rotação, retomada)
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

A versão subiu para **2.61.0**, acima de qualquer 2.60.x do original, para um `.bat` deles não substituir a cópia instalada por ser "mais novo". A versão atual é **2.62.0**.

---

## 📜 Créditos e licença

Baseado no [OpenCode Infinite](https://gitlab.com/jekooo/opencode-infinite) (GPL-3.0), com retomada pelo Desktop, padrões em português, DeepSeek V4.1 max, orquestrador, bridge para o Claude Code e sem a autoatualização do projeto original.
Distribuído sob a mesma licença: [GPL-3.0](LICENSE). Não é um projeto oficial do OpenCode nem da Cloudflare.
