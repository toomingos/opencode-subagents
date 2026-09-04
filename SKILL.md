---
name: opencode-subagents
description: Dispatch a task to an opencode agent as an async background subagent, and get back a single result envelope. Use when the user says to delegate, send, offload, or run a task on opencode, or invokes /opencode-subagents with a task.
---

`run.sh` lives next to this file: `.claude/skills/opencode-subagents/run.sh` for a project
install, `~/.claude/skills/opencode-subagents/run.sh` for a global one. Use that path below.

One Bash call per agent, task on stdin. In Claude Code set `run_in_background: true`:

```bash
bash <skill-dir>/run.sh --agent <name> "<short title>" <<'EOF'
<full task prompt. End with: "Final message: what changed, where, how verified, or what blocked you.">
EOF
```

Launch returns a Claude Code task id and output file at once; keep working. On exit you get a
`<task-notification>` with the exit code. Then read the output file: it holds one `run.sh: run <run-id> …`
line and the envelope `<task id="ses_…" state="completed|error">` with `<task_result>` or
`<task_error>` (the agent's final text). Relay it faithfully, session id included. Never do the task
yourself instead.

- Many agents: one `run.sh` call per agent, all in the same message, each with `run_in_background: true`.
  Each is its own Claude Code task with its own output file and its own notification; they finish
  independently and in any order. You choose how many to launch; there is no built-in cap.
- Monitor one agent mid-run (foreground calls; `<run-id>` or a word from its title):
  `run.sh --peek <run-id>` (state, elapsed, session, last text), `run.sh --events <run-id>` (every tool
  call and text so far), `run.sh --peek list` (all runs). The raw stream is
  `$TMPDIR/opencode-subagents-runs/<run-id>.jsonl`; Claude Code's Monitor tool can tail it for live events.
- Agent: `--agent <name>` picks the opencode agent (default `build`, or env `OPENCODE_AGENT`). Pass a project
  agent when one exists: v2 reads `.opencode/agents/`, v1 reads `.opencode/agent/`. v2 errors on an unknown
  name; v1 silently falls back to `build`.
- Version: uses `opencode2` (v2, shared background server, much lighter per agent) when on PATH, else
  `opencode` (v1). Force one with env `OPENCODE_BIN=opencode` or `OPENCODE_BIN=opencode2`.
- Resume: `run.sh --session <id> "<title>" <<'EOF' … EOF` (id from the envelope).
- Watchdog: `state="error"` with `stalled` after 15 min without output or `timeout` after 45 min (env
  `OPENCODE_STALL`, `OPENCODE_MAXRUN`, seconds). Nonzero exits, error events and unparseable streams also
  come back as `task_error`, never silently.
- Permissions that resolve to "ask" cannot be answered headless; fix them with a permission block on the
  agent (see README for the v1 and v2 syntax), not by passing `--auto`.
- Outside Claude Code the call is just foreground and prints the same envelope.
