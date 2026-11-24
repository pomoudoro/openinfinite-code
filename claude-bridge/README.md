# Bridge Claude Code → OpenCode Infinite (opcional)

Servidor MCP local (stdio). O **Claude Code** planeja e revisa; o **OpenCode Infinite** executa com o **DeepSeek V4.1 Flash Free**, pela mesma conexão (WARP/Tor/Proxy) que o launcher escolheu.

## Ferramentas que aparecem no Claude Code

| Ferramenta | O que faz |
|---|---|
| `opencode_status` | Confere se o serviço do OpenCode Infinite está no ar. Não abre outro servidor. |
| `opencode_delegate` | Manda uma tarefa ao DeepSeek. Reaproveita uma sessão por projeto; `new_session=true` começa do zero. |

## Instalação

O `INSTALAR.bat` faz isso sozinho (passo 6/6) quando acha o `claude` e o `npm`. À mão:

```powershell
cd "$env:LOCALAPPDATA\opencode-infinite\claude-bridge"
npm install
claude mcp add --transport stdio --scope user opencode-infinite -- node "$env:LOCALAPPDATA\opencode-infinite\claude-bridge\bridge.mjs"
```

Reinicie o Claude Code e confira com `/mcp`.

## Uso

1. Abra o OpenCode Infinite pelo `INICIAR.bat` (caminho 2-1-1) e deixe aberto.
2. No Claude Code, peça para chamar `opencode_status` e depois `opencode_delegate` com a tarefa.

## Variáveis (opcionais)

| Variável | Padrão |
|---|---|
| `OPENCODE_MODEL` | `opencode/deepseek-v4.1-flash-free` |
| `OPENCODE_CLI` | caminho achado pelo launcher em `%LOCALAPPDATA%\opencode-infinite\opencode_path.txt` |
| `BRIDGE_INSTRUCTIONS` | `instructions.md` ao lado do `bridge.mjs`. Se o arquivo existir, ele é anexado a cada sessão delegada; se não existir, nada é anexado. |
| `OPENCODE_BRIDGE_TIMEOUT_MS` | 20 minutos |

O bridge **não** sobe um `opencode serve` próprio quando o serviço do Infinite está fora do ar: isso furaria o proxy escolhido no launcher.
