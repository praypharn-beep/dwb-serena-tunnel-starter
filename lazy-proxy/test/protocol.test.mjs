import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough, Writable } from 'node:stream';
import {
  createJsonLineReader,
  jsonRpcError,
  jsonRpcResult,
  writeJsonLine,
} from '../protocol.mjs';

const nextTurn = () => new Promise(resolve => setImmediate(resolve));

test('reader reconstructs split newline-delimited JSON messages', async () => {
  const input = new PassThrough();
  const seen = [];
  createJsonLineReader(input, {
    onMessage: value => seen.push(value),
    onError: error => { throw error; },
  });

  input.write('{"jsonrpc":"2.0","id":1,');
  input.write('"method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n');
  await nextTurn();

  assert.deepEqual(seen.map(value => value.id), [1, 2]);
});

test('reader isolates malformed JSON and non-object messages', async () => {
  const input = new PassThrough();
  const seen = [];
  const errors = [];
  createJsonLineReader(input, {
    onMessage: value => seen.push(value),
    onError: error => errors.push(error),
  });

  input.end('{oops}\n["not an object"]\n{"id":3}\n');
  await nextTurn();

  assert.equal(errors.length, 2);
  assert.deepEqual(seen, [{ id: 3 }]);
});

test('reader discards every chunk of an oversized line until its newline', async () => {
  const input = new PassThrough();
  const seen = [];
  const errors = [];
  createJsonLineReader(input, {
    onMessage: value => seen.push(value),
    onError: error => errors.push(error),
  });

  input.write('x'.repeat(1024 * 1024 + 1));
  input.end('{"id":"must-not-be-parsed"}\n{"id":"after"}\n');
  await nextTurn();

  assert.equal(errors.length, 1);
  assert.deepEqual(seen, [{ id: 'after' }]);
});

test('writer waits for drain when output applies backpressure', async () => {
  let chunks = '';
  const output = new Writable({
    write(chunk, encoding, callback) {
      chunks += chunk.toString();
      callback();
    },
  });
  const originalWrite = output.write.bind(output);
  output.write = function writeWithBackpressure(chunk, encoding, callback) {
    originalWrite(chunk, encoding, callback);
    setImmediate(() => output.emit('drain'));
    return false;
  };

  await writeJsonLine(output, { jsonrpc: '2.0', id: 4, method: 'ping' });
  assert.equal(chunks, '{"jsonrpc":"2.0","id":4,"method":"ping"}\n');
});

test('writer rejects non-object messages without writing them', async () => {
  let writes = 0;
  const output = new Writable({
    write(chunk, encoding, callback) {
      writes += 1;
      callback();
    },
  });

  for (const invalid of [undefined, null, [], 'message']) {
    await assert.rejects(writeJsonLine(output, invalid), /object/);
  }
  assert.equal(writes, 0);
});

test('helpers preserve JSON-RPC ids', () => {
  assert.deepEqual(jsonRpcResult('a', { ok: true }), {
    jsonrpc: '2.0', id: 'a', result: { ok: true },
  });
  assert.deepEqual(jsonRpcError(9, -32601, 'not found', { method: 'missing' }), {
    jsonrpc: '2.0',
    id: 9,
    error: { code: -32601, message: 'not found', data: { method: 'missing' } },
  });
});
