import assert from 'node:assert';
import { normalizeOpt, parseChatId, usableToken } from '/home/jauharijjd05/build/mc/tgbridge-bedrock/pack/scripts/config.js';

// full PATT string shape
const p = normalizeOpt('{ "chat": -1001234567890, "token": "123:ABC", "batching": { "size": 3 } }');
assert.strictEqual(p.chat, -1001234567890);
assert.strictEqual(p.token, '123:ABC');
assert.strictEqual(p.batching.size, 3);
assert.strictEqual(p.messages.mcToTg.chat, '&lt;<name>&gt; <message>'); // defaults preserved
// empty -> defaults, chat undefined
const d = normalizeOpt('');
assert.strictEqual(d.chat, undefined);
assert.strictEqual(parseChatId(d.chat), null);
// parseChatId shapes
assert.strictEqual(parseChatId('-100123'), -100123);
assert.strictEqual(parseChatId(''), null);
assert.strictEqual(parseChatId('abc'), null);
// usableToken shapes
assert.strictEqual(usableToken('123:ABC'), '123:ABC');
assert.strictEqual(usableToken(''), '');
assert.strictEqual(usableToken(null), '');
assert.strictEqual(usableToken('REPLACE_ME'), '');
console.log('config.test OK');
