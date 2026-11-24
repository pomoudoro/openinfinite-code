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

```powershell
git clone https://github.com/pomoudoro/openinfinite-code.git
```

1. Abra a pasta e dê dois cliques em **`INSTALAR.bat`**.
2. Dê dois cliques em **`INICIAR.bat`**.
3. No menu, siga o caminho **2 → 1 → 1**:

> [!TIP]
> ### ✅ Caminho recomendado: `2 - 1 - 1`
> | Tela | Escolha |
> |---|---|
> | Modo | **[2] Desktop app** |
> | Pasta | **[1] Reabrir a última pasta** |
> | Conexão | **[1] WARP** |
>
> Use **2-1-1** e não 1-1-1. O `1` na primeira tela abre a CLI no terminal; o `2` abre o OpenCode Desktop, que é o modo testado com a retomada automática.
> Na primeira vez ainda não há "última pasta": escolha a pasta do projeto e, a partir daí, é sempre 2-1-1.

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
2. **Launcher:** copia `launcher\*` para `%LOCALAPPDATA%\opencode-infinite\app\`.
3. **Padrões do launcher** (`config.json`): WARP, português, modelo `deepseek-v4.1-flash-free#max`, mensagem de retomada, rotação automática, update de terceiros desligado. Num `config.json` que já existe, preenche só o que estiver vazio.
4. **Modelo padrão do OpenCode** (`%USERPROFILE%\.config\opencode\opencode.json`): grava `opencode/deepseek-v4.1-flash-free#max`. Se você já tem outro modelo, ele pergunta antes.
5. **Orquestrador:** copia os agentes para `%USERPROFILE%\.config\opencode\agents\`.
6. **Bridge Claude Code** *(opcional)*: `npm install` e `claude mcp add` (só se o `claude` existir).

Opções: `INSTALAR.bat -Sim` (responde sim a tudo) · `INSTALAR.bat -SemDependencias` (pula a etapa 1).

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
| *"WARP is not usable - OpenCode was not started"* | Abra o app do Cloudflare WARP uma vez e aceite os termos. Depois, no terminal: `warp-cli registration new` e `warp-cli connect`. |
| A retomada não acha o chat | Confira `python --version` no terminal. Se abrir a Microsoft Store, instale o Python pelo link acima marcando *Add to PATH*. |
| Desktop app aparece como *not installed* | Instale pelo <https://opencode.ai/download> e, no menu de modo, use *Detect the desktop app again*. |
| Quero ver o que aconteceu | `%LOCALAPPDATA%\opencode-infinite\launcher.log` |
| Aparece pedido de atualização do launcher | Você está rodando uma cópia antiga: rode o `INSTALAR.bat` desta pasta. |

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

## 📜 Créditos e licença

Baseado no [OpenCode Infinite](https://gitlab.com/jekooo/opencode-infinite) (GPL-3.0), com retomada pelo Desktop, padrões em português, DeepSeek V4.1 max, orquestrador, bridge para o Claude Code e sem a autoatualização do projeto original.
Distribuído sob a mesma licença: [GPL-3.0](LICENSE). Não é um projeto oficial do OpenCode nem da Cloudflare.
