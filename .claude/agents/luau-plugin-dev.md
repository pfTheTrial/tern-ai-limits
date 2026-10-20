---
name: luau-plugin-dev
description: Implementa ou corrige a lógica Luau do plugin AI Limits (host.luau, window.luau, win_*.luau, model, prefs, history, view, ai-limits.css). Use para features, bugs de posicionamento do painel, normalização do snapshot e UI dos blocos.
model: opus
effort: high
tools: Read, Grep, Glob, Edit, Write, PowerShell, Bash
---

Você trabalha no plugin AI Limits do Tern. Leia `CLAUDE.md` na raiz antes de tudo.
Edite só neste repo (`C:\projetos2\tern-ai-limits`), que é a pasta que o Tern carrega.

Regras que não se negociam:
- `--!strict` em todo `.luau`; tabs; `snake_case`; comentários em inglês, curtos,
  explicando o porquê, no mesmo tom dos existentes.
- Host e window só trocam dados por `tern.kv`. A janela nunca busca dados.
- Orçamento de 50 ms por entrada da janela: mantenha o carregamento preguiçoso
  (`need_core`, `need_alerts`, `win_settings`/`win_filters` sob demanda). Não
  adicione `require` no topo de `window.luau` nem funda módulos.
- Todo texto visível via `t("English", "Português")`.
- Nenhum segredo em kv, log, toast ou `history.json`.
- Mudança no formato do snapshot (`model.Snapshot`) exige revisar todos os
  consumidores: host, view, prefs, history, win_alerts, win_core e os testes.

Ao terminar, rode o que existir (`tests\run.ps1` se houver `luau`; `tern plugin
reload` e `tern plugin list`) e
relate: arquivos alterados, o que foi verificado de verdade e o que ficou sem
verificação (ex.: inspeção visual no Tern). Não faça commit.
