#!/usr/bin/env bash
# Dispatch a task to an opencode agent and print ONLY the final <task> envelope.
#
#   run.sh [--agent <name>] [--session <id>] "<title>" <<'EOF'   # task on stdin
#   ...task...
#   EOF
#   run.sh --peek [run-id]        # latest/one run: state, elapsed, session, last text
#   run.sh --peek list            # all runs
#
# Designed for Claude Code's Bash run_in_background: the launch returns at once,
# the completion notification carries the exit code, and the output file holds
# the envelope. Runs foreground everywhere else with the same output.
#
# Raw JSON stream: $RUNS/<run-id>.jsonl, stderr: <run-id>.err (7-day retention).
set -uo pipefail

RUNS="${OPENCODE_RUNS:-${TMPDIR:-/tmp}/opencode-subagents-runs}"
STALL="${OPENCODE_STALL:-900}"     # kill after N s without stream growth
MAXRUN="${OPENCODE_MAXRUN:-2700}"  # kill after N s total
AGENT="${OPENCODE_AGENT:-build}"   # opencode agent to run the task
mkdir -p "$RUNS"

session_of() { jq -R -r 'fromjson? | .sessionID // empty' "$1" 2>/dev/null | head -1; }
last_text()  { jq -R -c 'fromjson?' "$1" 2>/dev/null | jq -rs '[.[] | select(.type == "text")] | last | .part.text // empty'; }
mtime()      { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

# --- peek --------------------------------------------------------------------
if [ "${1:-}" = "--peek" ]; then
  if [ "${2:-}" = "list" ]; then
    for s in $(ls -t "$RUNS"/*.state 2>/dev/null); do
      read -r state start _ <"$s"; printf '%-10s %s\n' "$state" "$(basename "${s%.state}")"
    done; exit 0
  fi
  if [ -n "${2:-}" ]; then id="$2"; else id="$(ls -t "$RUNS"/*.state 2>/dev/null | head -1)"; id="$(basename "${id%.state}")"; fi
  [ -f "$RUNS/$id.state" ] || { echo "no run '$id' in $RUNS" >&2; exit 1; }
  read -r state start code sid agent <"$RUNS/$id.state"
  now=$(date +%s)
  printf 'run:      %s\nstate:    %s%s\nagent:    %s\nelapsed:  %dm%02ds\nsession:  %s\nlast write: %ss ago\nlast text:\n%s\n' \
    "$id" "$state" "${code:+ (exit $code)}" "${agent:-?}" $(((now - start) / 60)) $(((now - start) % 60)) \
    "${sid:-$(session_of "$RUNS/$id.jsonl")}" "$((now - $(mtime "$RUNS/$id.jsonl")))" \
    "$(last_text "$RUNS/$id.jsonl" | tail -c 2000)"
  exit 0
fi

# --- dispatch ----------------------------------------------------------------
command -v opencode >/dev/null || { echo "run.sh: 'opencode' not on PATH (https://opencode.ai)" >&2; exit 2; }
command -v jq       >/dev/null || { echo "run.sh: 'jq' not on PATH" >&2; exit 2; }

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

find "$RUNS" -type f -mtime +7 -delete 2>/dev/null
slug="$(printf '%s' "$title" | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
id="$(date +%Y%m%d-%H%M%S)-${slug:-run}-$$"
out="$RUNS/$id.jsonl" err="$RUNS/$id.err" state="$RUNS/$id.state"
start=$(date +%s)
: >"$out"; echo "running $start" >"$state"

opencode run --agent "$AGENT" ${sess[@]+"${sess[@]}"} --title "$title" --format json "$task" >"$out" 2>"$err" &
pid=$!
reason=""
while kill -0 "$pid" 2>/dev/null; do
  sleep 5
  now=$(date +%s)
  if [ $((now - $(mtime "$out"))) -gt "$STALL" ]; then reason="stalled: no output for ${STALL}s"
  elif [ $((now - start)) -gt "$MAXRUN" ]; then reason="timeout: exceeded ${MAXRUN}s"; fi
  if [ -n "$reason" ]; then kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null; break; fi
done
wait "$pid"; code=$?

sid="$(session_of "$out")"; sid="${sid:-unknown}"
text="$(last_text "$out")"
rejected="$(grep -c 'auto-rejecting' "$err" 2>/dev/null || true)"

if [ -n "$reason" ]; then
  result=error; code=1; text="[$reason] resume with --session $sid"$'\n'"$text"
elif [ "$code" -eq 0 ]; then
  result=completed
else
  result=error; [ -z "$text" ] && text="$(cat "$out" "$err")"; text="[exit $code] $text"
fi
[ "${rejected:-0}" -gt 0 ] && text="$text"$'\n'"[note: $rejected permission request(s) auto-rejected in headless mode; see $err]"

echo "$result $start $code $sid $AGENT" >"$state"
tag=task_result; [ "$result" = error ] && tag=task_error
printf '<task id="%s" state="%s">\n<%s>\n%s\n</%s>\n</task>\n' "$sid" "$result" "$tag" "$text" "$tag"
exit "$code"
