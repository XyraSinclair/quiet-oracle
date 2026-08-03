#!/usr/bin/env node
// oracle-scrape.mjs — dependency-free CDP salvage for oracle-bg.sh.
//
// Why: @steipete/oracle <=0.16.1 double-counts conversation turns against the
// 2026-07 ChatGPT DOM (each message is a section[data-testid=conversation-turn-N]
// AND an inner div[data-message-author-role]; both match its turn selector), so
// its completion poller waits for a turn index that never arrives and the run
// dies at timeout even though the finished answer is on the page. This script
// reads the answer directly over CDP using the same terminal proof oracle uses
// (action bar visible, no stop button, non-empty stable text).
//
// Usage: oracle-scrape.mjs [--port 9222] [--out /path/answer.md] [--stable-seconds 0]
//   exit 0: answer complete (and stable for --stable-seconds); text written to --out (or stdout)
//   exit 1: not ready (no tab, still streaming, or not stable long enough)
// Requires node >= 22 (global WebSocket, fetch).
//
// Assumes a single chatgpt.com tab (true inside oracle-bg.sh's dedicated
// profile). Against a multi-tab Chrome it reads the first chatgpt.com tab
// CDP lists, which may not be the conversation you mean.

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : dflt;
};
const PORT = Number(opt('port', '9222'));
const OUT = opt('out', '');
const STABLE_S = Number(opt('stable-seconds', '0'));

const listRes = await fetch(`http://127.0.0.1:${PORT}/json/list`).catch(() => null);
if (!listRes) { console.error(`oracle-scrape: no CDP endpoint on ${PORT}`); process.exit(1); }
const targets = await listRes.json();
const tab = targets.find((t) => t.type === 'page' && /chatgpt\.com/.test(t.url || ''));
if (!tab || !tab.webSocketDebuggerUrl) { console.error('oracle-scrape: no chatgpt.com tab'); process.exit(1); }

const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let msgId = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
};
const send = (method, params) => new Promise((res) => {
  const id = ++msgId;
  pending.set(id, res);
  ws.send(JSON.stringify({ id, method, params }));
});
const evalJs = async (expression) => {
  const m = await send('Runtime.evaluate', { expression, returnByValue: true });
  if (m.result?.exceptionDetails) throw new Error(JSON.stringify(m.result.exceptionDetails).slice(0, 300));
  return m.result?.result?.value;
};

const SAMPLE_JS = `(() => {
  const asst = Array.from(document.querySelectorAll('[data-message-author-role="assistant"]'));
  const last = asst[asst.length - 1];
  const stop = document.querySelector('[data-testid="stop-button"], button[aria-label*="Stop streaming"], button[aria-label*="Stop generating"]');
  // Terminal proof must come from the LAST turn's own action bar. Never use
  // the conversation-header Share button: it is visible from the moment the
  // conversation exists, which would turn this check into a false-success
  // machine on partial answers.
  const turn = last ? (last.closest('[data-testid^="conversation-turn"]') || last.parentElement) : null;
  const bar = turn ? turn.querySelector('button[data-testid="copy-turn-action-button"], button[data-testid="good-response-turn-action-button"]') : null;
  return {
    url: location.href,
    text: last ? (last.innerText || last.textContent || '') : '',
    stopVisible: !!(stop && stop.getBoundingClientRect().width > 0),
    barVisible: !!(bar && bar.getBoundingClientRect().width > 0),
  };
})()`;

const sample = async () => await evalJs(SAMPLE_JS);
const terminal = (s) => s && !s.stopVisible && s.barVisible && s.text.trim().length > 0;

let a = await sample();
if (!terminal(a)) { console.error('oracle-scrape: not terminal (streaming or empty)'); ws.close(); process.exit(1); }
if (STABLE_S > 0) {
  await new Promise((r) => setTimeout(r, STABLE_S * 1000));
  const b = await sample();
  if (!terminal(b) || b.text !== a.text) { console.error('oracle-scrape: not stable'); ws.close(); process.exit(1); }
  a = b;
}
if (OUT) {
  const { writeFileSync } = await import('node:fs');
  writeFileSync(OUT, a.text);
  console.error(`oracle-scrape: wrote ${a.text.length} chars to ${OUT} (conversation: ${a.url})`);
} else {
  console.log(a.text);
  console.error(`oracle-scrape: ${a.text.length} chars (conversation: ${a.url})`);
}
ws.close();
process.exit(0);
