import assert from 'node:assert';
import { tgEscape, renderMcPlayerChat, renderTgToMc, parseTgCommand, parseUpdate, clampMcText, UpdateCursor } from '../pack/scripts/lib.js';

// tgEscape
assert.strictEqual(tgEscape('<b>&x</b>'), '&lt;b&gt;&amp;x&lt;/b&gt;');
// template renders
const cfg = { messages: { mcToTg: { chat: '&#60<b><name></b>: <message>' } } };
assert.strictEqual(renderMcPlayerChat({}, 'Jau', 'hi'), '&lt;Jau&gt; hi');
assert.strictEqual(renderTgToMc({}, '@jau', 'yo'), '@jau > yo');
// command parse
assert.deepStrictEqual(parseTgCommand('/list'), { cmd: 'list', arg: '' });
assert.deepStrictEqual(parseTgCommand('/list@bob x'), { cmd: 'list', arg: 'x' });
assert.deepStrictEqual(parseTgCommand('/nope_start'), { cmd: 'nope_start', arg: '' }); // parse matches; dispatch decides what's bridged
// update parse
const u = { update_id: 1, message: { message_id: 5, chat: { id: -100, type: 'supergroup' }, from: { username: 'jau', first_name: 'Jau' }, text: 'hi' } };
assert.deepStrictEqual(parseUpdate(u), { kind: 'chat', text: 'hi', from: '@jau', chatId: -100, username: 'jau', isGroup: true });
assert.strictEqual(parseUpdate({ message: { text: undefined, photo: [] } } ).mediaType, 'photo');
assert.strictEqual(parseUpdate({ message: { chat: { id: 2, type: 'private' }, from: {}, text: 'x' } } ).isGroup, false);
// clamp
assert.strictEqual(clampMcText('a'.repeat(300), 256).endsWith('…'), true);
// cursor dedup
const cu = new UpdateCursor();
cu.fresh(1); cu.fresh(2);
assert.strictEqual(cu.seen(1), true); assert.strictEqual(cu.seen(99), false);
console.log('lib.test OK');
