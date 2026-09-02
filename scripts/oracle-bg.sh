#!/usr/bin/env bash
# oracle-bg.sh — zero-focus background Oracle (GPT-5.x Pro) via the browser engine.
#
# Why this exists: `@steipete/oracle --engine browser` defaults to launching a
# VISIBLE Chrome that takes focus, and its in-app cookie copy can fail to pick up
# the real ChatGPT session (the "Unable to locate the ChatGPT model selector
# button" error is usually an AUTH failure in disguise). This script instead:
#   1. runs DIRECTLY on the persistent master automation profile when it is
#      signed in and free (default since 2026-08-11): token rotation lands in
#      the jar that owns it, so the session stays coherent indefinitely, and
#      the Cloudflare clearance stays bound to one stable fingerprint. One
#      run at a time (mkdir lock); concurrent runs fall back to seeded copies.
#   2. launches that Chrome in the background via `open -g` (never activates,
#      never touches the user's main Chrome — separate profile) and parks its
#      windows in the clamped ~40px bottom-right corner sliver for the whole
#      run via oracle-hide-window.mjs — `open -g` prevents focus steal but
#      the window was still visible on the desktop, macOS clamps
#      --window-position so a fully offscreen launch is impossible (measured
#      2026-08-12), and minimizing stops frame production so the composer
#      send breaks; the sliver keeps rendering live with at most a 40px
#      corner crumb on screen, never raised,
#   3. (seeded fallback only) copies ONLY the ChatGPT/OpenAI cookies from the
#      master (WAL-safe sqlite .backup) into a per-run profile,
#   4. pins the account's effort tier to Pro via oracle-pick-effort.mjs
#      (ChatGPT's Advanced-submenu picker that oracle <=0.17.1 cannot descend;
#      the choice persists server-side) and runs oracle with the CURRENT
#      model — which is then Pro-tier by construction,
#   5. attaches oracle via --remote-chrome (oracle launches nothing => no flash),
#   6. on exit quits the dedicated Chrome; deletes per-run seeded profiles,
#      NEVER the master.
#
# Usage:
#   oracle-bg.sh <prompt-file> [slug] [-- extra oracle args...]
#   oracle-bg.sh --setup-master     # one-time master-profile login flow
# Env overrides: ORACLE_BG_PORT (default: slug-derived 9300-9899, scanned
#   free), ORACLE_BG_PROFILE (default: $TMPDIR/oracle-bg-chrome-<slug>),
#   ORACLE_BG_MASTER (~/.local/state/oracle-bg/chrome-master),
#   ORACLE_BG_MODEL ("Pro"), ORACLE_CHATGPT_URL,
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

if [ $# -eq 0 ]; then
  echo "usage: oracle-bg.sh <prompt-file> [slug] [-- extra oracle args...] | oracle-bg.sh --setup-master" >&2
  exit 2
fi

# ── SAME-ACCOUNT SESSION-KILL GATE (2026-08): browser mode can log the user
# out of ChatGPT in their real browser SERVER-SIDE even with a fully isolated
# master profile (zero local contact with the real cookie jar). Observed:
# every post-run visit to chatgpt.com over two days found the real session
# dead; the same account's Codex OAuth refresh token died into permanent
# reauth-needed in the same window. OpenAI appears to revoke the account's
# other sessions after automated use — not fixable locally. Safe usage is a
# DEDICATED ChatGPT account for the automation, not the user's daily driver.
# Acknowledge the risk explicitly to run:
if [ "${1:-}" != "--setup-master" ] && [ "${ORACLE_BG_ACCEPT_SESSION_KILL:-0}" != 1 ]; then
  cat >&2 <<'SESSION_KILL_STOP'
oracle-bg: REFUSING to run — automated browser consults on a shared ChatGPT
account can invalidate the account's OTHER sessions server-side (the user's
real browser gets logged out; observed repeatedly 2026-08 even in
direct-master mode with zero local cookie contact). If the master profile is
signed into a DEDICATED automation account — or the user accepts being
logged out of their daily account — acknowledge explicitly:
  ORACLE_BG_ACCEPT_SESSION_KILL=1 oracle-bg.sh ...
SESSION_KILL_STOP
  exit 2
fi

# Master automation profile (fix 2026-08-10): seeding runs from the USER'S REAL
# Chrome session steals a live token — ChatGPT rotates session tokens on use,
# the rotation lands in the automation profile, and the user's real browser is
# left holding a stale/invalidated session (observed: live ChatGPT degrades
# until the user forces a fresh session by switching accounts and back). The
# durable master profile quarantines this: the user signs into ChatGPT ONCE in
# the automation-owned browser, and every run seeds from the master instead.
# Master sessions rotate only against automation use; the user's real browser
# is never touched. If the master session ever dies, rerun --setup-master.
MASTER="${ORACLE_BG_MASTER:-$HOME/.local/state/oracle-bg/chrome-master}"

# FORBIDDEN-ACCOUNT GUARD (2026-08). Set ORACLE_BG_FORBIDDEN_ACCOUNT to a
# marker for your daily identity (e.g. your email's local part). If it shows
# up in the master profile's plaintext stores — autofill from a login form is
# the proven trace — the profile is poisoned: someone signed the automation
# profile into the daily account, and every consult would run on (and
# server-side-invalidate) your real ChatGPT sessions. Refuse hard until the
# profile is purged and --setup-master is redone with the dedicated account.
FORBIDDEN_ACCOUNT="${ORACLE_BG_FORBIDDEN_ACCOUNT:-}"
check_master_untainted() {
  [ -n "$FORBIDDEN_ACCOUNT" ] || return 0
  [ -d "$MASTER/Default" ] || return 0
  local f
  for f in "Web Data" "Login Data" "Preferences"; do
    if [ -f "$MASTER/Default/$f" ] \
       && LC_ALL=C grep -aq -- "$FORBIDDEN_ACCOUNT" "$MASTER/Default/$f"; then
      echo "oracle-bg: REFUSING TO RUN — forbidden account marker '$FORBIDDEN_ACCOUNT' found in master profile ($f)." >&2
      echo "oracle-bg: the master profile must hold ONLY the dedicated automation account, never your daily account. Purge the profile and re-run --setup-master signing in as the dedicated account." >&2
      exit 2
    fi
  done
  return 0
}
check_master_untainted

if [ "${1:-}" = "--setup-master" ]; then
  mkdir -p "$MASTER"
  # Singleton guard: if a Chrome already holds this profile, a second `open`
  # FORWARDS the request to the running instance, which RAISES its window
  # over the user's work (observed 2026-08-10 16:19 — a setup-master re-run
  # popped the logged-out master window mid-session). Never relaunch.
  master_running=0
  while IFS= read -r cmd; do
    case "$cmd" in
      *"--user-data-dir=$MASTER "*|*"--user-data-dir=$MASTER") master_running=1 ;;
    esac
  done < <(ps -axo command=)
  if [ "$master_running" = 1 ]; then
    echo "oracle-bg: master Chrome is ALREADY RUNNING on $MASTER — not relaunching (a second open would raise its window over the user's work). Cmd-Tab to that Chrome, sign into ChatGPT there, then quit it." >&2
    exit 0
  fi
  open -g -n -a "Google Chrome" --args \
    --user-data-dir="$MASTER" --no-first-run --no-default-browser-check \
    "https://chatgpt.com/" \
    || { echo "oracle-bg: could not launch Google Chrome" >&2; exit 4; }
  cat >&2 <<'SETUP_MSG'
oracle-bg: a dedicated background Chrome is now running on the automation
master profile (it will NOT steal focus). To finish setup, foreground it
yourself (click its Dock icon or Cmd-Tab to the new Chrome instance), sign
in to ChatGPT once in that window, then quit that Chrome instance. After
that, oracle runs attach to this master profile directly (rotation-coherent,
one at a time) and never touch the session in your daily browser again.
SETUP_MSG
  exit 0
fi

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
# lost" / "Prompt did not appear", observed 3x on 2026-08-10). Deriving both
# from the slug removes the whole class; env overrides still win.
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
# Exact pin: 0.17.1 fixes 0.17.0's broken composer send; newer upstream
# releases (0.17.2/0.17.3/0.18.0) exist but are untested against this
# recipe. Override with ORACLE_BG_PKG to trial one.
PKG="${ORACLE_BG_PKG:-@steipete/oracle@0.17.1}"
CHROME_ROOT="$HOME/Library/Application Support/Google/Chrome"

SCRAPER="$(cd "$(dirname "$0")" && pwd)/oracle-scrape.mjs"
[ -f "$SCRAPER" ] || echo "oracle-bg: WARNING: salvage scraper not found at $SCRAPER (symlinked install?) — completion salvage disabled" >&2
HIDER="$(cd "$(dirname "$0")" && pwd)/oracle-hide-window.mjs"
[ -f "$HIDER" ] || echo "oracle-bg: WARNING: window hider not found at $HIDER — the dedicated Chrome window will be visible (background, never focused)" >&2
PICKER="$(cd "$(dirname "$0")" && pwd)/oracle-pick-effort.mjs"
[ -f "$PICKER" ] || echo "oracle-bg: WARNING: effort picker not found at $PICKER — Pro selection falls back to oracle's own (currently broken) picker" >&2
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
HIDE_PID=""
cleanup() {
  if [ -n "$ORACLE_PID" ]; then
    pkill -TERM -P "$ORACLE_PID" 2>/dev/null; kill -TERM "$ORACLE_PID" 2>/dev/null
  fi
  [ -n "$HIDE_PID" ] && kill -TERM "$HIDE_PID" 2>/dev/null
  # Direct mode releases the singleton lock; the MASTER profile itself is
  # NEVER deleted (it holds the durable signed-in session + CF clearance).
  if [ "${DIRECT:-0}" = 1 ]; then
    if [ "$LAUNCHED" = 1 ]; then
      kill_profile_chrome TERM
      wait_profile_chrome_dead || { kill_profile_chrome KILL; sleep 1; }
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    return 0
  fi
  [ "$LAUNCHED" = 1 ] || return 0
  kill_profile_chrome TERM
  wait_profile_chrome_dead || { kill_profile_chrome KILL; sleep 1; }
  rm -rf "$PROFILE" 2>/dev/null
  [ -e "$PROFILE" ] && echo "oracle-bg: WARNING: could not fully remove $PROFILE (seeded cookies may remain)" >&2
}
trap cleanup EXIT

# 1. pick the cookie source: the quarantined master profile, which must hold
# a SIGNED-IN ChatGPT session (an actual __Secure-next-auth.session-token —
# anonymous visit cookies do not count; a logged-out master previously passed
# the >0-cookies test and every run died at the login wall, 5x 2026-08-10).
# Seeding from the user's real Chrome is the documented session-stealer
# (token rotation lands in the automation profile and the user's live
# browser errors until they re-login — observed twice 2026-08-10), so it is
# NEVER automatic anymore: ORACLE_BG_ALLOW_LEGACY_SEED=1 is the only way in.
count_chatgpt_cookies() {  # db-file -> count (0 on any failure)
  local db="$1" tmp n
  [ -f "$db" ] || { echo 0; return; }
  tmp="$(mktemp)"; sqlite3 "$db" ".backup '$tmp'" 2>/dev/null || { rm -f "$tmp"; echo 0; return; }
  n="$(sqlite3 "$tmp" "SELECT count(*) FROM cookies WHERE host_key LIKE '%chatgpt.com' OR host_key LIKE '%openai.com';" 2>/dev/null || echo 0)"
  rm -f "$tmp"; echo "${n:-0}"
}
count_session_tokens() {  # db-file -> count of signed-in session-token cookies
  local db="$1" tmp n
  [ -f "$db" ] || { echo 0; return; }
  tmp="$(mktemp)"; sqlite3 "$db" ".backup '$tmp'" 2>/dev/null || { rm -f "$tmp"; echo 0; return; }
  n="$(sqlite3 "$tmp" "SELECT count(*) FROM cookies WHERE host_key LIKE '%chatgpt.com' AND name LIKE '__Secure-next-auth.session-token%';" 2>/dev/null || echo 0)"
  rm -f "$tmp"; echo "${n:-0}"
}
best_db=""; best_n=0
DIRECT=0
LOCKDIR="$MASTER.lock"
master_s="$(count_session_tokens "$MASTER/Default/Cookies")"
if [ "$master_s" -gt 0 ]; then
  # DIRECT-MASTER MODE (default since 2026-08-11): run oracle ON the master
  # profile itself instead of seeding a per-run copy. Seeded copies re-created
  # the rotation race one level down — ChatGPT rotates the session token
  # against the RUN profile's jar while the master keeps the pre-rotation
  # token, so the master session died every few runs and needed a re-login.
  # Running in place keeps rotation coherent (the jar that owns the token
  # receives the rotation) AND keeps the Cloudflare clearance bound to one
  # stable browser fingerprint (fresh per-run profiles are what trip the
  # "Just a moment…" challenge). Direct mode is a singleton: one run at a
  # time holds the master; concurrent runs fall back to seeded copies.
  master_busy=0
  while IFS= read -r cmd; do
    case "$cmd" in
      *"--user-data-dir=$MASTER "*|*"--user-data-dir=$MASTER") master_busy=1 ;;
    esac
  done < <(ps -axo command=)
  if [ "$master_busy" = 0 ] && mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCKDIR/pid"
    DIRECT=1
    PROFILE="$MASTER"
    echo "oracle-bg: DIRECT master-profile mode (session rotation stays coherent; profile preserved on exit; user's live session untouched)" >&2
  else
    # Stale-lock reclaim: a dead PID means a crashed run left the lock.
    if [ "$master_busy" = 0 ] && [ -f "$LOCKDIR/pid" ] && ! kill -0 "$(cat "$LOCKDIR/pid" 2>/dev/null)" 2>/dev/null; then
      rm -rf "$LOCKDIR"
      if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCKDIR/pid"
        DIRECT=1
        PROFILE="$MASTER"
        echo "oracle-bg: DIRECT master-profile mode (reclaimed stale lock from a dead run)" >&2
      fi
    fi
    if [ "$DIRECT" = 0 ]; then
      best_db="$MASTER/Default/Cookies"
      best_n="$(count_chatgpt_cookies "$best_db")"
      echo "oracle-bg: master profile is BUSY (another oracle run or an open master Chrome) — falling back to a SEEDED copy for this run. Note: heavy seeded use can rotate the master session out from under it; prefer serializing consults." >&2
    fi
  fi
  [ "$DIRECT" = 1 ] || echo "oracle-bg: using MASTER automation profile cookies ($best_n chatgpt/openai cookies, signed in)" >&2
elif [ "${ORACLE_BG_ALLOW_LEGACY_SEED:-0}" = 1 ]; then
  while IFS= read -r db; do
    n="$(count_chatgpt_cookies "$db")"
    if [ "${n:-0}" -gt "$best_n" ]; then best_n="$n"; best_db="$db"; fi
  done < <(find "$CHROME_ROOT" -maxdepth 3 -name Cookies 2>/dev/null)
  if [ -z "$best_db" ] || [ "$best_n" -eq 0 ]; then
    echo "oracle-bg: no ChatGPT cookies found under $CHROME_ROOT — sign into ChatGPT in Chrome first." >&2
    exit 2
  fi
  cat >&2 <<LEGACY_WARN
oracle-bg: WARNING: ORACLE_BG_ALLOW_LEGACY_SEED=1 — seeding from the user's
REAL Chrome session ($best_db).
ChatGPT rotates session tokens on use, so this run can invalidate the session
in the user's live browser (observed twice 2026-08-10: live ChatGPT errored
until the user re-logged-in). Prefer the master profile:
  $0 --setup-master
then sign in once in the background automation Chrome it launches.
LEGACY_WARN
  echo "oracle-bg: using cookies from: $best_db ($best_n chatgpt/openai cookies)" >&2
else
  cat >&2 <<'NO_MASTER'
oracle-bg: REFUSING to run — the master automation profile has no signed-in
ChatGPT session, and seeding from the user's real Chrome is disabled (it
steals the live session token; the user's browser then errors until they
re-login — observed twice 2026-08-10). Fix once:
  oracle-bg.sh --setup-master
then sign into ChatGPT in the background Chrome it launches, and quit it.
Escape hatch (dangerous, degrades the user's live ChatGPT):
  ORACLE_BG_ALLOW_LEGACY_SEED=1 oracle-bg.sh ...
NO_MASTER
  exit 2
fi

# 2. reclaim any stale dedicated Chrome from a prior run on this profile,
# then require a FREE CDP port: attaching to a foreign debugger would drive
# the wrong (possibly the user's real) browser. In DIRECT mode the reclaim
# is skipped — we only entered direct mode after verifying no Chrome holds
# the master, and killing here could hit a login window the user just
# opened in the race window.
if [ "$DIRECT" = 0 ]; then
  if kill_profile_chrome TERM; then
    wait_profile_chrome_dead || { kill_profile_chrome KILL; sleep 1; }
  fi
fi
if curl -s --max-time 2 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
  echo "oracle-bg: port $PORT already has a DevTools listener that is not ours — refusing to attach. Set ORACLE_BG_PORT to a free port." >&2
  exit 4
fi

# 3. seed cookies (seeded mode only — direct mode runs on the master jar
# in place), launch backgrounded.
if [ "$DIRECT" = 0 ]; then
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
fi
# Window invisibility (2026-08-12): spawn small at the clamped bottom-right
# corner (macOS clamps 20000,20000 back onscreen — fully offscreen launch is
# impossible), disable hidden-page throttling so ChatGPT streams normally
# while minimized, then keep every window minimized via the hider watchdog
# (Target.createTarget DE-minimizes, so a one-shot minimize is not enough).
open -g -n -a "Google Chrome" --args \
  --remote-debugging-port="$PORT" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --window-position=20000,20000 --window-size=900,700 \
  --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
  --disable-background-timer-throttling \
  || { echo "oracle-bg: could not launch Google Chrome (is it installed?)" >&2; exit 4; }
LAUNCHED=1
for _ in $(seq 1 30); do curl -s "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && break; sleep 1; done
curl -s "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 || { echo "oracle-bg: debug port $PORT never came up" >&2; exit 4; }
if [ -f "$HIDER" ]; then
  node "$HIDER" --port "$PORT" 2>/dev/null &
  HIDE_PID=$!
fi

# Stale-tab purge (2026-09): the persistent master profile can come back up
# with a PREVIOUS run's finished conversation tab (session restore after an
# unclean exit, or a tab someone left open). The salvage scraper reads the
# first chatgpt.com tab CDP lists, so a stale finished tab is a wrong-answer
# machine: the watchdog would prove "terminal + stable" against the OLD
# answer and end the run with it. Close every pre-existing chatgpt.com tab
# before the picker/oracle open their own (a blank tab is opened first so
# Chrome never hits zero tabs); conversation history lives server-side, so
# nothing is lost.
ORACLE_BG_PURGE_PORT="$PORT" node --input-type=module -e '
try {
  const base = `http://127.0.0.1:${Number(process.env.ORACLE_BG_PURGE_PORT)}`;
  const targets = await (await fetch(`${base}/json/list`)).json();
  const stale = targets.filter((t) => t.type === "page" && /chatgpt\.com/.test(t.url || ""));
  if (stale.length > 0) {
    await fetch(`${base}/json/new?about:blank`, { method: "PUT" }).catch(() => {});
    for (const t of stale) await fetch(`${base}/json/close/${t.id}`).catch(() => {});
    console.error(`oracle-bg: closed ${stale.length} stale chatgpt.com tab(s) left from a previous session`);
  }
} catch (e) {
  console.error(`oracle-bg: WARNING: stale-tab purge failed (${e.message}) — if a previous conversation tab survived, the salvage watchdog could scrape a STALE answer`);
  process.exit(1);
}
' || true

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
  # PKG_POLICY_BYPASS is inert unless the machine runs a local npx policy
  # hook that honors it; an exact already-reviewed pin is outside the
  # fresh-publish threat model such hooks defend against.
  PKG_POLICY_BYPASS=1 npx -y "$PKG" \
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

# Effort pinning (2026-08-12): ChatGPT moved effort tiers into a submenu of
# the composer pill that oracle <=0.17.1 cannot descend, so its own picker can
# no longer reach Pro. oracle-pick-effort.mjs descends it over CDP (trusted
# keyboard input; works minimized) and the selection persists SERVER-SIDE per
# account — after one success, the profile's current model IS Pro-tier. So:
# pin first, then run oracle with the current-model strategy (skipping its
# broken picker). If pinning fails, fall back to the old select->current
# chain with loud disclosure.
PINNED=0
if [ -f "$PICKER" ] && [ "$MODEL" = "Pro" ]; then
  if node "$PICKER" --port "$PORT" --tier Pro >&2; then
    PINNED=1
    echo "oracle-bg: effort tier pinned to Pro via the picker script; running oracle on the current model (= Pro-tier by construction)." >&2
  else
    echo "oracle-bg: effort pinning failed (see above); falling back to oracle's own picker." >&2
  fi
fi

if [ "$PINNED" = 1 ]; then
  run_oracle current
  ORACLE_STATUS=$?
else
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
