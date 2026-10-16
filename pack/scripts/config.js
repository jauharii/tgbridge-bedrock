// config.js — PURE module (no @minecraft imports) so node can unit-test it.
// The BDS-side readers live in main.js; this file only shapes values.

export const DEFAULT_OPT = {
  batching: { size: 8, timeoutMs: 4000 },
  polling: { pollMs: 1000, backoffMs: 3000 },
  messages: {
    mcToTg: {
      chat: "&lt;<name>&gt; <message>",
      join: "<name> joined the game",
      leave: "<name> left the game",
    },
    tgToMc: { message: "<name> > <message>" },
  },
};

// Accepts an object (variables.json nested JSON) OR a JSON string; never throws.
export function normalizeOpt(raw) {
  let v = raw;
  if (typeof raw === "string") {
    if (!raw.trim()) return structuredCloneSafe(DEFAULT_OPT);
    try { v = JSON.parse(raw); } catch { return structuredCloneSafe(DEFAULT_OPT); }
  }
  if (!v || typeof v !== "object") return structuredCloneSafe(DEFAULT_OPT);
  // shallow-merge two levels so a partial override keeps the other defaults
  const out = structuredCloneSafe(DEFAULT_OPT);
  for (const [k, val] of Object.entries(v)) {
    if (val && typeof val === "object" && !Array.isArray(val) && out[k] && typeof out[k] === "object") {
      out[k] = { ...out[k], ...val };
    } else {
      out[k] = val;
    }
  }
  return out;
}

export function structuredCloneSafe(o) { return JSON.parse(JSON.stringify(o)); }

// Telegram chat id: number, or null when unset/garbage. Accepts "-100123" and -100123.
export function parseChatId(raw) {
  if (raw === undefined || raw === null) return null;
  const s = String(raw).trim();
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

// A usable token: non-empty string that isn't a dead placeholder.
export function usableToken(raw) {
  const s = raw == null ? "" : String(raw).trim();
  if (!s || s === "[object Object]" || /^REPLACE/i.test(s)) return "";
  return s;
}

// SecretString may not coerce to a URL-safe string; prefer the plain variables.json
// value when the secret does not stringify usefully. (Same posture as the Java
// plugin, whose token is plaintext in config.yml.)
export function pickToken(secretValue, varValue) {
  const s = usableToken(secretValue);
  if (s) return { token: s, source: "secrets.json" };
  const v = usableToken(varValue);
  if (v) return { token: v, source: "variables.json" };
  return { token: "", source: "none" };
}
