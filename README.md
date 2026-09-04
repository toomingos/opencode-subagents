# Claude Code's opencode sub-agents

[![skills.sh](https://skills.sh/b/toomingos/opencode-subagents)](https://skills.sh/toomingos/opencode-subagents)

Run [opencode](https://opencode.ai) agents as async sub-agents of Claude Code.

One shell call hands a task to an opencode agent and returns a single result envelope:
no streaming to babysit, no polling loop, no wrapper process to manage. In Claude Code,
dispatch it with `run_in_background: true` and you get a task notification when it exits,
which is the same shape as a native sub-agent: fire, keep working, read one result.

Works with opencode **v1** (`opencode`) and **v2** (`opencode2`). v2 is preferred when
installed: every run is a thin client of one shared background server instead of a full
runtime per agent, so ten parallel agents cost one server plus ten small clients.

## Install

```bash
npx skills add toomingos/opencode-subagents        # this project
npx skills add toomingos/opencode-subagents -g     # all projects
```

Requires `jq`, bash 3.2+ (stock macOS bash is fine), and one of:

- v2: `curl -fsSL https://opencode.ai/v2/install | bash` (installs `opencode2`; beta)
- v1: `curl -fsSL https://opencode.ai/install | bash` (installs `opencode`)

## Use

```bash
bash .claude/skills/opencode-subagents/run.sh --agent executor "refactor parser" <<'EOF'
Split src/parser.ts into tokenizer and parser modules. Keep the public API identical.
Final message: what changed, where, how verified, or what blocked you.
EOF
```

Output is one launch line on stderr, then only the envelope on stdout:

```
run.sh: run 20260904-123920-refactor-parser-13651 (opencode2, agent executor) stream …/20260904-123920-refactor-parser-13651.jsonl
<task id="ses_f96e8b2bcffehPxssFBu1zGY0U" state="completed">
<task_result>
Split parser.ts into tokenizer.ts and parser.ts; public API unchanged; `pnpm test` passes.
</task_result>
</task>
```

`state="error"` with `<task_error>` covers nonzero exits, error events, stalls, and timeouts.
Failures never come back silently.

### Several agents at once

One `run.sh` call per agent, each with `run_in_background: true`, all in the same Claude Code
message. Each is a separate background task with its own output file and its own completion
notification, so they finish independently and in any order. The parent decides how many to
launch; the script imposes no limit. Size the batch to the machine: every agent that runs
`tsc` or a type-aware linter adds a few hundred MB on top of the agent itself.

### Monitoring one agent

```bash
run.sh --peek list            # every run: state, minutes elapsed, run id
run.sh --peek <run-id|word>   # state, elapsed, session, last text of one run
run.sh --events <run-id|word> # its tool calls and text so far, one line each
```

`<word>` is any word from the title; the newest matching run wins. The raw JSON stream is
`$TMPDIR/opencode-subagents-runs/<run-id>.jsonl`; tail it (Claude Code's Monitor tool, or
`tail -f`) for live events.

| Flag | Meaning |
| --- | --- |
| `--agent <name>` | opencode agent to run the task (default `build`) |
| `--session <id>` | resume a previous run, id from the envelope |
| `--peek [id\|word\|list]` | state, elapsed, session and last text of a run |
| `--events [id\|word]` | condensed event log of a run |

| Env var | Default | Meaning |
| --- | --- | --- |
| `OPENCODE_BIN` | `opencode2` if on PATH, else `opencode` | which binary to run |
| `OPENCODE_AGENT` | `build` | default agent |
| `OPENCODE_STALL` | `900` | kill after N seconds with no new output |
| `OPENCODE_MAXRUN` | `2700` | kill after N seconds total |
| `OPENCODE_RUNS` | `$TMPDIR/opencode-subagents-runs` | where raw streams are kept, 7-day retention |

## Agents and permissions

Headless opencode cannot answer a permission that resolves to "ask", so a task can stop
halfway with nothing to click. Fix it on the agent rather than by disabling permission
checks globally, and grant only what the tasks you delegate actually need. Then dispatch
with `--agent executor`.

### v2 (`opencode2`)

Agents live in `.opencode/agents/<name>.md` (project) or `~/.config/opencode/agents/`
(global). Permissions are an ordered rule list; the last matching rule wins. Actions are
`shell`, `edit`, `read`, `glob`, `grep`, `webfetch`, `websearch`, `subagent`, `skill`.
An unknown `--agent` name is an error.

```markdown
---
description: Executes delegated tasks.
mode: all
permissions:
  - action: edit
    resource: "*"
    effect: allow
  - action: shell
    resource: "*"
    effect: allow
  - action: webfetch
    resource: "*"
    effect: deny
---

You execute delegated tasks. Follow the prompt exactly and never expand scope.
Final message: what changed, where, how verified, or what blocked you.
```

### v1 (`opencode`)

Agents live in `.opencode/agent/<name>.md` (singular) or `~/.config/opencode/agent/`.
An unknown `--agent` name silently falls back to `build`, so check spelling.

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

Keep both directories if you switch between versions; each reads only its own.

## License

MIT
