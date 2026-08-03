# Oracle browser-mode flags

Checked against `oracle --help` from `@steipete/oracle` v0.10–v0.16. Verify
against your installed version when a flag misbehaves.

## Core flags

- `--engine browser`: force browser mode. Do not rely on auto-selection when the user explicitly asked for browser Oracle.
- `--browser-hide-window`: mandatory on every direct browser launch. Omit only
  when using the bundled `scripts/oracle-bg.sh` or
  attaching via `--remote-chrome` so Oracle launches no browser.
- `--model <model>`: Browser labels are screen-scrape strings. As of 2026-07 use `"Pro"` for the Pro effort tier (runs on the account's current model family). Never a combined family+Pro label (`"5.6 Sol Pro"`) — oracle ≤0.16.1 hard-rejects it. API-style names also work for some paths.
- `--chatgpt-url <url>`: Use the exact ChatGPT home/project/folder/workspace URL. This is the main way to keep consultations inside the intended browser context.
- `--browser-cookie-path <path>`: Explicit Chrome/Chromium cookie DB path for session reuse when default discovery fails.
- `--remote-chrome <host:port>`: Attach to an existing Chrome DevTools endpoint.
- `--remote-host <host:port>` + `--remote-token <token>`: Delegate browser runs to a remote `oracle serve` instance.
- `--browser-port <port>`: Use a fixed DevTools port when firewall/WSL/local routing makes random ports painful.

## Model picker strategy

- `--browser-model-strategy select`: default; choose requested model. Best when the user named a model.
- `--browser-model-strategy current`: keep active model. Best when the browser is already in the right project/model and picker automation is flaky.
- `--browser-model-strategy ignore`: skip model picker. Best for manual recovery after the user sets the model.

## Attachments

- `--browser-attachments auto`: default; inline small bundles, upload larger ones.
- `--browser-attachments never` or `--browser-inline-files`: force inline paste. Good when file uploads hang, account upload is disabled, or the bundle is small enough.
- `--browser-attachments always`: force upload. Good when inline paste is too fragile or too large.
- `--browser-bundle-files`: bundle all attachments into one archive before uploading. Good for many small files or when upload UI pain dominates.
- `--file <paths...>`: attach files, directories, or globs. Prefix exclusions with `!`, e.g. `--file "src/**/*.ts" --file "!src/**/*.test.ts"`.

## Preview and fallback

- `--dry-run summary`: preview without sending.
- `--files-report`: show token usage per file; combine with dry-run before large sends.
- `--render --copy-markdown`: assemble prompt+files, print it, and copy to clipboard for manual paste.
- `--render-plain`: avoid ANSI/highlighting when output will be captured.
- `--write-output <path>`: save the final assistant message so the answer survives a lost terminal.

## Session management

- `--slug <words>`: 3-5 word session name. Always use it.
- `oracle status --hours 72 --limit 50`: find recent/running sessions.
- `oracle session <slug-or-id>`: reattach.
- `oracle restart <id>`: re-run a stored session with cloned options.
- `--force`: bypass duplicate prompt guard; use only intentionally.
- `--timeout auto`: default; use longer explicit timeouts when the model/browser is slow.
- `--heartbeat <seconds>`: progress updates; increase or disable if noisy.

The CLI also drives Gemini web (YouTube and image flags); out of scope
here — see upstream `--help`.

## Practical failure map

- Login required: stop and ask the user to complete browser login; do not invent credentials.
- Model not visible: try `--browser-model-strategy current` after the user manually selects the model.
- Upload stuck: retry with `--browser-inline-files` for small/medium bundles or `--browser-bundle-files` for many files.
- Browser automation blocked: use `--render --copy-markdown` and give paste instructions.
- Duplicate run: reattach with `oracle session <slug>`; do not spawn a second browser tab unless forced.
