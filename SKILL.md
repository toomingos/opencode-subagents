---
name: opencode-subagents
description: Dispatch a task to an opencode agent as an async background subagent, and get back a single result envelope. Use when the user says to delegate, send, offload, or run a task on opencode, or invokes /opencode-subagents with a task.
---

`run.sh` lives next to this file: `.claude/skills/opencode-subagents/run.sh` for a project
install, `~/.claude/skills/opencode-subagents/run.sh` for a global one. Use that path below.

One Bash call, task on stdin. In Claude Code set `run_in_background: true`:

```bash
bash <skill-dir>/run.sh "<short title>" <<'EOF'
<full task prompt. End with: "Final message: what changed, where, how verified, or what blocked you.">
EOF
```

Launch returns a task id and output file at once; keep working. On exit you get a
`<task-notification>` with the exit code. Then read the output file: it holds only
`<task id="ses_…" state="completed|error">` with `<task_result>` or `<task_error>` (the
agent's final text). Relay it faithfully, session id included. Never do the task yourself instead.

- Agent: `--agent <name>` picks the opencode agent (default `build`, or env `OPENCODE_AGENT`). Pass a project agent from `.opencode/agent/` when one exists.
- Resume: `run.sh --session <id> "<title>" <<'EOF' … EOF` (id from the envelope).
- Peek mid-run: `run.sh --peek` (latest), `--peek <run-id>`, `--peek list`. Foreground call.
- Watchdog: `state="error"` with `stalled` after 15 min without output or `timeout` after 45 min (env `OPENCODE_STALL`, `OPENCODE_MAXRUN`, seconds). Nonzero exits and unparseable streams also come back as `task_error`, never silently.
- Headless opencode auto-rejects any permission that resolves to "ask"; the envelope appends a note when that happened. Fix it with a `permission` block on the agent, not by passing `--auto`.
- Parallel work: several run.sh calls in one message, each its own background task.
- Outside Claude Code the call is just foreground and prints the same envelope.
