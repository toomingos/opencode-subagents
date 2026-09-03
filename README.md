# Claude Code's opencode sub-agents

[![skills.sh](https://skills.sh/b/toomingos/opencode-subagents)](https://skills.sh/toomingos/opencode-subagents)

Run [opencode](https://opencode.ai) agents as async sub-agents of Claude Code.

One shell call hands a task to an opencode agent and returns a single result envelope:
no streaming to babysit, no polling loop, no wrapper process to manage. In Claude Code,
dispatch it with `run_in_background: true` and you get a task notification when it exits,
which is the same shape as a native sub-agent: fire, keep working, read one result.

## Install

```bash
npx skills add toomingos/opencode-subagents        # this project
npx skills add toomingos/opencode-subagents -g     # all projects
```

Requires the `opencode` CLI, `jq`, and bash 3.2+ (stock macOS bash is fine).

## Use

```bash
bash .claude/skills/opencode-subagents/run.sh "refactor parser" <<'EOF'
Split src/parser.ts into tokenizer and parser modules. Keep the public API identical.
Final message: what changed, where, how verified, or what blocked you.
EOF
```

Output is only the envelope:

```
<task id="ses_f96e8b2bcffehPxssFBu1zGY0U" state="completed">
<task_result>
Split parser.ts into tokenizer.ts and parser.ts; public API unchanged; `pnpm test` passes.
</task_result>
</task>
```

`state="error"` with `<task_error>` covers nonzero exits, stalls, and timeouts. Failures
never come back silently.

| Flag | Meaning |
| --- | --- |
| `--agent <name>` | opencode agent to run the task (default `build`) |
| | opencode falls back to its default agent when the name is unknown, silently, so check your spelling against `.opencode/agent/` |
| `--session <id>` | resume a previous run, id from the envelope |
| `--peek [id\|list]` | state, elapsed, session and last text of a run in flight |

| Env var | Default | Meaning |
| --- | --- | --- |
| `OPENCODE_AGENT` | `build` | default agent |
| `OPENCODE_STALL` | `900` | kill after N seconds with no new output |
| `OPENCODE_MAXRUN` | `2700` | kill after N seconds total |
| `OPENCODE_RUNS` | `$TMPDIR/opencode-subagents-runs` | where raw streams are kept, 7-day retention |

## Permissions

Headless opencode auto-rejects any permission that resolves to "ask", so a task can stop
halfway with nothing to click. The envelope tells you when that happened. Fix it on the
agent rather than by disabling permission checks globally. Create `.opencode/agent/executor.md`:

```markdown
---
description: Executes delegated tasks.
mode: all
permission:
  edit: allow
  bash: allow
  webfetch: deny
---

You execute delegated tasks. Follow the prompt exactly and never expand scope.
Final message: what changed, where, how verified, or what blocked you.
```

Then dispatch with `--agent executor`. Grant only what the tasks you delegate actually need.

## License

MIT
