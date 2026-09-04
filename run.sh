#!/usr/bin/env bash
# Dispatch a task to an opencode agent and print ONLY the final <task> envelope.
#
#   run.sh [--agent <name>] [--session <id>] "<title>" <<'EOF'   # task on stdin
#   ...task...
#   EOF
#   run.sh --peek [run-id|title]      # one run: state, elapsed, session, rate limit, last text
#   run.sh --peek list                # all runs
#   run.sh --events [run-id|title]    # one run: condensed event log (tools, text, errors)
#   run.sh --limits                   # v2: active sessions on the service and their rate-limit waits
#   run.sh --interrupt <run|ses_…|limited|all>   # v2: stop a session on the service
#
# Designed for Claude Code's Bash run_in_background: the launch returns at once,
# the completion notification carries the exit code, and the output file holds
# the envelope. Runs foreground everywhere else with the same output.
#
# Works with opencode v1 (`opencode`) and v2 (`opencode2`, shared background
# server). Picks opencode2 when on PATH; override with OPENCODE_BIN.
#
# v2 notes:
# - The background service is started detached (`opencode2 service start`) before
#   the first run. A `run` client that has to spawn the service itself keeps it as a
#   child process, and Claude Code's task stop kills the whole tree, taking the
#   service and every other agent down with it ("Transport" errors).
# - Provider rate limits (HTTP 429) put a session into a silent retry with a fixed
#   15 min backoff and no stream output. The watchdog reads the retry state from
#   the service API and does not count that wait as a stall.
# - A session keeps running (and retrying) on the service after its client dies, so
#   run.sh interrupts the session when it kills or is told to stop, and --interrupt
#   cleans up after a client that was killed outright.
#
# Raw JSON stream: $RUNS/<run-id>.jsonl, stderr: <run-id>.err (7-day retention).
set -uo pipefail

RUNS="${OPENCODE_RUNS:-${TMPDIR:-/tmp}/opencode-subagents-runs}"
STALL="${OPENCODE_STALL:-900}"     # kill after N s without stream growth (rate-limit waits excluded)
MAXRUN="${OPENCODE_MAXRUN:-2700}"  # kill after N s total
AGENT="${OPENCODE_AGENT:-build}"   # opencode agent to run the task
BIN="${OPENCODE_BIN:-}"            # opencode binary; default: opencode2, else opencode
mkdir -p "$RUNS"

session_of() { jq -R -r 'fromjson? | .sessionID // empty' "$1" 2>/dev/null | head -1; }
last_text()  { jq -R -c 'fromjson?' "$1" 2>/dev/null | jq -rs '[.[] | select(.type == "text")] | last | .part.text // empty'; }
last_error() { jq -R -c 'fromjson?' "$1" 2>/dev/null | jq -rs '[.[] | select(.type == "error")] | last | .error.message // empty'; }
mtime()      { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
hms()        { date -r "$1" '+%H:%M:%S' 2>/dev/null || date -d "@$1" '+%H:%M:%S'; }
# resolve "<run-id>" or "<title substring>" (newest match) or "" (newest run)
resolve()    { local q="${1:-}" f
  if [ -z "$q" ]; then f="$(ls -t "$RUNS"/*.state 2>/dev/null | head -1)"
  elif [ -f "$RUNS/$q.state" ]; then f="$RUNS/$q.state"
  else f="$(ls -t "$RUNS"/*"$(printf '%s' "$q" | tr -cs '[:alnum:]' '-')"*.state 2>/dev/null | head -1)"; fi
  [ -n "$f" ] && basename "${f%.state}"; }

# v2 service HTTP access. curl against the service registration when available (the
# `opencode2 api` client caps output at 256 KB, which breaks on long sessions), else the CLI.
SVC="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"
api() { local url pw
  if [ -f "$SVC" ] && command -v curl >/dev/null; then
    url="$(jq -r '.url // empty' "$SVC")"; pw="$(jq -r '.password // empty' "$SVC")"
    [ -n "$url" ] && { printf 'user = "opencode:%s"\n' "$pw" | curl -s -f -m 20 -K - -X "$1" "$url$2" 2>/dev/null; return; }
  fi
  "$BIN" api "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$2" 2>/dev/null; }
# v2 only. Prints "<epoch-s> <attempt> <message>" when the session's latest assistant
# message is waiting on a provider retry (rate limit), nothing otherwise.
retry_of()   { is_v2 && [ -n "${1:-}" ] || return 0
  api GET "/api/session/$1/message?limit=2&order=desc" | jq -r '
    [.data[]? | select(.type == "assistant")] | first | .retry // empty
    | "\(.at / 1000 | floor) \(.attempt) \(.error.message // .error.type // "retry")"' 2>/dev/null; }
active_sessions() { api GET /api/session/active | jq -r '.data | keys[]' 2>/dev/null; }
title_of()   { api GET "/api/session/$1" | jq -r '.data.title // empty' 2>/dev/null; }
interrupt()  { api POST "/api/session/$1/interrupt" >/dev/null 2>&1; }

is_v2() { case "$BIN" in *opencode2*) return 0 ;; *) return 1 ;; esac; }
if [ -z "$BIN" ]; then
  if command -v opencode2 >/dev/null; then BIN=opencode2; else BIN=opencode; fi
fi

# --- limits / interrupt -------------------------------------------------------
# Asks the shared service, not the local state files, so it also covers sessions
# started elsewhere (TUI, desktop app, another run.sh) and ignores stale runs.
if [ "${1:-}" = "--limits" ]; then
  is_v2 || { echo "--limits needs opencode2 (v1 runs a private server per agent)" >&2; exit 2; }
  now=$(date +%s); n=0; w=0
  for sid in $(active_sessions); do
    n=$((n + 1)); r="$(retry_of "$sid")"
    if [ -n "$r" ]; then read -r rat ratt rmsg <<<"$r"; w=$((w + 1))
      printf '%-28s %-24s rate-limited: attempt %s, next try %s (%dm%02ds)  %s\n' "$sid" "$(title_of "$sid" | cut -c1-24)" "$ratt" "$(hms "$rat")" $(((rat - now) / 60)) $(((rat - now) % 60)) "$rmsg"
    else printf '%-28s %-24s working\n' "$sid" "$(title_of "$sid" | cut -c1-24)"; fi
  done
  echo "$n active session(s) on the service, $w waiting on a provider rate limit"
  exit 0
fi
if [ "${1:-}" = "--interrupt" ]; then
  is_v2 || { echo "--interrupt needs opencode2" >&2; exit 2; }
  q="${2:?--interrupt needs <run-id|title word|ses_…|limited|all>}"; n=0
  case "$q" in
    all)     for sid in $(active_sessions); do interrupt "$sid" && n=$((n + 1)); done ;;
    limited) for sid in $(active_sessions); do [ -n "$(retry_of "$sid")" ] && interrupt "$sid" && n=$((n + 1)); done ;;
    ses_*)   interrupt "$q" && n=1 ;;
    *) id="$(resolve "$q")"; [ -n "$id" ] || { echo "no run matching '$q'" >&2; exit 1; }
       read -r _ _ _ sid _ <"$RUNS/$id.state"; [ "$sid" = "-" ] && sid="$(session_of "$RUNS/$id.jsonl")"
       [ -n "$sid" ] || { echo "run $id has no session yet" >&2; exit 1; }; interrupt "$sid" && n=1 ;;
  esac
  echo "interrupted $n session(s)"; exit 0
fi

# --- peek / events ------------------------------------------------------------
if [ "${1:-}" = "--peek" ] || [ "${1:-}" = "--events" ]; then
  if [ "${2:-}" = "list" ]; then
    now=$(date +%s)
    for s in $(ls -t "$RUNS"/*.state 2>/dev/null); do
      read -r state start _ _ _ rl <"$s"; printf '%-10s %4dm  %s%s\n' "$state" $(((now - start) / 60)) "$(basename "${s%.state}")" "${rl:+  [rate-limited until $(hms "${rl#rl:}")]}"
    done; exit 0
  fi
  id="$(resolve "${2:-}")"
  [ -n "$id" ] && [ -f "$RUNS/$id.state" ] || { echo "no run matching '${2:-}' in $RUNS" >&2; exit 1; }
  if [ "$1" = "--events" ]; then
    jq -R -r 'fromjson? | select(.type != "step_start" and .type != "step_finish")
      | (.timestamp / 1000 | strftime("%H:%M:%S")) + "  " + .type
        + (if .type == "tool_use" then "  " + .part.tool + " " + (.part.state.status // "") + "  " + ((.part.state.input // {}) | tostring | .[0:160])
           elif .type == "text" then "  " + (.part.text | gsub("\n"; " ") | .[0:200])
           elif .type == "error" then "  " + (.error.message // "")
           else "" end)' "$RUNS/$id.jsonl"
    exit 0
  fi
  read -r state start code sid agent rl <"$RUNS/$id.state"
  [ "$code" = "-" ] && code=""; [ "$sid" = "-" ] && sid=""
  now=$(date +%s)
  sid="${sid:-$(session_of "$RUNS/$id.jsonl")}"
  rlline=""
  if [ "$state" = running ]; then r="$(retry_of "$sid")"; [ -n "$r" ] && { read -r rat ratt rmsg <<<"$r"; rlline="rate limit: waiting, attempt $ratt, next try $(hms "$rat") ($(((rat - now) / 60))m$(((rat - now) % 60))s): $rmsg"$'\n'; }
  elif [ -n "${rl:-}" ]; then rlline="rate limit: was waiting until $(hms "${rl#rl:}") when the run ended"$'\n'; fi
  printf 'run:      %s\nstate:    %s%s\nagent:    %s\nelapsed:  %dm%02ds\nsession:  %s\nlast write: %ss ago\n%slast text:\n%s\n' \
    "$id" "$state" "${code:+ (exit $code)}" "${agent:-?}" $(((now - start) / 60)) $(((now - start) % 60)) \
    "$sid" "$((now - $(mtime "$RUNS/$id.jsonl")))" "$rlline" \
    "$(last_text "$RUNS/$id.jsonl" | tail -c 2000)"
  exit 0
fi

# --- dispatch ----------------------------------------------------------------
command -v "$BIN" >/dev/null || { echo "run.sh: '$BIN' not on PATH (https://opencode.ai)" >&2; exit 2; }
command -v jq     >/dev/null || { echo "run.sh: 'jq' not on PATH" >&2; exit 2; }

sess=()
while :; do
  case "${1:-}" in
    --agent)   AGENT="${2:?--agent needs a name}"; shift 2 ;;
    --session) sess=(--session "${2:?--session needs an id}"); shift 2 ;;
    *) break ;;
  esac
done
title="${1:?usage: run.sh [--agent <name>] [--session <id>] \"<title>\" <<'EOF' ...task... EOF}"
task="$(cat)"
[ -n "$task" ] || { echo "run.sh: empty task on stdin" >&2; exit 2; }

# v2: make sure the shared service is up and detached (ppid 1) before the run client
# connects, so no client ever owns it. Serialised so parallel launches start it once.
if is_v2; then
  lock="$RUNS/.service.lock"; i=0
  until mkdir "$lock" 2>/dev/null; do i=$((i + 1)); [ "$i" -gt 60 ] && { rm -rf "$lock"; break; }; sleep 0.5; done
  if ! api GET /api/health | grep -q '"healthy":true'; then
    "$BIN" service start >/dev/null 2>&1
  fi
  rmdir "$lock" 2>/dev/null
fi

find "$RUNS" -type f -mtime +7 -delete 2>/dev/null
slug="$(printf '%s' "$title" | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
id="$(date +%Y%m%d-%H%M%S)-${slug:-run}-$$"
out="$RUNS/$id.jsonl" err="$RUNS/$id.err" state="$RUNS/$id.state"
start=$(date +%s)
: >"$out"; echo "running $start - - $AGENT" >"$state"
echo "run.sh: run $id ($BIN, agent $AGENT) stream $out" >&2

"$BIN" run --agent "$AGENT" ${sess[@]+"${sess[@]}"} --title "$title" --format json "$task" >"$out" 2>"$err" &
pid=$!
reason="" sid="" rl="" rlmsg="" lastcheck=0 progress=$start
# Stopped from outside (Claude Code task stop sends TERM): stop the session on the
# service too, or it keeps working and retrying with nobody listening.
stopped() { kill "$pid" 2>/dev/null; [ -n "$sid" ] || sid="$(session_of "$out")"
  is_v2 && [ -n "$sid" ] && interrupt "$sid"
  echo "killed $start 143 ${sid:-unknown} $AGENT${rl:+ $rl}" >"$state"; exit 143; }
trap stopped TERM INT HUP
while kill -0 "$pid" 2>/dev/null; do
  sleep 5
  now=$(date +%s)
  m=$(mtime "$out"); [ "$m" -gt "$progress" ] && progress=$m
  # v2: a session waiting on a provider retry makes no stream progress; poll the
  # service every 30 s and treat that wait as progress, not as a stall.
  if is_v2 && [ $((now - lastcheck)) -ge 30 ]; then
    lastcheck=$now; [ -n "$sid" ] || sid="$(session_of "$out")"
    r="$(retry_of "$sid")"
    if [ -n "$r" ]; then
      read -r rat ratt rmsg <<<"$r"; rl="rl:$rat"; rlmsg="rate limited by provider (attempt $ratt, next try $(hms "$rat")): $rmsg"
      progress=$now; echo "running $start - ${sid:--} $AGENT $rl" >"$state"
    elif [ -n "$rl" ]; then
      rl=""; rlmsg=""; echo "running $start - ${sid:--} $AGENT" >"$state"
    fi
  fi
  if [ $((now - progress)) -gt "$STALL" ]; then reason="stalled: no output for ${STALL}s"
  elif [ $((now - start)) -gt "$MAXRUN" ]; then reason="timeout: exceeded ${MAXRUN}s${rl:+ while $rlmsg}"; fi
  if [ -n "$reason" ]; then
    [ -n "$sid" ] || sid="$(session_of "$out")"; is_v2 && [ -n "$sid" ] && interrupt "$sid"
    kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null; break
  fi
done
trap - TERM INT HUP
wait "$pid"; code=$?

sid="${sid:-$(session_of "$out")}"; sid="${sid:-unknown}"
text="$(last_text "$out")"
errmsg="$(last_error "$out")"
case "$errmsg" in Transport|*"Transport"*) errmsg="lost the opencode2 background service mid-run (it was stopped or killed; check 'opencode2 service status')" ;; esac
rejected="$(grep -c 'auto-rejecting' "$err" 2>/dev/null || true)"

if [ -n "$reason" ]; then
  result=error; code=1; text="[$reason] resume with --session $sid"$'\n'"$text"
elif [ "$code" -eq 0 ] && [ -z "$errmsg" ]; then
  result=completed
else
  result=error; [ "$code" -eq 0 ] && code=1
  [ -n "$errmsg" ] && text="$errmsg"$'\n'"$text"
  [ -z "$text" ] && text="$(cat "$out" "$err")"; text="[exit $code] $text"
fi
[ "${rejected:-0}" -gt 0 ] && text="$text"$'\n'"[note: $rejected permission request(s) auto-rejected in headless mode; see $err]"

echo "$result $start $code $sid $AGENT${rl:+ $rl}" >"$state"
tag=task_result; [ "$result" = error ] && tag=task_error
printf '<task id="%s" state="%s">\n<%s>\n%s\n</%s>\n</task>\n' "$sid" "$result" "$tag" "$text" "$tag"
exit "$code"
