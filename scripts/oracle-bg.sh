#!/usr/bin/env bash
# oracle-bg.sh — zero-focus background Oracle (GPT-5.x Pro) via the browser engine.
#
# Why this exists: `@steipete/oracle --engine browser` defaults to launching a
# VISIBLE Chrome that takes focus, and its in-app cookie copy can fail to pick up
# the real ChatGPT session (the "Unable to locate the ChatGPT model selector
# button" error is usually an AUTH failure in disguise). This script instead:
#   1. finds the Chrome profile actually signed into ChatGPT,
#   2. launches a DEDICATED Chrome in the background via `open -g` (never
#      activates, never touches the user's main Chrome — separate profile),
#   3. seeds that profile with ONLY the ChatGPT/OpenAI cookies (WAL-safe
#      sqlite .backup),
#   4. attaches oracle via --remote-chrome (oracle launches nothing => no flash),
#   5. cleans up the dedicated Chrome + seeded cookies on exit.
#
# Usage:
#   oracle-bg.sh <prompt-file> [slug] [-- extra oracle args...]
# Env overrides: ORACLE_BG_PORT (9222), ORACLE_BG_MODEL ("Pro"),
#   ORACLE_BG_PROFILE ($TMPDIR/oracle-bg-chrome), ORACLE_CHATGPT_URL,
#   ORACLE_BG_PKG (default @steipete/oracle@0.17.1 — exact pin, see below).
#
# Model default "Pro" (verified 2026-07): the ChatGPT picker is two-axis —
# a model-family submenu times an effort tier (Instant / Medium / High /
# Extra High / Pro). "Pro" selects the Pro effort tier on the account's
# current family. Do NOT pass a combined family+Pro label: oracle <=0.16.1
# hard-rejects it.
#
# Picker regression + auto-fallback (verified 2026-08-10): ChatGPT moved the
# effort tiers into an "Advanced" submenu that oracle <=0.17.1 cannot descend
# ("Unable to find model option matching 'Pro'"), and 0.17.0's composer send
# is broken ("Prompt did not appear in conversation"). 0.17.1 sends fine, so
# this script pins it, tries Pro first, and on the picker error retries once
# with --browser-model-strategy current (the profile's active model),
# disclosing loudly that the answer is NOT guaranteed Pro-tier. Pro-tier
# restoration paths: an oracle release that handles the Advanced submenu, or
# the user setting their ChatGPT current model to Pro once in their real
# browser (then `current` IS Pro).
set -uo pipefail
umask 077  # seeded cookies + answer files must never be world-readable

PROMPT_FILE="${1:?usage: oracle-bg.sh <prompt-file> [slug] [-- extra args]}"; shift
# Default slug is 3 words: oracle 0.16.x rejects slugs under 3 hyphen-words.
SLUG="oracle-background-consult"
if [ $# -gt 0 ] && [ "$1" != "--" ]; then SLUG="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
EXTRA=("$@")

[ -r "$PROMPT_FILE" ] || { echo "oracle-bg: cannot read prompt file: $PROMPT_FILE" >&2; exit 2; }
printf '%s' "$SLUG" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+){2,4}$' \
  || { echo "oracle-bg: slug must be 3-5 hyphen-separated lowercase words (got: $SLUG)" >&2; exit 2; }

for bin in sqlite3 node npx curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "oracle-bg: missing required binary: $bin" >&2; exit 5; }
done
node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null \
  || { echo "oracle-bg: node >= 22 required (the salvage scraper needs the global WebSocket)" >&2; exit 5; }

# Per-RUN unique port + profile by default (fix 2026-08-10). A shared default
# profile is a foreground hazard, not just a collision hazard: launching while
# another Chrome holds the same profile's singleton lock makes the new process
# FORWARD its open request to the existing instance, which RAISES a window —
# `open -g` only backgrounds the process it launches, not the forward target.
# Shared defaults also made concurrent sessions mutually kill each other's
# dedicated Chrome via the stale-reclaim logic ("Remote Chrome connection
# lost" / "Prompt did not appear"). Deriving both from the slug removes the
# whole class; env overrides still win.
derive_port() {  # slug -> deterministic port in 9300..9899, then scan upward to a free one
  local port; port=$((9300 + $(printf '%s' "$SLUG" | cksum | cut -d' ' -f1) % 600))
  local tries=0
  while [ "$tries" -lt 50 ]; do
    if ! curl -s --max-time 1 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 \
       && ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$port"; return 0
    fi
    port=$((port + 1)); tries=$((tries + 1))
  done
  echo "oracle-bg: no free port found in the derived 9300..9899 scan range" >&2
  return 1
}
PORT="${ORACLE_BG_PORT:-$(derive_port)}" || exit 4
[ -n "$PORT" ] || exit 4
PROFILE="${ORACLE_BG_PROFILE:-${TMPDIR:-/tmp}/oracle-bg-chrome-$SLUG}"
MODEL="${ORACLE_BG_MODEL:-Pro}"
URL="${ORACLE_CHATGPT_URL:-https://chatgpt.com/}"
# Exact pin: 0.17.1 fixes 0.17.0's broken composer send. Override with
# ORACLE_BG_PKG if a newer release restores Pro picking.
PKG="${ORACLE_BG_PKG:-@steipete/oracle@0.17.1}"
CHROME_ROOT="$HOME/Library/Application Support/Google/Chrome"

SCRAPER="$(cd "$(dirname "$0")" && pwd)/oracle-scrape.mjs"
[ -f "$SCRAPER" ] || echo "oracle-bg: WARNING: salvage scraper not found at $SCRAPER (symlinked install?) — completion salvage disabled" >&2
SALVAGE_OUT="${TMPDIR:-/tmp}/oracle-bg-${SLUG}-answer.md"

# Match ONLY Chrome processes on OUR exact profile dir — exact string with a
# boundary, never a bare pkill regex (which also matches sibling profiles
# like "$PROFILE-2" and would murder parallel runs).
profile_chrome_pids() {
  local pid cmd
  while read -r pid cmd; do
    case "$cmd" in
      *"--user-data-dir=$PROFILE "*|*"--user-data-dir=$PROFILE") printf '%s\n' "$pid" ;;
    esac
  done < <(ps -axo pid=,command=)
}

kill_profile_chrome() {
  local sig="${1:-TERM}" pids
  pids="$(profile_chrome_pids)"
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC2086
  kill "-$sig" $pids 2>/dev/null
  return 0
}

wait_profile_chrome_dead() {
  local i=0
  while [ -n "$(profile_chrome_pids)" ]; do
    [ "$i" -ge 20 ] && return 1
    sleep 0.5; i=$((i + 1))
  done
  return 0
}

LAUNCHED=0
ORACLE_PID=""
cleanup() {
  if [ -n "$ORACLE_PID" ]; then
    pkill -TERM -P "$ORACLE_PID" 2>/dev/null; kill -TERM "$ORACLE_PID" 2>/dev/null
  fi
  [ "$LAUNCHED" = 1 ] || return 0
  kill_profile_chrome TERM
  wait_profile_chrome_dead || { kill_profile_chrome KILL; sleep 1; }
  rm -rf "$PROFILE" 2>/dev/null
  [ -e "$PROFILE" ] && echo "oracle-bg: WARNING: could not fully remove $PROFILE (seeded cookies may remain)" >&2
}
trap cleanup EXIT

# 1. find the profile/cookie DB with the most chatgpt/openai cookies.
best_db=""; best_n=0
while IFS= read -r db; do
  [ -f "$db" ] || continue
  tmp="$(mktemp)"; sqlite3 "$db" ".backup '$tmp'" 2>/dev/null || { rm -f "$tmp"; continue; }
  n="$(sqlite3 "$tmp" "SELECT count(*) FROM cookies WHERE host_key LIKE '%chatgpt.com' OR host_key LIKE '%openai.com';" 2>/dev/null || echo 0)"
  rm -f "$tmp"
  if [ "${n:-0}" -gt "$best_n" ]; then best_n="$n"; best_db="$db"; fi
done < <(find "$CHROME_ROOT" -maxdepth 3 -name Cookies 2>/dev/null)
if [ -z "$best_db" ] || [ "$best_n" -eq 0 ]; then
  echo "oracle-bg: no ChatGPT cookies found under $CHROME_ROOT — sign into ChatGPT in Chrome first." >&2
  exit 2
fi
echo "oracle-bg: using cookies from: $best_db ($best_n chatgpt/openai cookies)" >&2

# 2. reclaim any stale dedicated Chrome from a prior run on this profile,
# then require a FREE CDP port: attaching to a foreign debugger would drive
# the wrong (possibly the user's real) browser.
if kill_profile_chrome TERM; then
  wait_profile_chrome_dead || { kill_profile_chrome KILL; sleep 1; }
fi
if curl -s --max-time 2 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
  echo "oracle-bg: port $PORT already has a DevTools listener that is not ours — refusing to attach. Set ORACLE_BG_PORT to a free port." >&2
  exit 4
fi

# 3. seed cookies, launch backgrounded.
mkdir -p "$PROFILE/Default"
sqlite3 "$best_db" ".backup '$PROFILE/Default/Cookies'" || { echo "oracle-bg: cookie seed failed" >&2; exit 3; }
# Seed ONLY chatgpt/openai cookies. Seeding the whole jar replays the user's
# Google session cookies from an unregistered browser instance; Google's
# cookie-theft detection then rotates/revokes the sessions and logs the user
# out of every Google account in their REAL Chrome (observed 2026-07,
# repeated mass logouts correlated 1:1 with runs). Never widen this.
sqlite3 "$PROFILE/Default/Cookies" \
  "DELETE FROM cookies WHERE host_key NOT LIKE '%chatgpt.com' AND host_key NOT LIKE '%openai.com'; VACUUM;" \
  || { echo "oracle-bg: cookie filter failed" >&2; exit 3; }
open -g -n -a "Google Chrome" --args \
  --remote-debugging-port="$PORT" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  || { echo "oracle-bg: could not launch Google Chrome (is it installed?)" >&2; exit 4; }
LAUNCHED=1
for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && break; sleep 1; done
curl -s "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 || { echo "oracle-bg: debug port $PORT never came up" >&2; exit 4; }

# 4. attach oracle to the authenticated background Chrome.
# Oracle runs in the background with a salvage watchdog: oracle <=0.16.1
# double-counts conversation turns against the 2026-07 ChatGPT DOM, so its
# completion poller can hang forever on a finished answer. If the on-page
# answer is terminal (per-turn action bar up, no stop button) and stable for
# 90s while oracle still hasn't finalized, we scrape it directly and end the
# run.
ORACLE_LOG="${TMPDIR:-/tmp}/oracle-bg-${SLUG}-run.log"
: > "$ORACLE_LOG"

salvage() {
  [ -f "$SCRAPER" ] || return 1
  node "$SCRAPER" --port "$PORT" --out "$SALVAGE_OUT" --stable-seconds "${1:-90}" 2>&1
}

# run_oracle <select|current>: launch oracle with the given model strategy,
# run the salvage watchdog beside it, return oracle's exit status. Output is
# mirrored to $ORACLE_LOG so the caller can classify failures.
run_oracle() {
  local strategy="$1" model_args=(--browser-model-strategy "$1")
  [ "$strategy" = "select" ] && model_args+=(--model "$MODEL")
  npx -y "$PKG" \
    --engine browser \
    --remote-chrome "127.0.0.1:$PORT" \
    "${model_args[@]}" \
    --slug "$SLUG" \
    --chatgpt-url "$URL" \
    --browser-attachments auto \
    --prompt "$(cat "$PROMPT_FILE")" \
    --timeout auto \
    ${EXTRA[@]+"${EXTRA[@]}"} > >(tee -a "$ORACLE_LOG") 2> >(tee -a "$ORACLE_LOG" >&2) &
  ORACLE_PID=$!

  while kill -0 "$ORACLE_PID" 2>/dev/null; do
    sleep 30
    kill -0 "$ORACLE_PID" 2>/dev/null || break
    if salvage 90 >/dev/null 2>&1; then
      # Answer proven terminal + stable 90s and oracle still spinning: its
      # detector will never fire. Scrape wins; stop oracle and report.
      pkill -TERM -P "$ORACLE_PID" 2>/dev/null; kill -TERM "$ORACLE_PID" 2>/dev/null
      wait "$ORACLE_PID" 2>/dev/null
      ORACLE_PID=""
      echo "oracle-bg: SALVAGED answer via CDP scrape (oracle's completion detector missed it)" >&2
      echo "oracle-bg: answer file: $SALVAGE_OUT" >&2
      echo "===== ORACLE ANSWER (salvaged) ====="
      cat "$SALVAGE_OUT"
      exit 0
    fi
  done

  wait "$ORACLE_PID"
  local st=$?
  ORACLE_PID=""
  return "$st"
}

run_oracle select
ORACLE_STATUS=$?

# Auto-fallback (2026-08-10): oracle <=0.17.1 cannot descend ChatGPT's
# "Advanced" picker submenu where the Pro tier now lives. When the failure is
# exactly that, retry once with the profile's current model and say so — an
# answer from the wrong tier silently labeled Pro would be worse than the
# failure.
if [ "$ORACLE_STATUS" -ne 0 ] \
  && grep -Eq "Unable to find model option|Unable to locate the ChatGPT model selector" "$ORACLE_LOG"; then
  echo "oracle-bg: model picker could not reach '$MODEL' (ChatGPT Advanced-submenu regression); retrying with the profile's CURRENT model. The answer below is NOT guaranteed Pro-tier — the run log footer names the model that actually answered." >&2
  SLUG="$(printf '%s' "$SLUG" | cut -d- -f1-4)-retry"
  SALVAGE_OUT="${TMPDIR:-/tmp}/oracle-bg-${SLUG}-answer.md"
  run_oracle current
  ORACLE_STATUS=$?
fi

if [ "$ORACLE_STATUS" -ne 0 ]; then
  # Last chance: if oracle failed after the answer landed (confirm-refusal /
  # timeout), the page still has it.
  if salvage 5 >/dev/null 2>&1; then
    echo "oracle-bg: oracle exited $ORACLE_STATUS but the answer was on the page; salvaged." >&2
    echo "oracle-bg: answer file: $SALVAGE_OUT" >&2
    echo "===== ORACLE ANSWER (salvaged) ====="
    cat "$SALVAGE_OUT"
    exit 0
  fi
else
  # Success path: oracle printed the answer on stdout above. Also write the
  # answer file so a durable artifact exists either way (best effort).
  salvage 5 >/dev/null 2>&1 && echo "oracle-bg: answer file: $SALVAGE_OUT" >&2
fi
exit "$ORACLE_STATUS"
