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

1. Find the Chrome profile that is actually signed into ChatGPT: back up
   each profile's cookie database (WAL-safe `sqlite3 .backup`) and count
   `chatgpt.com`/`openai.com` cookies. Highest count wins.
2. Launch a **dedicated** throwaway Chrome with `open -g` (macOS: open in
   background, no activation) on its own `--user-data-dir` and CDP debug
   port. Your real Chrome is never touched.
3. Seed the throwaway profile with the ChatGPT/OpenAI cookies **only** —
   every other cookie is deleted before launch (see the Google-logout
   footgun).
4. Attach `oracle --engine browser --remote-chrome 127.0.0.1:9222`. Oracle
   launches no browser of its own, so nothing can flash or take focus. The
   launcher asks for the Pro tier first and, if the picker cannot reach it
   (see the Advanced-submenu regression below), retries once with the
   profile's current model — telling you which model actually answered.
5. A salvage watchdog polls the page over CDP. If the answer is finished
   (action bar up, no stop button, text stable for 90 s) while oracle's own
   completion detector spins, the watchdog scrapes the answer directly,
   prints it, and ends the run cleanly.
6. On exit the throwaway Chrome is killed and the seeded profile deleted.

## Install

As a Claude Code skill:

    git clone https://github.com/XyraSinclair/quiet-oracle ~/.claude/skills/oracle

Claude Code discovers `SKILL.md` from there. The skill teaches the agent
the full doctrine: background-only rules, model targeting, Cloudflare
limits, fallbacks, and how to weigh the answer.

Standalone (no Claude Code):

    scripts/oracle-bg.sh /tmp/prompt.md fix-login-race

Write the prompt file first. Slugs must be 3–5 hyphen-separated words.

## Requirements

- macOS (the launcher uses `open -g` and the macOS Chrome profile paths).
  A Linux port needs an equivalent no-activation launch; PRs welcome.
- Google Chrome, signed into chatgpt.com with a Pro plan. (Plus works
  mechanically, but you don't get the Pro tier this repo exists for.)
- Node ≥ 22 (`npx` fetches `@steipete/oracle`; the scraper is
  dependency-free).
- `sqlite3` (ships with macOS).

## What it touches, honestly

The launcher reads your Chrome cookie database locally and copies only the
`chatgpt.com` and `openai.com` rows into a temporary profile on the same
machine. Nothing is sent anywhere except to ChatGPT itself, as your own
signed-in session. The temporary profile is deleted on exit. One known
exposure: the prompt text is passed to the oracle CLI on its command line,
so other local users can see it in the process list during the run. You
are automating your own account through your own browser; read your plan's
terms and make your own call.

## The footgun map

Each rule in the scripts exists because one of these drew blood.

**Focus stealing.** `--engine browser` alone launches a visible Chrome that
takes focus. `--browser-hide-window` still flashes on launch. The only
zero-flash path is attaching to a Chrome that is already running in the
background — which is exactly what the launcher does.

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

**The Advanced-submenu regression (2026-08).** ChatGPT moved the effort
tiers into an "Advanced" submenu that oracle ≤0.17.1 cannot descend, so
`--model "Pro"` now fails fast ("Unable to find model option matching
'Pro' … Available: Advanced, Model …, Effort Medium"). Separately, 0.17.0
broke the composer send ("Prompt did not appear in conversation before
timeout"); 0.17.1 sends correctly. The launcher pins 0.17.1, tries Pro
first, and on the picker error automatically retries once with
`--browser-model-strategy current` (your profile's active model),
disclosing loudly that the answer is not guaranteed Pro-tier — the run-log
footer names the model that actually answered. To get Pro back today, set
your ChatGPT default model to Pro once in your real browser; then
`current` IS Pro.

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
