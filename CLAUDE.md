# AI Limits (plugin do Tern)

Plugin do Tern que mostra os limites de uso dos planos de IA (Claude Code, Codex,
Cursor, Grok, Factory, OpenCode Go, Command Code e o que vier do omp) numa coluna
lateral, gaveta, cartão flutuante, aba, barra de status, título da janela e toasts.
Manifesto: `plugin.toml` (id `ai-limits`). Visão de usuário: `README.md`.

## Pasta de trabalho

Este repo (`C:\projetos2\tern-ai-limits`, remoto
`github.com/pfTheTrial/tern-ai-limits`) é a fonte única e é a pasta que o Tern
carrega: `%APPDATA%\Tern\plugins\ai-limits.path` aponta para cá (religado em
2026-10-19). Editar aqui e rodar `tern plugin reload` já testa no Tern.

`C:\projetos2\plugin_tern\ai-limits` é uma cópia antiga, sem Git, que o Tern não
carrega mais; não edite lá. `C:\projetos2\plugin_tern\strip` é outro plugin.

## Arquitetura

Dois "halves" que só conversam por `tern.kv`:

- **host** (`host.luau`, daemon): a cada N minutos roda `omp usage --json` e/ou os
  helpers PowerShell, normaliza com `model.luau`, aplica `prefs.luau`, grava
  amostras em `history.luau` (`history.json`, 1/h por 7 dias) e publica
  `snapshot`/`snapshot_all` no kv. Desenha os blocos `cards` e `dashboard` e a
  lens `omp usage` via `view.luau`.
- **window** (`window.luau`, UI): só registra comandos, chrome e eventos. Carrega
  sob demanda `win_core` (posicionamento do painel), `win_alerts` (peek, status,
  título, toasts), `win_settings` e `win_filters` (pickers). Nunca busca dados:
  só lê o kv.
- **Helpers** `*-usage.ps1`: imprimem um documento no formato do
  `omp usage --json` (`reports`, `disabledCredentials`, `generatedAt`).
  `cursor`/`grok` são "lentos" (polling mais espaçado). `keys-usage.ps1` cobre
  as chaves salvas no secret store do Tern (Factory, OpenCode Go, Command Code).
- `ai-limits.css`: tudo sob `.ail-root`. `icons/<provider>-{dark,light}.svg`.

## Regras do projeto

- **Orçamento de 50 ms** por entrada/hook da janela (o Tern compila para código
  nativo antes). Não junte módulos da janela nem adicione `require` no topo de
  `window.luau`; mantenha o carregamento preguiçoso existente.
- Todo arquivo `.luau` começa com `--!strict`. Siga o estilo: tabs, `snake_case`,
  comentários em inglês explicando o porquê.
- **i18n:** todo texto visível passa por `t("English", "Português")` (idioma em
  `tern.kv "lang"`; trocar recarrega o plugin). Nos `.ps1`, `T en pt` com
  `$env:AI_LIMITS_LANG`. Nunca adicione string só num idioma.
- **Credenciais:** os helpers só *leem* logins de outras ferramentas; nunca
  renovam, reescrevem nem registram tokens, e cada token vai só para a API do
  próprio provedor. Chaves do plugin ficam no secret store do Tern. Nada de
  segredo em log, toast, kv, `history.json` ou fixture.
- Helpers rodam em Windows PowerShell 5.1 (`powershell.exe -NoProfile
  -NonInteractive -ExecutionPolicy Bypass`): nada de sintaxe PS 7 (`??`, `?.`,
  ternário, `&&`). Erro esperado vira `disabledCredentials` com `cause`, saída 0.
- Endpoints de Cursor e Grok não são públicos; trate mudança de formato sem quebrar
  o snapshot inteiro.
- Arquivos com acentos estão em UTF-8; preserve a codificação ao editar.

## Verificação

- Testes: `powershell -File tests\run.ps1 [-Luau C:\caminho\luau.exe]`.
  Cobrem `model`, `prefs` e `history` com stub de `tern`. Precisa do CLI `luau`
  (https://github.com/luau-lang/luau/releases), que **não está no PATH** desta máquina.
- Carregamento real: `tern plugin reload` (sai 1 se algum plugin falhar) e
  `tern plugin list` deve mostrar `ai-limits ... ready`. Confira que
  `%APPDATA%\Tern\plugins\ai-limits.path` ainda aponta para este repo.
- Tipos: `tern plugin types <dir>` gera `tern.d.luau` para o luau-lsp (arquivo
  gerado; não versionar).
- Mudança visual exige ver no Tern (coluna, gaveta, cartão flutuante, aba,
  densidade compacta, tema claro/escuro, PT e EN).

## Subagentes (`.claude/agents/`)

| Agente | Modelo / esforço | Quando usar |
| --- | --- | --- |
| `luau-plugin-dev` | opus / high | Implementar ou corrigir lógica Luau (host, window, model, prefs, history, view) |
| `provider-reader` | sonnet / high | Criar ou ajustar helpers `*-usage.ps1` e o mapeamento de um provedor |
| `plugin-reviewer` | opus / high | Revisão só-leitura antes de commit: orçamento, strict, i18n, segredos |
| `plugin-verifier` | haiku / low | Rodar testes, `tern plugin reload/list` e relatar o resultado |
| `docs-i18n` | sonnet / low | README, strings `t(en, pt)` e textos de UI |

## Git

Branch `main`. Commit, push e mudanças de link do Tern só com pedido explícito.
