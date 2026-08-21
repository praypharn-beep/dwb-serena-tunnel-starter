import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { SerenaProcessManager } from '../serena-process.mjs';

const fakeServer = new URL('./fixtures/fake-serena.mjs', import.meta.url);
const manifest = {
  protocolVersion: '2025-06-18',
  tools: [{
    name: 'echo',
    description: 'Return the supplied text',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string' } },
      required: ['text'],
      additionalProperties: false,
    },
  }],
};

function managerFor({ behavior = 'normal', ...options } = {}) {
  let spawns = 0;
  const manager = new SerenaProcessManager({
    command: process.execPath,
    args: [fileURLToPath(fakeServer)],
    manifest,
    startupTimeoutMs: 200,
    idleTimeoutMs: 10_000,
    shutdownGraceMs: 200,
    spawnImpl(command, args, spawnOptions) {
      spawns += 1;
      return spawn(command, args, {
        ...spawnOptions,
        env: { ...process.env, FAKE_SERENA_BEHAVIOR: behavior, ...options.env },
      });
    },
    ...options,
  });
  return { manager, getSpawnCount: () => spawns };
}

async function eventually(predicate, message = 'condition was not met') {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('does not spawn until start is requested', async () => {
  const { manager, getSpawnCount } = managerFor();
  assert.equal(manager.snapshot().state, 'stopped');
  assert.equal(getSpawnCount(), 0);
  await manager.shutdown('test cleanup');
});

test('concurrent starts create one child', async () => {
  const { manager, getSpawnCount } = managerFor();
  try {
    const [first, second] = await Promise.all([manager.start(), manager.start()]);
    assert.equal(getSpawnCount(), 1);
    assert.equal(first.pid, second.pid);
    assert.equal(manager.snapshot().state, 'ready');
  } finally {
    await manager.shutdown('test cleanup');
  }
});

test('start performs initialize, initialized notification, and tools/list', async () => {
  const { manager } = managerFor();
  try {
    const started = await manager.start();
    assert.ok(Number.isInteger(started.pid));
    assert.deepEqual(started.tools, manifest.tools);
    const snapshot = manager.snapshot();
    assert.equal(snapshot.state, 'ready');
    assert.equal(snapshot.pid, started.pid);
    assert.equal(snapshot.inFlight, 0);
    assert.equal(typeof snapshot.lastActivityAt, 'number');
    assert.equal(typeof snapshot.idleDeadline, 'number');
    assert.equal(snapshot.lastError, null);
    assert.equal(snapshot.manifestCompatible, true);
  } finally {
    await manager.shutdown('test cleanup');
  }
});

test('startup timeout terminates the partial child and enters failed state', async () => {
  const { manager } = managerFor({
    behavior: 'slow-start',
    startupTimeoutMs: 25,
    env: { FAKE_SERENA_START_DELAY_MS: '300' },
  });
  await assert.rejects(manager.start(), /startup timed out/);
  await eventually(() => manager.snapshot().pid === null);
  assert.equal(manager.snapshot().state, 'failed');
  assert.match(manager.snapshot().lastError, /startup timed out/);
});

test('shutdown waits for active call before stopping', async () => {
  const { manager } = managerFor({
    env: { FAKE_SERENA_HOLD_CALL: 'true', FAKE_SERENA_CALL_DELAY_MS: '75' },
  });
  await manager.start();
  const call = manager.callTool('call-1', { name: 'echo', arguments: { text: 'hello' } });
  await eventually(() => manager.snapshot().inFlight === 1);
  const stopping = manager.shutdown('test shutdown');
  assert.notEqual(manager.snapshot().state, 'stopped');
  assert.deepEqual(await call, { content: [{ type: 'text', text: 'hello' }] });
  await stopping;
  assert.equal(manager.snapshot().state, 'stopped');
});

test('idle timer stops child only after the last call finishes', async () => {
  const timers = [];
  let now = 0;
  const clock = {
    now: () => now,
    setTimeout(callback, delay) {
      const timer = { callback, delay, cleared: false };
      timers.push(timer);
      return timer;
    },
    clearTimeout(timer) { timer.cleared = true; },
  };
  const { manager } = managerFor({
    idleTimeoutMs: 50,
    clock,
    env: { FAKE_SERENA_HOLD_CALL: 'true', FAKE_SERENA_CALL_DELAY_MS: '25' },
  });
  await manager.start();
  const call = manager.callTool('call-2', { name: 'echo', arguments: { text: 'later' } });
  await eventually(() => manager.snapshot().inFlight === 1);
  const startTimer = timers.at(-1);
  startTimer.callback();
  assert.equal(manager.snapshot().state, 'busy');
  await call;
  now = 50;
  const afterCallTimer = timers.at(-1);
  assert.notEqual(afterCallTimer, startTimer);
  afterCallTimer.callback();
  await eventually(() => manager.snapshot().state === 'stopped');
});
