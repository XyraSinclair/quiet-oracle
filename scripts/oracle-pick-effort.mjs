#!/usr/bin/env node
// oracle-pick-effort.mjs — set ChatGPT's effort tier (default: Pro) via CDP.
//
// ChatGPT moved effort tiers into a submenu of the composer pill that
// @steipete/oracle <=0.17.1 cannot descend ("Unable to find model option
// matching 'Pro' ... Available: Advanced, Model GPT-5.6 Sol, Effort ...").
// This script descends it with trusted CDP input, entirely keyboard-driven
// after one trusted click on the pill, so it works on minimized/offscreen
// windows. The selection persists server-side per account, so after one
// success `--browser-model-strategy current` IS the chosen tier.
//
// Usage: node oracle-pick-effort.mjs --port 9222 [--tier Pro]
// Exit:  0 selected/already selected · 2 pill or menu not found (auth/DOM)
//        3 tier not offered (entitlement) · 4 CDP/connection failure
//
// Verified 2026-08-12 against chatgpt.com (menu: Advanced toggle, Model
// submenu, Effort submenu with Instant/Medium/High/Extra High/Pro radios;
// pill label mirrors the active tier and survives reload).
//
// Dependency-free; node >= 22 (global WebSocket). Never activates a window.

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : dflt;
};
const PORT = Number(opt("port", "9222"));
const TIER = opt("tier", "Pro");
const log = (m) => console.error(`pick-effort: ${m}`);

const die = (code, msg) => { log(msg); process.exit(code); };

const connect = async () => {
  const v = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
  const ws = new WebSocket(v.webSocketDebuggerUrl);
  let id = 0;
  const pend = {};
  const send = (method, params = {}, sessionId) =>
    new Promise((res, rej) => {
      const i = ++id;
      pend[i] = { res, rej };
      ws.send(JSON.stringify({ id: i, method, params, sessionId }));
      setTimeout(() => {
        if (pend[i]) { pend[i].rej(new Error(`timeout ${method}`)); delete pend[i]; }
      }, 20000);
    });
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pend[m.id]) {
      m.error ? pend[m.id].rej(new Error(JSON.stringify(m.error))) : pend[m.id].res(m.result);
      delete pend[m.id];
    }
  };
  await new Promise((r) => (ws.onopen = r));
  return { send };
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  let c;
  try { c = await connect(); } catch (e) { die(4, `cannot reach CDP on :${PORT} (${e.message})`); }

  // find or open a chatgpt.com tab
  const targets = await c.send("Target.getTargets");
  let page = targets.targetInfos.find((t) => t.type === "page" && t.url.includes("chatgpt.com"));
  if (!page) {
    const nt = await c.send("Target.createTarget", { url: "https://chatgpt.com/" });
    await sleep(1500);
    page = { targetId: nt.targetId };
  }
  const att = await c.send("Target.attachToTarget", { targetId: page.targetId, flatten: true });
  const sid = att.sessionId;

  const evalJs = async (expr) => {
    const r = await c.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, sid);
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  const key = async (k, code, kc) => {
    await c.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: k, code, windowsVirtualKeyCode: kc, nativeVirtualKeyCode: kc }, sid);
    await c.send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: kc, nativeVirtualKeyCode: kc }, sid);
    await sleep(300);
  };
  const focusText = () => evalJs(`(document.activeElement?.textContent||'').trim()`);
  const pillText = () => evalJs(
    `(document.querySelector('button.__composer-pill[aria-haspopup="menu"]')?.textContent||'').trim()`);

  // wait for the composer pill (React mounts it a beat after interactive)
  let pill = "";
  for (let i = 0; i < 40; i++) {
    pill = await pillText();
    if (pill) break;
    await sleep(500);
  }
  if (!pill) die(2, "composer effort pill never appeared (not signed in, or DOM changed)");
  if (pill === TIER) { log(`already at ${TIER}`); process.exit(0); }
  log(`current tier: ${pill}; selecting ${TIER}`);

  // one trusted click on the pill (works on minimized windows)
  const rect = await evalJs(
    `(()=>{const b=document.querySelector('button.__composer-pill[aria-haspopup="menu"]');
       const r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
  await c.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: rect.x, y: rect.y, pointerType: "mouse" }, sid);
  await c.send("Input.dispatchMouseEvent", { type: "mousePressed", x: rect.x, y: rect.y, button: "left", clickCount: 1, pointerType: "mouse" }, sid);
  await c.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: rect.x, y: rect.y, button: "left", clickCount: 1, pointerType: "mouse" }, sid);
  await sleep(900);

  const menuOpen = await evalJs(`!!document.querySelector('[role="menu"]')`);
  if (!menuOpen) die(2, "pill click did not open the picker menu");

  // keyboard: ArrowDown until the focused item is the Effort submenu trigger
  let found = false;
  for (let i = 0; i < 8; i++) {
    const t = await focusText();
    if (/^Effort/.test(t)) { found = true; break; }
    await key("ArrowDown", "ArrowDown", 40);
  }
  if (!found) { await key("Escape", "Escape", 27); die(2, "Effort row not reachable in the picker menu"); }

  // ArrowRight opens the submenu; focus lands on its first radio item
  await key("ArrowRight", "ArrowRight", 39);
  await sleep(500);

  // ArrowDown until the focused radio equals the requested tier
  let onTier = false;
  for (let i = 0; i < 10; i++) {
    const t = await focusText();
    if (t === TIER) { onTier = true; break; }
    await key("ArrowDown", "ArrowDown", 40);
  }
  if (!onTier) {
    await key("Escape", "Escape", 27);
    await key("Escape", "Escape", 27);
    die(3, `tier "${TIER}" not offered in the Effort submenu (entitlement?)`);
  }
  await key("Enter", "Enter", 13);
  await sleep(1200);
  await key("Escape", "Escape", 27); // menu can linger open after selection

  const after = await pillText();
  if (after !== TIER) die(2, `selection did not stick (pill reads "${after}")`);
  log(`selected ${TIER} (persists server-side; 'current' strategy now answers ${TIER}-tier)`);
  process.exit(0);
})().catch((e) => die(4, e.message));
