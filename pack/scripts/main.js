// main.js — tgbridge Bedrock behavior pack.
// Minecraft -> Telegram : chat / join / leave via world.afterEvents + Batcher.
// Telegram -> Minecraft : long poll getUpdates, /list supported, group chats only.
// Token posture: plaintext token in variables.json (PATT.chat + PATT.token), the
// same file the Java tgbridge keeps its token in (config.yml). A SecretString can
// never be used here: Telegram's auth lives in the URL EVENT (/bot<TOKEN>/method)
// and SecretString is only printable inside HttpHeader values.
import { world, system } from "@minecraft/server";
import { http, HttpRequest, HttpRequestMethod, HttpHeader } from "@minecraft/server-net";
import { normalizeOpt, parseChatId, usableToken } from "./config.js";
import {
  tgEscape, renderTgToMc, renderTgMedia, parseTgCommand, parseUpdate,
  Batcher, withRetry, clampMcText
} from "./lib.js";

// variables.json (config/default/variables.json):
// { "PAPI": "https://api.telegram.org",                       <- optional; leave unless self-hosted bot api
//   "PATT": "{ \"chat\": -1001234567890, \"token\": \"123:ABB...\" }" }
// PATT is a quoted JSON *string*; unzip into {chat, token} here.

const rawVars = {};
try {
  const admin = await import("@minecraft/server-admin");
  rawVars.apiRaw = admin.variables?.get?.("PAPI") ?? "";
  rawVars.attRaw = admin.variables?.get?.("PATT") ?? "";
} catch (e) {
  console.error("[tgbridge] @minecraft/server-admin unavailable — pack works only on a Bedrock Dedicated Server (beta-apis experiment ON for this world): " + (e?.message ?? e));
  // fall through to EMPTY vars so boot diagnostics tell the operator exactly what is missing
}

const PATT = normalizeOpt(rawVars.attRaw);
const chatId = parseChatId(PATT.chat);
const token = usableToken(PATT.token);
const apiBase = String(rawVars.apiRaw || "").trim() || "https://api.telegram.org";
const opt = PATT;

function log(...a) { console.log(`[tgbridge] ${a.join(" ")}`); }
function warn(...a) { console.warn(`[tgbridge] ${a.join(" ")}`); }

// ---- HTTP core ----
async function api(method, body) {
  const req = new HttpRequest(`${apiBase}/bot${token}/${method}`);
  req.method = HttpRequestMethod.Post;
  req.body = JSON.stringify(body);
  req.headers = [new HttpHeader("Content-Type", "application/json")];
  req.timeout = 30; // >= long-poll wait (25)
  const r = await http.request(req);
  let j;
  try { j = JSON.parse(r.body); } catch { throw new Error(`${method}: non-json: ${String(r.body).slice(0, 160)}`); }
  if (!j?.ok) throw new Error(`${method}: ${JSON.stringify(j).slice(0, 160)}`);
  return j.result;
}

// ---- outbound batching ----
const batcher = new Batcher(
  items => {
    const text = items.map(i => (i.media ? renderTgMedia(i) : i.text)).join("\n");
    withRetry(() =>
      api("sendMessage", { chat_id: chatId, text, parse_mode: "HTML", link_preview_options: { is_disabled: true } })
    , 2).catch(e => warn(`send: ${e.message ?? e}`));
  },
  { size: opt.batching?.size ?? 8, flushMs: opt?.batching?.timeoutMs ?? 4000 }
);

// ---- Minecraft -> Telegram ----
world.afterEvents.chatSend.subscribe(ev => {
  if (!ev.message || ev.message.startsWith("/")) return;
  const fmt = opt.messages?.mcToTg?.chat ?? "&lt;<name>&gt; <message>";
  batcher.put({ text: fmt.replace("<name>", tgEscape(ev.sender.name)).replace("<message>", tgEscape(ev.message)) });
});
world.afterEvents.playerJoin.subscribe(ev => {
  const fmt = opt.messages?.mcToTg?.join ?? "<name> joined the game";
  batcher.put({ text: fmt.replace("<name>", tgEscape(ev.playerName)) });
});
world.afterEvents.playerLeave.subscribe(ev => {
  const fmt = opt.messages?.mcToTg?.leave ?? "<name> left the game";
  batcher.put({ text: fmt.replace("<name>", tgEscape(ev.playerName)) });
});

// ---- Telegram -> Minecraft ----
function dispatchTg(u) {
  const p = parseUpdate(u);
  if (!p) return;
  if (chatId != null && p.chatId !== chatId) return; // not our chat
  if (!p.isGroup) return;                            // DMs never forwarded (parity)
  if (p.kind === "chat") {
    const fmt = opt.messages?.tgToMc?.message ?? "<name> > <message>";
    world.sendMessage(clampMcText(fmt.replace("<name>", p.from).replace("<message>", p.text), 256));
  } else if (p.kind === "command") {
    const c = parseTgCommand(p.text);
    if (c?.cmd === "list") {
      const names = world.getAllPlayers().map(x => x.name);
      batcher.put({ text: names.length ? `☑ <b>${tgEscape(names.join(", "))}</b>` : "☑ (nobody online)" });
    }
  } else if (p.kind === "media") {
    batcher.put({ media: true, mediaType: p.mediaType, from: p.from, caption: p.caption });
  }
}

// ---- long poll ----
// Telegram allows exactly ONE getUpdates consumer per bot token. A second one gets
// 409 Conflict forever. Treat 409 as FATAL (stop polling, say why) instead of
// retrying forever in the background — a silent spin looks like "connected but dead".
const FATAL = new Set([409]);
let polling = false;
async function pollLoop() {
  if (polling) return;
  polling = true;
  let offset = 0;
  while (polling) {
    try {
      const updates = await api("getUpdates", { timeout: 25, offset, limit: 20, allowed_updates: ["message"] });
      for (const u of updates) {
        offset = Math.max(offset, (u.update_id ?? 0) + 1); // ack before handle — a bad update can't re-loop
        dispatchTg(u);
      }
    } catch (e) {
      const msg = String(e?.message ?? e);
      warn(`poll: ${msg}`);
      if (FATAL.has(+(/error":(\d+)/.exec(msg) || [])[1])) {
        warn("409 = another getUpdates consumer already owns this bot token (usually the Java tgbridge). " +
             "STOPPED. Give this pack its OWN bot token, or remove the other consumer.");
        return;
      }
      await new Promise(r => setTimeout(r, opt.polling?.backoffMs ?? 3000));
    }
  }
}

// ---- boot diagnostics (never prints the token) ----
system.runTimeout(() => {
  log(`chat=${chatId ?? "✗"} bot=${token ? "✓" : "✗"} api=${apiBase}`);
  if (!chatId || !token) { warn("config incomplete — polling disabled. PATT needs {\"chat\": ... , \"token\": \"...\"}"); return; }
  pollLoop().catch(e => warn(`loop: ${e.message ?? e}`));
}, 20);
