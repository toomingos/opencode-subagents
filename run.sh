#!/usr/bin/env bash
# Dispatch a task to an opencode agent and print ONLY the final <task> envelope.
#
#   run.sh [--agent <name>] [--session <id>] "<title>" <<'EOF'   # task on stdin
#   ...task...
#   EOF
#   run.sh --peek [run-id|title]      # one run: state, elapsed, session, last text
#   run.sh --peek list                # all runs
#   run.sh --events [run-id|title]    # one run: condensed event log (tools, text, errors)
#
# Designed for Claude Code's Bash run_in_background: the launch returns at once,
# the completion notification carries the exit code, and the output file holds
# the envelope. Runs foreground everywhere else with the same output.
#
# Works with opencode v1 (`opencode`) and v2 (`opencode2`, shared background
# server). Picks opencode2 when on PATH; override with OPENCODE_BIN.
#
# Raw JSON stream: $RUNS/<run-id>.jsonl, stderr: <run-id>.err (7-day retention).
set -uo pipefail

RUNS="${OPENCODE_RUNS:-${TMPDIR:-/tmp}/opencode-subagents-runs}"
STALL="${OPENCODE_STALL:-900}"     # kill after N s without stream growth
MAXRUN="${OPENCODE_MAXRUN:-2700}"  # kill after N s total
AGENT="${OPENCODE_AGENT:-build}"   # opencode agent to run the task
BIN="${OPENCODE_BIN:-}"            # opencode binary; default: opencode2, else opencode
mkdir -p "$RUNS"

session_of() { jq -R -r 'fromjson? | .sessionID // empty' "$1" 2>/dev/null | head -1; }
last_text()  { jq -R -c 'fromjson?' "$1" 2>/dev/null | jq -rs '[.[] | select(.type == "text")] | last | .part.text // empty'; }
last_error() { jq -R -c 'fromjson?' "$1" 2>/dev/null | jq -rs '[.[] | select(.type == "error")] | last | .error.message // empty'; }
mtime()      { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
# resolve "<run-id>" or "<title substring>" (newest match) or "" (newest run)
resolve()    { local q="${1:-}" f
  if [ -z "$q" ]; then f="$(ls -t "$RUNS"/*.state 2>/dev/null | head -1)"
  elif [ -f "$RUNS/$q.state" ]; then f="$RUNS/$q.state"
  else f="$(ls -t "$RUNS"/*"$(printf '%s' "$q" | tr -cs '[:alnum:]' '-')"*.state 2>/dev/null | head -1)"; fi
  [ -n "$f" ] && basename "${f%.state}"; }

# --- peek / events ------------------------------------------------------------
if [ "${1:-}" = "--peek" ] || [ "${1:-}" = "--events" ]; then
  if [ "${2:-}" = "list" ]; then
    now=$(date +%s)
    for s in $(ls -t "$RUNS"/*.state 2>/dev/null); do
      read -r state start _ <"$s"; printf '%-10s %4dm  %s\n' "$state" $(((now - start) / 60)) "$(basename "${s%.state}")"
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
  read -r state start code sid agent <"$RUNS/$id.state"
  [ "$code" = "-" ] && code=""; [ "$sid" = "-" ] && sid=""
  now=$(date +%s)
  printf 'run:      %s\nstate:    %s%s\nagent:    %s\nelapsed:  %dm%02ds\nsession:  %s\nlast write: %ss ago\nlast text:\n%s\n' \
    "$id" "$state" "${code:+ (exit $code)}" "${agent:-?}" $(((now - start) / 60)) $(((now - start) % 60)) \
    "${sid:-$(session_of "$RUNS/$id.jsonl")}" "$((now - $(mtime "$RUNS/$id.jsonl")))" \
    "$(last_text "$RUNS/$id.jsonl" | tail -c 2000)"
  exit 0
fi

# --- dispatch ----------------------------------------------------------------
if [ -z "$BIN" ]; then
  if command -v opencode2 >/dev/null; then BIN=opencode2; else BIN=opencode; fi
fi
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

find "$RUNS" -type f -mtime +7 -delete 2>/dev/null
slug="$(printf '%s' "$title" | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
id="$(date +%Y%m%d-%H%M%S)-${slug:-run}-$$"
out="$RUNS/$id.jsonl" err="$RUNS/$id.err" state="$RUNS/$id.state"
start=$(date +%s)
: >"$out"; echo "running $start - - $AGENT" >"$state"
echo "run.sh: run $id ($BIN, agent $AGENT) stream $out" >&2

"$BIN" run --agent "$AGENT" ${sess[@]+"${sess[@]}"} --title "$title" --format json "$task" >"$out" 2>"$err" &
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
errmsg="$(last_error "$out")"
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

echo "$result $start $code $sid $AGENT" >"$state"
tag=task_result; [ "$result" = error ] && tag=task_error
printf '<task id="%s" state="%s">\n<%s>\n%s\n</%s>\n</task>\n' "$sid" "$result" "$tag" "$text" "$tag"
exit "$code"
