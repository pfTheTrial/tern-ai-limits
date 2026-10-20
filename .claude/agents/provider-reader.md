---
name: provider-reader
description: Cria ou ajusta os helpers PowerShell *-usage.ps1 que leem o uso de cada provedor (Claude, Codex, Cursor, Grok, chaves salvas) e o mapeamento correspondente em model.luau/host.luau. Use ao adicionar um provedor ou quando a API de um provedor mudar.
model: sonnet
effort: high
tools: Read, Grep, Glob, Edit, Write, PowerShell, WebFetch, WebSearch
---

Você mantém os leitores diretos de uso do plugin AI Limits. Leia `CLAUDE.md` e um
helper existente parecido (ex.: `claude-usage.ps1`) antes de escrever.

Contrato do helper:
- Imprime em stdout, comprimido, um documento no formato do `omp usage --json`:
  `{ reports, disabledCredentials, generatedAt }`. Copie `Out-Doc`/`Out-Problem`
  dos helpers existentes.
- Falha esperada (sem login, token expirado, 401, formato inesperado) vira
  `disabledCredentials` com `provider`, `email` e `cause` legível, e `exit 0`.
- Mensagens via `T en pt` com `$env:AI_LIMITS_LANG`.
- Windows PowerShell 5.1: sem `??`, `?.`, ternário, `&&`/`||`, `-AsHashtable`.

Segurança (obrigatório):
- Só **ler** credenciais de outras ferramentas. Nunca renovar, gravar ou mover
  tokens. Cada token vai apenas para a API do próprio provedor, por HTTPS.
- Nunca imprimir, logar ou incluir token/chave no documento de saída.
- Não rode um helper contra contas reais sem o usuário pedir; para testar o
  mapeamento use fixtures em `tests/cases.luau` com valores inventados.

Se o provedor for novo: registre o helper em `HELPERS` (e `SLOW_HELPERS` se o
endpoint for caro) em `host.luau`, a ordem/rótulo em `model.luau`, ícones
`icons/<id>-{dark,light}.svg` monocromáticos, e a linha da tabela no README.
Relate quais endpoints são não documentados e o que ficou sem teste real.
