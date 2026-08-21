import test from 'node:test';
import assert from 'node:assert/strict';
import { startStatusServer } from '../status-server.mjs';

const statusSnapshot = {
  proxy: 'ready',
  serena: 'ready',
  pid: 123,
  inFlight: 0,
  queued: 0,
  lastActivityAt: 10,
  idleDeadline: 20,
  manifestVersion: '1.7.1',
  manifestCompatible: true,
  lastError: null,
  apiKey: 'must-not-leak',
  arguments: { secret: 'must-not-leak' },
  result: { secret: 'must-not-leak' },
  stderr: 'must-not-leak',
};

test('binds loopback and serves a redacted no-store status response', async () => {
  const server = await startStatusServer({
    host: '127.0.0.1',
    port: 0,
    snapshotProvider: () => statusSnapshot,
  });
  try {
    assert.match(server.url, /^http:\/\/127\.0\.0\.1:\d+$/);
    const response = await fetch(`${server.url}/status`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const body = await response.json();
    assert.deepEqual(body, {
      proxy: 'ready', serena: 'ready', pid: 123, inFlight: 0, queued: 0,
      lastActivityAt: 10, idleDeadline: 20, manifestVersion: '1.7.1',
      manifestCompatible: true, lastError: null,
    });
    for (const prohibited of ['apiKey', 'arguments', 'result', 'stderr', 'must-not-leak']) {
      assert.equal(JSON.stringify(body).includes(prohibited), false);
    }
  } finally {
    await server.close();
  }
});

test('serves safe HTML at /ui and returns 404 for other paths', async () => {
  const server = await startStatusServer({ host: '127.0.0.1', port: 0, snapshotProvider: () => statusSnapshot });
  try {
    const ui = await fetch(`${server.url}/ui`);
    assert.equal(ui.status, 200);
    assert.equal(ui.headers.get('cache-control'), 'no-store');
    assert.match(ui.headers.get('content-type'), /^text\/html/);
    assert.equal((await ui.text()).includes('must-not-leak'), false);
    assert.equal((await fetch(`${server.url}/other`)).status, 404);
  } finally {
    await server.close();
  }
});

test('refuses non-loopback status hosts', async () => {
  await assert.rejects(
    startStatusServer({ host: '0.0.0.0', port: 0, snapshotProvider: () => statusSnapshot }),
    /loopback/i,
  );
});

test('refuses IPv6 loopback because the status endpoint is IPv4 localhost only', async () => {
  await assert.rejects(
    startStatusServer({ host: '::1', port: 0, snapshotProvider: () => statusSnapshot }),
    /127\.0\.0\.1/i,
  );
});
