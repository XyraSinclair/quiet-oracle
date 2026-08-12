#!/usr/bin/env node
// oracle-hide-window.mjs — keep every window of a CDP-controlled Chrome
// parked in a ~40px screen-corner sliver for the lifetime of this process.
//
// Why: `open -g` prevents focus steal but the window is still VISIBLE on the
// desktop, and macOS clamps window positions so a fully offscreen launch is
// impossible (measured 2026-08-12: requesting 20000,20000 at launch clamps
// fully onscreen at the bottom-right; CDP Browser.setWindowBounds clamps to
// screenW-40 / screenH-41, leaving a 40x41px corner sliver).
//
// Why not minimize: a minimized window stops BeginFrame, so ChatGPT's React
// UI never commits the optimistic prompt render and oracle fails with
// "Prompt did not appear in conversation before timeout" (measured
// 2026-08-12 on an otherwise healthy run). The sliver keeps the page
// visibility "visible" and rendering live while showing almost nothing —
// and the window is never raised, so anything the user opens covers it.
//
// New windows (Target.createTarget spawns/de-minimizes windows at their old
// bounds) are re-parked within ~1s.
//
// Usage: node oracle-hide-window.mjs --port 9222   (run in background; kill to stop)
// Dependency-free; node >= 22. Never activates a window.

const args = process.argv.slice(2);
const i = args.indexOf("--port");
const PORT = Number(i >= 0 ? args[i + 1] : "9222");

const connect = async () => {
  const v = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
  const ws = new WebSocket(v.webSocketDebuggerUrl);
  let id = 0;
  const pend = {};
  const send = (method, params = {}) =>
    new Promise((res, rej) => {
      const n = ++id;
      pend[n] = { res, rej };
      ws.send(JSON.stringify({ id: n, method, params }));
      setTimeout(() => {
        if (pend[n]) { pend[n].rej(new Error(`timeout ${method}`)); delete pend[n]; }
      }, 10000);
    });
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pend[m.id]) {
      m.error ? pend[m.id].rej(new Error(JSON.stringify(m.error))) : pend[m.id].res(m.result);
      delete pend[m.id];
    }
  };
  const closed = new Promise((r) => (ws.onclose = r));
  await new Promise((r) => (ws.onopen = r));
  return { send, closed };
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  let c;
  try { c = await connect(); } catch { process.exit(4); }
  let stop = false;
  c.closed.then(() => { stop = true; });
  const parked = new Map(); // windowId -> "left,top" we last settled at
  while (!stop) {
    try {
      const t = await c.send("Target.getTargets");
      for (const p of t.targetInfos.filter((x) => x.type === "page")) {
        let w;
        try { w = await c.send("Browser.getWindowForTarget", { targetId: p.targetId }); } catch { continue; }
        const b = w.bounds;
        if (b.windowState === "minimized") {
          // never leave it minimized: rendering stops and sends time out
          try { await c.send("Browser.setWindowBounds", { windowId: w.windowId, bounds: { windowState: "normal" } }); } catch {}
        }
        // ask for far off-screen; macOS clamps to the bottom-right sliver.
        // Re-park only when the window has drifted, to avoid churn.
        if (parked.get(w.windowId) !== `${b.left},${b.top}`) {
          try {
            await c.send("Browser.setWindowBounds", { windowId: w.windowId, bounds: { left: 20000, top: 20000, width: 900, height: 700 } });
            const after = await c.send("Browser.getWindowBounds", { windowId: w.windowId });
            parked.set(w.windowId, `${after.bounds.left},${after.bounds.top}`);
            console.error(`hide-window: parked window ${w.windowId} at ${after.bounds.left},${after.bounds.top} (corner sliver)`);
          } catch { /* window may have closed between calls */ }
        }
      }
    } catch { /* browser shutting down; the closed handler ends the loop */ }
    await sleep(1000);
  }
  process.exit(0);
})();
