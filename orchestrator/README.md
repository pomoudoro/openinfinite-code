# Orquestrador: modos e agentes

O `INSTALAR.bat` copia os agentes desta pasta para `%USERPROFILE%\.config\opencode\agents\`, assim eles ficam disponíveis em **qualquer projeto**. No OpenCode, aperte **Tab** para trocar de agente e escolha `orchestrator`.

> Prefere por projeto? Copie `agents\` para `.opencode\agents\` dentro do projeto.

## Regra de bolso

| Modo | Em uma frase | Edita arquivo? |
|---|---|---|
| `orchestrator` | Decompõe, delega a subagentes, acompanha e sintetiza. | Não |
| `build` *(nativo)* | Implementa direto: edita, compila, roda o comando. | Sim |
| `plan` *(nativo)* | Analisa, mapeia, planeja e revisa sem alterar. | Não |
| `ask` | Responde pergunta sobre o código com citação `arquivo:linha`. | Não |
| `debug` | Reproduz a falha, prova a causa raiz e corrige com diff mínimo. | Sim |

## Subagentes que o orquestrador usa

| Precisa de | Subagente |
|---|---|
| Localizar arquivos, símbolos, fluxo ou dependências | `explore` *(nativo)* |
| Implementar, corrigir, refatorar ou compilar | `builder` |
| Rodar build e testes, ler artefatos e comparar com a baseline | `tester` |
| Investigar binário, offsets, protocolo | `reverser` |
| Revisar o diff, procurar regressões | `reviewer` |
| Consultar documentação externa, API ou versão | `researcher` |
| Tarefa multi-etapa fora das categorias acima | `general` *(nativo)* |

## Pipeline padrão

```text
explore (se precisar) → builder → tester → reviewer → builder corrige → tester repete
```

Termina em **(a) fechado**: testes verdes e revisão sem achado bloqueante; ou **(b) pendência explícita**: o que falta, por quê, e qual artefato comprova o estado atual.

## Contrato de prompt (todo pedido a um subagente leva os 5 campos)

| Campo | Conteúdo |
|---|---|
| Objetivo | Uma frase verificável ("fazer Y passar em Z", não "melhorar X"). |
| Caminhos relevantes | Arquivos e pastas que o subagente lê antes de agir. |
| Restrições | O que não pode mudar: arquivos, estilo, encoding, escopo. |
| Critério de aceite | Comando, saída, arquivo ou contagem que comprova. |
| Formato do relatório | Status, arquivos alterados, comandos, saída, pendências, próximo passo. |

## Quando trocar de modo

- Cabe em 1 ou 2 arquivos, causa conhecida e aceite óbvio: **`build`**.
- Apareceu um 3º arquivo, atravessa módulos ou precisa de revisão independente: **`orchestrator`**.
- Falha reproduzível com causa desconhecida: **`debug`**.
- Só entender ou planejar, sem gravar: **`plan`** ou **`ask`**.
- Pergunta conversacional ("como funciona X?"): responda direto; não monte pipeline.

## Regras que valem em todos os modos

- Não inventar resultado: sem comando e saída, não está provado.
- Teste que falha não se conserta editando o teste.
- Preservar encoding, BOM e quebra de linha; seguir o estilo do arquivo vizinho.
- Sem refatoração de carona.
