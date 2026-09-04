# Claude Code's opencode sub-agents

[![skills.sh](https://skills.sh/b/toomingos/opencode-subagents)](https://skills.sh/toomingos/opencode-subagents)

Run [opencode](https://opencode.ai) agents as async sub-agents of Claude Code.

One shell call hands a task to an opencode agent and returns a single result envelope:
no streaming to babysit, no polling loop, no wrapper process to manage. In Claude Code,
dispatch it with `run_in_background: true` and you get a task notification when it exits,
which is the same shape as a native sub-agent: fire, keep working, read one result.

Works with opencode **v1** (`opencode`) and **v2** (`opencode2`). v2 is preferred when
installed: every run is a thin client of one shared background server instead of a full
runtime per agent, so ten parallel agents cost one server plus ten small clients. `run.sh`
starts that server detached before the first run (see [v2 background service](#v2-background-service)).

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
run.sh --peek list            # every run: state, minutes elapsed, run id, rate-limit wait
run.sh --peek <run-id|word>   # state, elapsed, session, rate-limit wait, last text of one run
run.sh --events <run-id|word> # its tool calls and text so far, one line each
run.sh --limits               # v2: every active session on the service, working or waiting on a rate limit
run.sh --interrupt <run-id|word|ses_…|limited|all>   # v2: stop a session on the service
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
| `--limits` | v2 only: active sessions on the service; for rate-limited ones the attempt and next-try time |
| `--interrupt <run\|word\|ses_…\|limited\|all>` | v2 only: interrupt one session, every rate-limited one, or every active one |

| Env var | Default | Meaning |
| --- | --- | --- |
| `OPENCODE_BIN` | `opencode2` if on PATH, else `opencode` | which binary to run |
| `OPENCODE_AGENT` | `build` | default agent |
| `OPENCODE_STALL` | `900` | kill after N seconds with no new output (v2: rate-limit waits do not count) |
| `OPENCODE_MAXRUN` | `2700` | kill after N seconds total, rate-limit waits included |
| `OPENCODE_RUNS` | `$TMPDIR/opencode-subagents-runs` | where raw streams are kept, 7-day retention |

## v2 background service

`opencode2 run` connects to one shared background server. If none is running, the first
client spawns `opencode2 serve --service` as its **own child**, and that client owns it:
stopping that client's process tree (Claude Code's task stop, `kill` of the process
group, closing the terminal) kills the server too, and every other agent on it dies with
`{"type":"error","error":{"message":"Transport"}}`. Their sessions survive on disk, but the
runs are gone.

`run.sh` avoids this by running `opencode2 service start` before the first run, which
detaches the server (parent pid 1) so no client owns it. Parallel launches serialise on a
lock so it starts once. Useful commands:

```bash
opencode2 service status     # URL of the running server, or "stopped"
opencode2 service restart    # after upgrading opencode2, or when a session is wedged
opencode2 api get /api/health
```

If you still see `lost the opencode2 background service mid-run` in a `task_error`, someone
stopped the service; resume the run with `--session <id>` once it is back.

The reverse also matters: a session keeps running on the service after its client is gone.
`run.sh` interrupts the session when its watchdog fires and when it receives `TERM`/`INT`
(Claude Code's task stop), so stopping a run stops the agent. A client killed with `KILL`
cannot do that; its session carries on with nobody listening, so after a hard stop run
`run.sh --limits` and `run.sh --interrupt <run|limited|all>` to clean up. On restart the
service resumes every session that was active, including those.

## Provider rate limits (v2)

An HTTP 429 from the model provider does not end the run. opencode2 keeps the session
alive and retries on a fixed schedule (15 minutes between attempts with the Console Go
models), and the json stream prints **nothing** while it waits. Only the session's
assistant message carries the state:

```bash
opencode2 api get /api/session/<id>/message | jq '[.data[] | select(.type=="assistant")] | first | .retry'
# {"attempt":2,"at":1788535101301,"error":{"type":"provider.rate-limit","status":429,...}}
```

`at` is the epoch-millisecond time of the next attempt. `run.sh` polls this every 30 s
while a run is quiet, so a run waiting on the provider is **not** killed as stalled; the
wait still counts towards `OPENCODE_MAXRUN`, and if that expires the `task_error` says it was
rate-limited and when the next attempt was due. `--peek` and `--peek list` show the same
wait, and `--limits` lists every active session on the service (`/api/session/active`) with
its wait, which is the quickest way to tell whether the limit has lifted before launching
a new batch: when nothing is waiting, launch; when sessions show a next-try time, wait for it.

`at` is a lower bound, not the provider's reset time. opencode reads the provider's
`retry-after` header but clamps the delay to 15 minutes, so a longer reset just means
another 429 and another 15 minute wait; it gives up after about five attempts. The header
values are not exposed anywhere a client can read them, and neither the local API nor the
Go gateway has a quota or usage endpoint (the Go plan limits are rolling windows with no
published reset time). So the only signals are a session's `retry` field disappearing (its
next attempt succeeded) or a fresh run producing `text`/`tool_use` events.

For a push signal instead of polling, subscribe to the server's event stream. Basic auth
with the password from `~/.local/state/opencode/service.json`, scoped to the project:

```bash
curl -sN -u "opencode:$PW" -H "x-opencode-directory: $PWD" "$URL/api/event"
# session.retry.scheduled     {sessionID, assistantMessageID, attempt, at, error}  -> wait began
# session.execution.succeeded | failed | interrupted                               -> retry cleared
```

Launching more agents into a limit only queues more 15 minute retries, and orphaned
sessions (clients killed outright, or a batch that was stopped) keep retrying in lock-step
and can hold the limit open on their own; `--interrupt limited` clears them. Note that
`/api/session/active` and `POST /api/session/<id>/wait` treat a session asleep in backoff as
running, so neither is a rate-limit indicator on its own.

## Agents and permissions

Headless opencode cannot answer a permission that resolves to "ask", so a task can stop
halfway with nothing to click. Fix it on the agent rather than by disabling permission
checks globally, and grant only what the tasks you delegate actually need. Then dispatch
with `--agent executor`.

### v2 (`opencode2`)

Agents live in `.opencode/agents/<name>.md` (project) or `~/.config/opencode/agents/`
(global). Permissions are an ordered rule list; the last matching rule wins, and anything
without a rule resolves to "ask". Actions are `shell`, `edit`, `read`, `glob`, `grep`,
`webfetch`, `websearch`, `subagent`, `skill`, `question`, `external_directory`.
An unknown `--agent` name is an error.

`external_directory` is the one that bites headless: any path outside the project (a
`cd ..`, a `cat ../../file`, an absolute path elsewhere) asks, and headless auto-rejects,
so the agent's shell command fails with no explanation in its final text. Deny it
explicitly and tell the agent to stay in the repository; allow only the directories you
mean it to touch (opencode's own tool-output directory is a common one).

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
  - action: external_directory
    resource: "*"
    effect: deny
  - action: external_directory
    resource: "~/.local/share/opencode/tool-output/*"
    effect: allow
---

You execute delegated tasks. Follow the prompt exactly and never expand scope.
Stay inside the repository: no `cd ..`, no `../` paths above the repo root, no absolute
paths outside it; access outside is denied headless.
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
  external_directory:
    "*": deny
    "~/.local/share/opencode/tool-output/*": allow
---

You execute delegated tasks. Follow the prompt exactly and never expand scope.
Stay inside the repository: no `cd ..`, no `../` paths above the repo root, no absolute
paths outside it; access outside is denied headless.
Final message: what changed, where, how verified, or what blocked you.
```

Keep both directories if you switch between versions; each reads only its own.

## License

MIT
