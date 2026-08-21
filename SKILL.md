---
name: oracle
description: >-
  Consult GPT-5.x Pro (the ChatGPT Pro web entitlement) for hard problems —
  tough bugs, architecture trade-offs, security review, adversarial second
  opinions. Use when stuck, when the answer stays uncertain after real effort,
  or when a hard design call would benefit from a frontier second opinion.
  Triggered by "use oracle", "consult oracle", "ask GPT Pro". Scope ban: never
  consult Oracle about web crawling/scraping work or anything that could be
  interpreted as cyber abuse — keep those questions on models you run or bill
  directly. Browser mode is
  the default path (it uses the signed-in ChatGPT Pro entitlement, no metered
  API key). The browser MUST run in the background — never raise, activate,
  or steal focus.
---

# Oracle: browser-first, background-only

Oracle gives a strong non-Claude frontier model for hard problems. It drives
the [`@steipete/oracle`](https://github.com/steipete/oracle) CLI. Three hard
rules, in order of importance:

1. **Scope ban: never consult Oracle about web crawling/scraping activities
   or anything that could be interpreted as cyber abuse.** No crawl/scrape
   architecture or throughput questions, no rate-limit/ban/detection evasion,
   no proxy-fleet tactics, no captcha or access-control circumvention, no
   offensive-security asks — regardless of how legitimate the underlying
   project is. The consult surface is a signed-in ChatGPT account whose
   standing is load-bearing, and these topics invite provider flags no answer
   is worth. Keep such questions on models you run or bill directly; when in
   doubt, don't send them off-box.

2. **Browser mode is the default.** It reuses the user's signed-in ChatGPT
   Pro web entitlement — no `OPENAI_API_KEY`, no metered billing. Do not
   check for, require, or fall back to an API key. A failed or absent key is
   not a reason to switch engines.

3. **The browser MUST stay in the background.** Never raise, activate, or
   focus a window. Never call `page.bringToFront()`, `window.focus()`, or
   AppleScript `activate`. The launcher attaches over CDP, which does not
   foreground by construction — keep it that way. A popup or focus-steal
   while the user works is a serious violation, not a minor glitch. If the
   run genuinely needs human interaction (login, model picker, upload
   approval, CAPTCHA), STOP and tell the user what is needed in one line —
   do not foreground a window to resolve it yourself.

## The proven zero-flash path

Default: the bundled launcher `scripts/oracle-bg.sh` in this skill's
directory. It is the verified recipe and needs no flags to stay background:

    cat > /tmp/oracle-prompt.md << 'ORACLE_PROMPT_END'
    Self-contained briefing, situation, prior attempts, exact question,
    output shape. Indent inline code by four spaces; avoid nested backticks.
    ORACLE_PROMPT_END

    /path/to/this/skill/scripts/oracle-bg.sh /tmp/oracle-prompt.md fix-login-race

Run it in the background and poll the output. Slugs MUST be 3–5
hyphen-separated words — oracle 0.16.x rejects shorter ones.

The launcher finds the Chrome profile actually signed into ChatGPT, launches
a DEDICATED Chrome in the background via `open -g` (never activates, never
touches the user's main Chrome), seeds it with only the ChatGPT/OpenAI
cookies, attaches oracle via `--remote-chrome` (oracle launches nothing, so
no window flash), and cleans up on exit.

**Cookie filtering is a safety rule, not an optimization.** Seeding the whole
cookie jar replays the user's Google session cookies from an unregistered
browser instance. Google's cookie-theft detection then revokes those
sessions and logs the user out of every Google account in their REAL Chrome
(observed 2026-07, repeated mass logouts correlated 1:1 with runs). The
launcher copies only `chatgpt.com` and `openai.com` cookies. Never widen it.

**Master automation profile (fix 2026-08):** seeding runs from the user's
real Chrome session steals a live token — ChatGPT rotates session tokens on
use, the rotation lands in the automation profile, and the user's live
browser is left holding a stale session (observed: their ChatGPT degrades
until they force a fresh session). The launcher now prefers a durable
automation-owned profile at `~/.local/state/oracle-bg/chrome-master`
(override `ORACLE_BG_MASTER`): runs seed cookies from it, never from the
real Chrome, once it holds a ChatGPT session. One-time setup:
`oracle-bg.sh --setup-master` launches a background Chrome on the master
profile; the user foregrounds it, signs into ChatGPT once, and quits it.
Until the master holds a signed-in session the launcher REFUSES to run
(exit 2) — the legacy real-Chrome path is opt-in only via
`ORACLE_BG_ALLOW_LEGACY_SEED=1` and steals the user's live session; never
set it without the user's explicit say-so. Automation consults still share
the signed-in account's usage limits — no profile arrangement changes that.

**Use a DEDICATED ChatGPT account — this is the big one.** Automated
browser consults invalidate the ChatGPT account's *other* sessions
server-side. Concretely: after a consult runs, any normal browser you have
logged into that same ChatGPT account gets silently logged out. We observed
this on every single post-run check across two days, and the same account's
Codex OAuth refresh token died into a permanent "reauth needed" state in the
same window.

Two things make this trap especially nasty:

1. **It is not a local cookie bug, so local fixes do not touch it.** We first
   assumed the launcher was copying/stealing the live session token, and spent
   a fix cycle isolating the automation into its own Chrome profile that never
   reads the real cookie jar (see the "master automation profile" note above).
   The logouts continued unchanged. The invalidation happens on OpenAI's
   servers in response to the *account* being driven by automation — no
   profile, cookie-filter, or window trick on your machine can prevent it.

2. **Quiet gaps look like success.** You only notice the logout the next time
   you personally open ChatGPT, which may be hours later, so it is easy to
   conclude "the last fix worked" when really nobody looked. Confirm with the
   browser's own history/session state, not with "it seemed fine."

**The only reliable fix:** point the master automation profile at a ChatGPT
account you use for *nothing else*. Sign that dedicated account in once via
`--setup-master`; never sign your daily-driver account into the automation
profile. The periodic session-kill still happens, but now it only logs out
the throwaway account, which no human is ever sitting in. Automated consults
also consume that account's usage limits, which is a second reason to keep it
separate. If you share one account between your real browser and the
automation, expect to be logged out regularly — that is inherent, not a bug
you can patch here.

**Concurrency and Cloudflare (measured 2026-07; launcher fixed 2026-08):**
the launcher derives a per-run port (9300–9899, slug-hashed, scanned free)
and per-run profile (`oracle-bg-chrome-<slug>`) by default. Shared defaults
were a foreground hazard, not just a collision hazard: launching while
another session's Chrome held the same profile's singleton lock made Chrome
forward the open request to that existing instance, which raised a window
(`open -g` only backgrounds the process it launches). Shared defaults also
made concurrent sessions mutually kill each other's dedicated Chrome. Env
overrides still win; never point two live runs at one profile. Additionally,
chatgpt.com's edge challenges fresh automation profiles when several launch
in quick succession — the first 1–2 pass, later ones hit "Just a moment…"
(`cf_clearance` is IP+fingerprint-bound and never transfers with seeded
cookies). The challenge does not self-resolve, and a 45-minute cool-down did
not recover it. Doctrine: launch at most 2 concurrent sessions. If
Cloudflare fires, stop retrying — ask the user to open chatgpt.com once in
their real Chrome (this mints fresh clearance), or cover the question with
another clearly-labeled model, always saying which model actually answered.

**Completion salvage:** oracle ≤0.16.1 double-counts conversation turns
against the current ChatGPT DOM (each message is a
`section[data-testid=conversation-turn-N]` AND an inner
`div[data-message-author-role]`; both match its turn selector), so its
completion poller can wait forever on a finished answer and then refuse at
timeout. The launcher runs a salvage watchdog: if the on-page answer is
terminal (action bar up, no stop button) and stable for 90 s while oracle
still spins, it scrapes the answer over CDP (`scripts/oracle-scrape.mjs`,
dependency-free, node ≥22), prints it under
`===== ORACLE ANSWER (salvaged) =====`, writes
`$TMPDIR/oracle-bg-<slug>-answer.md` (the launcher prints the exact path),
and exits 0. It also tries a last-chance scrape when oracle exits nonzero.
The scraper works standalone to harvest a finished-but-uncollected answer:
`node scripts/oracle-scrape.mjs --port 9222` (single chatgpt.com tab
assumed).

**Model targeting (verified 2026-07):** the ChatGPT picker is two-axis — a
model-family submenu times an effort tier (Instant / Medium / High / Extra
High / Pro). The Pro entitlement is the "Pro" effort tier on the account's
current family, so `--model "Pro"` (the launcher's default) gets the current
family at Pro effort. Do not pass a combined family+Pro label (for example
`"5.6 Sol Pro"`): oracle ≤0.16.1 hard-rejects model strings that contain
both the family word and "pro". A bare family label selects the family at a
NON-Pro effort — not what "consult the oracle" means. Picker labels are
screen-scrape strings, not stable identifiers; verify against the live
picker when in doubt.

**Pro restored via effort pinning (2026-08-12):** ChatGPT moved the effort
tiers into a submenu of the composer pill that oracle ≤1.3.0 cannot descend
— `--model "Pro"` fails fast with "Unable to find model option matching
'Pro' … Available: Advanced, Model …, Effort …". The launcher now fixes
this itself: `scripts/oracle-pick-effort.mjs` opens the pill menu with one
trusted CDP click, keyboard-descends the Effort submenu (ArrowDown to the
`Effort` row, ArrowRight opens it onto Instant/Medium/High/Extra High/Pro
radios, ArrowDown to the tier, Enter), verifies the pill label, and exits.
The selection persists SERVER-SIDE per account, so after one success
`--browser-model-strategy current` IS Pro — the launcher pins first and
then runs oracle with `current`, skipping oracle's broken picker entirely
(smoke-verified 2026-08-12: the answer self-reported Pro). If pinning
fails it falls back to the old select→current chain, disclosing loudly
that the answer is not guaranteed Pro-tier. Separately, 0.17.0's composer
send is broken ("Prompt did not appear in conversation before timeout");
0.17.1 sends correctly, hence the pin below. Always report which model
actually answered.

**Window invisibility (2026-08-12):** `open -g` never steals focus but the
dedicated Chrome window was still VISIBLE on the desktop. macOS clamps
window positions, so a fully offscreen launch is impossible (requesting
20000,20000 clamps back onscreen; CDP `Browser.setWindowBounds` clamps to
a 40×41 px bottom-right corner sliver). Minimizing is NOT safe: a
minimized window stops BeginFrame, ChatGPT's UI never commits the prompt
render, and oracle dies with "Prompt did not appear in conversation before
timeout" (measured on an otherwise healthy run). The launcher therefore
runs `scripts/oracle-hide-window.mjs` for the whole run: it parks every
window of the run's Chrome in the clamped corner sliver (re-parking
new/de-minimized windows within ~1 s, un-minimizing any it finds) — worst
case on screen is a 40 px corner crumb that other windows freely cover.

**Version pin:** the recipe is verified against oracle 0.17.1 (the
launcher's default pin); the salvage/turn-count notes above date to 0.16.x.
Override with `ORACLE_BG_PKG` to trial a newer release.

WHY the manual flags fail: `--engine browser` alone launches a VISIBLE
focus-stealing Chrome; `--browser-hide-window` still flashes on launch; and
oracle's own cookie copy often misses the real session — the resulting auth
failure shows up as a misleading "Unable to locate the ChatGPT model
selector button" error. The launcher sidesteps all three. Reach for raw
flags only to debug.

## Manual fallback / mechanics

**CRITICAL FLAG:** the CLI defaults to a VISIBLE window that takes focus.
Always pass `--browser-hide-window` (own hidden window) or, to reuse an
already-running signed-in Chrome without launching anything,
`--remote-chrome <host:port>` (zero launch, zero popup risk). Without one of
these the browser WILL pop into the foreground. Never omit it.

Canonical manual invocation (run detached, prompt from `/tmp/oracle-prompt.md`
as above):

    npx -y @steipete/oracle \
      --engine browser \
      --browser-hide-window \
      --model "Pro" \
      --slug "short-memorable-slug" \
      --chatgpt-url "https://chatgpt.com/" \
      --browser-model-strategy select \
      --browser-attachments auto \
      --prompt "$(cat /tmp/oracle-prompt.md)" \
      --timeout auto

If the model picker fails ("Unable to locate the ChatGPT model selector
button" or "Unable to find model option"), retry with
`--browser-model-strategy current` (skip the picker; uses the profile's
active model). The launcher does this retry automatically with disclosure;
only manual runs need it by hand.

Poll with `npx -y @steipete/oracle status --hours 72`; reattach with
`npx -y @steipete/oracle session <slug>`. Pro runs can take 10–90 minutes; a
quiet session is not a failed one. If automation stalls, use
`--render --copy-markdown` and hand the user the packet to paste — do not
foreground a window.

See `references/browser-flags.md` for the full flag map and
`references/prompt-shapes.md` for prompt structures that get actionable
answers instead of vibes.

## API mode — narrow opt-in only

Use `--engine api` with a Pro-tier API model ONLY when the user explicitly
says "API". It needs a valid `OPENAI_API_KEY`. If the key is rejected,
report it and ask the user to refresh it — do not silently substitute
another model and call it "the oracle". (If the oracle is unavailable, you
may consult another model, but say clearly which model actually answered.)

## Finalize

Oracle's answer is input, not authority. Close with: a short "Oracle said"
summary, your own accept/reject/modify judgment, concrete next steps, and
the session slug/path. Triangulate — do not defer to it. Demand
first-principles reasoning and an explicit challenge-to-thesis section;
compare where the framing shifts, not only where answers agree.
