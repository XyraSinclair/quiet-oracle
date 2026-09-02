# quiet-oracle

Consult GPT-5.x Pro from a coding agent's terminal, through your signed-in
ChatGPT Pro browser session — in a background Chrome that never takes focus.

This is a [Claude Code](https://code.claude.com/docs) skill plus two small
scripts around Peter Steinberger's
[`@steipete/oracle`](https://github.com/steipete/oracle) CLI. The CLI does
the heavy lifting. This repo contributes the launch recipe that makes it
safe and invisible on a machine you are actively using, and the operating
doctrine we learned by running it daily.

## Why

Coding agents get better when a genuinely different frontier model reviews
their hardest calls. ChatGPT Pro gives flat-rate access to Pro-tier
reasoning, but only through the web UI. The naive automation paths all hurt:

- A default browser launch opens a visible Chrome that steals focus while
  you type.
- Pro answers can take 10–90 minutes. A blocking foreground tool wastes
  the whole window.
- Cookie copying done wrong gets you logged out of every Google account on
  your machine (details below).

`oracle-bg.sh` fixes all three. Your agent fires a consultation, keeps
working, and collects the answer when it lands. You never see a window.

## How it works

1. **One-time setup**: `oracle-bg.sh --setup-master` launches a dedicated
   background Chrome on a persistent automation-owned profile
   (`~/.local/state/oracle-bg/chrome-master`). You sign into ChatGPT there
   once and quit it. Your real Chrome is never read (the old
   cookie-copy-from-real-Chrome path still exists but is an explicit,
   warned opt-in — see the token-rotation footgun).
2. Each run attaches **directly to the master profile in place** (one run
   at a time via a lock; a concurrent run falls back to a per-run copy
   seeded from the master). Running in place keeps ChatGPT's session-token
   rotation coherent — the jar that owns the token receives the rotation —
   so the session survives indefinitely, and the Cloudflare clearance
   stays bound to one stable browser fingerprint.
3. The Chrome launches with `open -g` (background, no activation) and its
   windows are kept **minimized** for the whole run by a small CDP
   watchdog (`scripts/oracle-hide-window.mjs`) — so it is not merely
   unfocused but invisible.
4. The launcher pins the account's effort tier to **Pro** over CDP
   (`scripts/oracle-pick-effort.mjs` descends the picker submenu that the
   oracle CLI currently cannot; the choice persists server-side), then
   attaches `oracle --engine browser --remote-chrome 127.0.0.1:<port>
   --browser-model-strategy current` — the current model is Pro-tier by
   construction. Oracle launches no browser of its own, so nothing can
   flash or take focus.
5. A salvage watchdog polls the page over CDP. If the answer is finished
   (action bar up, no stop button, text stable for 90 s) while oracle's own
   completion detector spins, the watchdog scrapes the answer directly,
   prints it, and ends the run cleanly.
6. On exit the dedicated Chrome is quit; per-run seeded profiles are
   deleted, the master profile never is.

## Install

As a Claude Code skill:

    git clone https://github.com/XyraSinclair/quiet-oracle ~/.claude/skills/oracle

Claude Code discovers `SKILL.md` from there. The skill teaches the agent
the full doctrine: background-only rules, model targeting, Cloudflare
limits, fallbacks, and how to weigh the answer.

Standalone (no Claude Code):

    ORACLE_BG_ACCEPT_SESSION_KILL=1 scripts/oracle-bg.sh /tmp/prompt.md fix-login-race

Write the prompt file first. Slugs must be 3–5 hyphen-separated words. The
env var is a deliberate speed bump, not ceremony: it acknowledges the
same-account session-kill footgun below, which has no local fix. Without it
the launcher refuses (exit 2) and prints the same explanation.
(`--setup-master` runs without it.)

## Requirements

- macOS (the launcher uses `open -g` and the macOS Chrome profile paths).
  A Linux port needs an equivalent no-activation launch; PRs welcome.
- Google Chrome, plus a ChatGPT Pro plan signed into the master profile
  once via `--setup-master`. (Plus works mechanically, but you don't get
  the Pro tier this repo exists for.)
- Node ≥ 22 (`npx` fetches `@steipete/oracle`; the scraper is
  dependency-free).
- `sqlite3` (ships with macOS).

## What it touches, honestly

The default path never reads your real Chrome at all: the session lives in
a dedicated automation profile you signed into once. Concurrent runs copy
only the `chatgpt.com`/`openai.com` cookie rows from that master profile
into a temporary per-run profile on the same machine; the legacy
copy-from-your-real-Chrome path is a warned, explicit opt-in
(`ORACLE_BG_ALLOW_LEGACY_SEED=1`). Nothing is sent anywhere except to
ChatGPT itself, as your own signed-in session. Temporary profiles are
deleted on exit. One known exposure: the prompt text is passed to the
oracle CLI on its command line, so other local users can see it in the
process list during the run. You are automating your own account through
your own browser; read your plan's terms and make your own call.

## The footgun map

Each rule in the scripts exists because one of these drew blood.

**Focus stealing.** `--engine browser` alone launches a visible Chrome that
takes focus. `--browser-hide-window` still flashes on launch. The only
zero-flash path is attaching to a Chrome that is already running in the
background — which is exactly what the launcher does.

**The same-account session kill.** Automated browser consults invalidate
the ChatGPT account's *other* sessions server-side. After a consult runs,
any normal browser signed into the same account gets silently logged out —
observed on every post-run check across two days, with the account's Codex
OAuth refresh token dying into permanent "reauth needed" in the same
window. This is not a local cookie bug: it kept happening with the
automation fully isolated in its own profile, zero contact with the real
cookie jar, so no profile or cookie trick on your machine can prevent it.
The only reliable fix is a ChatGPT account dedicated to the automation —
signed into the master profile once via `--setup-master`, used by no human
for anything else. Because there is no local fix, the launcher refuses to
run until you acknowledge the trade explicitly with
`ORACLE_BG_ACCEPT_SESSION_KILL=1` in the environment.

**The Google mass-logout.** Seeding the whole cookie jar replays your
Google session cookies from an unregistered browser instance. Google's
cookie-theft detection then revokes those sessions and logs you out of
every Google account in your real Chrome. We observed repeated mass
logouts correlated 1:1 with runs before finding the cause. The launcher
filters to ChatGPT/OpenAI cookies only. Never widen the filter.

**Cloudflare vs. parallel sessions.** Fresh automation profiles get
challenged ("Just a moment…") when several launch in quick succession.
`cf_clearance` is IP+fingerprint-bound and never transfers with seeded
cookies, and the challenge does not self-resolve. Run at most 2 concurrent
sessions. If Cloudflare fires, open chatgpt.com once in your real Chrome
to mint fresh clearance — do not retry the automation.

**The two-axis model picker.** ChatGPT's picker is a model-family submenu
times an effort tier (Instant / Medium / High / Extra High / Pro). "Pro" is
an effort tier, not a model name. Ask for `--model "Pro"` and you get the
account's current family at Pro effort. oracle ≤0.16.1 hard-rejects
combined labels like "5.6 Sol Pro", and a bare family label silently gets
you a non-Pro tier.

**The effort-submenu regression, and its fix (2026-08).** ChatGPT moved
the effort tiers into a submenu of the composer pill that oracle ≤1.3.0
cannot descend, so `--model "Pro"` fails fast ("Unable to find model
option matching 'Pro' … Available: Advanced, Model …, Effort …"). The
launcher now pins the tier itself: `scripts/oracle-pick-effort.mjs`
descends the submenu over CDP (one trusted click on the pill, then pure
keyboard: ArrowDown to the Effort row, ArrowRight into the
Instant/Medium/High/Extra High/Pro radios, Enter on Pro) and verifies the
pill label. The choice persists server-side on your account, so the
launcher then simply runs oracle with `--browser-model-strategy current`
— which is Pro-tier by construction. If pinning fails, it falls back to
the old try-Pro-then-current chain and says loudly that the answer is not
guaranteed Pro-tier. Separately, 0.17.0 broke the composer send; the
launcher pins 0.17.1, which sends correctly.

**Minimized windows break the send.** The obvious way to hide the
dedicated Chrome — minimize it — stops Chrome's frame production, ChatGPT
never commits the optimistic prompt render, and oracle times out with
"Prompt did not appear in conversation". And macOS clamps window
positions, so you cannot launch or move a window fully offscreen either
(CDP `Browser.setWindowBounds` clamps to a 40×41 px corner sliver — we
measured). `scripts/oracle-hide-window.mjs` therefore parks the run's
windows in that clamped bottom-right sliver for the whole run —
rendering stays live, and at most a 40 px corner crumb is on screen,
never raised, freely covered by your own windows.

**The completion detector hang.** oracle ≤0.16.1 double-counts
conversation turns against the current ChatGPT DOM, so it can wait forever
on an answer that is already finished — and then discard it at timeout.
The salvage watchdog (`scripts/oracle-scrape.mjs`) proves the answer
terminal over CDP and rescues it. It also works standalone to harvest a
finished-but-uncollected answer: `node scripts/oracle-scrape.mjs --port 9222`.

**Answers are input, not authority.** The skill ends every consultation
with the agent's own accept/reject/modify judgment. A frontier second
opinion is a triangulation point, not an oracle in the literal sense —
despite the name.

## Credits

- [`@steipete/oracle`](https://github.com/steipete/oracle) by Peter
  Steinberger does the actual browser driving, prompt assembly, file
  attachment, and session management. This repo is a launch recipe and
  doctrine layer on top of it.
- The ChatGPT Pro web entitlement is what makes the economics work:
  frontier reasoning at a flat rate, no metered key.

## License

[Harvest License](LICENSE.md). Free to use, copy, modify, and sell. The
one condition: at most once in any twelve months (and never in your first
180 days), the Steward can ask you what the work has been worth to you,
and you must answer honestly within 60 days. An honest zero satisfies the
license in full. Only silence is a breach.
