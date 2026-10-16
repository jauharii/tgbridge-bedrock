// lib.js — pure helpers: Telegram escaping, commands routing, packet format.
// No @minecraft imports here so node/test can require it standalone.

// Escape user text for parse_mode HTML (refs tgbridge's TelegramHtml escape).
export function tgEscape(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Render a Minecraft -> Telegram message. Format mirrors tgbridge lang.yml keys.
export function renderMcPlayerChat(cfg, playerName, message) {
  const chat = cfg.messages?.mcToTg?.chat ?? "&lt;<name>&gt; <message>";
  return chat.replace("<name>", tgEscape(playerName)).replace("<message>", tgEscape(message));
}

export function renderMcJoin(cfg, playerName) {
  const t = cfg.messages?.mcToTg?.join ?? "<name> joined the game";
  return t.replace("<name>", tgEscape(playerName));
}

export function renderMcLeave(cfg, playerName) {
  const t = cfg.messages?.mcToTg?.leave ?? "<name> left the game";
  return t.replace("<name>", tgEscape(playerName));
}

// Render a Telegram -> Minecraft line. "<name> > msg" like tgbridge default.
export function renderTgToMc(cfg, sender, text, isReply = false, replyTo = "") {
  const t = cfg.messages?.tgToMc?.message ?? "<name> > <message>";
  return t.replace("<name>", sender).replace("<message>", text) + (isReply && replyTo ? ` (re: ${replyTo})` : "");
}

// Telegram commands: "/list" etc. Returns {cmd, arg} or null.
export function parseTgCommand(text) {
  const m = /^\/([a-zA-Z][a-zA-Z0-9_]{0,31})(?:@[\w_]+)?(?:\s+(.*\S))?\s*$/.exec(text);
  return m ? { cmd: m[1].toLowerCase(), arg: m[2] ?? "" } : null;
}

// Render a Telegram media event (photo etc) into a text placeholder for the MC chat.
export function renderTgMedia(ev) {
  const kind = ev.mediaType === "photo" ? "[photo]" : (ev.mediaType ?? "[media]");
  return ev.caption ? `${kind} ${tgEscape(ev.caption)}` : kind;
}

// Telegram Bot API update -> normalized message or null.
export function parseUpdate(u) {
  if (!u?.message) return null;
  const m = u.message;
  if (m.text == null) { // photos/docs: show caption or type
    const kind = Object.keys(m).find(k => ["photo","video","animation","voice","audio","document"].includes(k));
    if (!kind) return null;
    const name = [m.from?.username && "@" + m.from.username, m.from?.first_name].filter(Boolean)[0] ?? "?";
    return { kind: "media", mediaType: kind, caption: m.caption ?? "", from: name, chatId: m.chat?.id, isGroup: ["group","supergroup"].includes(m.chat?.type) };
  }
  const from = [m.from?.username && "@" + m.from.username, m.from?.first_name].filter(Boolean)[0] ?? "?";
  const isCmd = m.text.startsWith("/");
  return { kind: isCmd ? "command" : "chat", text: m.text, from, chatId: m.chat?.id, username: m.from?.username ?? "", isGroup: ["group","supergroup"].includes(m.chat?.type) };
}

// MC -> TG batching. Flush after SIZE msgs or FLUSH_MS.
export class Batcher {
  constructor(flushFn, { size = 8, flushMs = 4000 } = {}) {
    this.fn = flushFn; this.size = size; this.flushMs = flushMs;
    this.buf = [];
    // ponytail: setInterval always running (even empty). Upgrade: schedule on put only.
    this.timer = setInterval(() => this.flush(), flushMs);
    if (this.timer.unref) this.timer.unref();
  }
  put(msg) {
    this.buf.push(msg);
    if (this.buf.length >= this.size) this.flush();
    return this;
  }
  flush() {
    const items = this.buf.splice(0);
    if (!items.length) return;
    try {
      this.fn(items);
    } catch (e) {
      console.warn(`[tgbridge] batch flush error: ${e}`);
    }
  }
}

// One retry, exponential backoff — for transient 5xx like the 502 the Java bridge hit today.
export async function withRetry(fn, attempts = 3, baseMs = 500) {
  let last;
  for (let i = 0; i < attempts; i++) {
    try { return await fn(); }
    catch (e) { last = e; await new Promise(r => setTimeout(r, baseMs * (i + 1))); }
  }
  throw last;
}

// Truncate long Telegram->MC lines (Bedrock chat has a soft cap; 256 is generous beyond MC's per-message).
export function clampMcText(s, max = 256) {
  const t = String(s);
  return t.length > max ? t.slice(0, max - 1) + "…" : t;
}

// Dedup by Telegram update_id; BDS scripts restart on world reload so dedup restarts too.
export class UpdateCursor {
  constructor(map = new Map(), max = 512) {
    this.map = map; this.max = max; this.latest = -1;
  }
  fresh(id) {
    this.latest = Math.max(this.latest, id);
    this.map.set(id, Date.now());
    if (this.map.size > this.max) {
      const oldest = [...this.map.entries()].sort((a, b) => a[1] - b[1]).slice(0, this.map.size - this.max);
      for (const [k] of oldest) this.map.delete(k);
    }
  }
  seen(id) { return this.map.has(id); }
}
