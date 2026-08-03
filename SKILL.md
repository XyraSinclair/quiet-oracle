---
name: oracle
description: >-
  Consult GPT-5.x Pro (the ChatGPT Pro web entitlement) for hard problems —
  tough bugs, architecture trade-offs, security review, adversarial second
  opinions. Use when stuck, when the answer stays uncertain after real effort,
  or when a hard design call would benefit from a frontier second opinion.
  Triggered by "use oracle", "consult oracle", "ask GPT Pro". Browser mode is
  the default path (it uses the signed-in ChatGPT Pro entitlement, no metered
  API key). The browser MUST run in the background — never raise, activate,
  or steal focus.
---

# Oracle: browser-first, background-only

Oracle gives a strong non-Claude frontier model for hard problems. It drives
the [`@steipete/oracle`](https://github.com/steipete/oracle) CLI. Two hard
rules, in order of importance:

1. **Browser mode is the default.** It reuses the user's signed-in ChatGPT
   Pro web entitlement — no `OPENAI_API_KEY`, no metered billing. Do not
   check for, require, or fall back to an API key. A failed or absent key is
   not a reason to switch engines.

2. **The browser MUST stay in the background.** Never raise, activate, or
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

**Concurrency and Cloudflare (measured 2026-07):** parallel sessions work
with distinct `ORACLE_BG_PORT`/`ORACLE_BG_PROFILE` per run, but
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

**Version pin:** the recipe and the bug notes above are verified against
oracle 0.16.x. If a newer release breaks the launcher, pin
`ORACLE_BG_PKG=@steipete/oracle@0.16.1`.

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
button"), retry with `--browser-model-strategy current` (skip the picker;
uses the profile's active model).

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
