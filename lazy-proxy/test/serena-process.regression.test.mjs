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
  let child = null;
  const manager = new SerenaProcessManager({
    command: process.execPath,
    args: [fileURLToPath(fakeServer)],
    manifest,
    startupTimeoutMs: 200,
    idleTimeoutMs: 10_000,
    shutdownGraceMs: 20,
    spawnImpl(command, args, spawnOptions) {
      spawns += 1;
      child = spawn(command, args, {
        ...spawnOptions,
        env: { ...process.env, FAKE_SERENA_BEHAVIOR: behavior, ...options.env },
      });
      return child;
    },
    ...options,
  });
  return { manager, child: () => child, spawns: () => spawns };
}

const echo = text => ({ name: 'echo', arguments: { text } });
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function eventually(predicate, message = 'condition was not met') {
  const deadline = Date.now() + 1_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await pause(5);
  }
}

async function killFixture(manager, child) {
  if (child?.exitCode === null && child.signalCode === null) child.kill();
  await eventually(() => manager.snapshot().pid === null);
}

test('shutdown reserves queued call work before its startup microtask can spawn', async () => {
  const { manager, spawns } = managerFor();
  const call = manager.callTool('race', echo('never-start'));
  await manager.shutdown('immediate shutdown');
  await assert.rejects(call, error => error.data?.state === 'stopping');
  assert.equal(spawns(), 0);
});

test('rejects a call when the bounded queue is full', async () => {
  const { manager } = managerFor({ maxQueuedCalls: 1 });
  const first = manager.callTool('first', echo('first'));
  try {
    await assert.rejects(manager.callTool('second', echo('second')), /queue is full/);
    await first;
  } finally {
    await manager.shutdown('test cleanup');
  }
});

test('reports failed queued calls with structured MCP error data after a crash', async () => {
  const { manager } = managerFor({ behavior: 'crash-on-call' });
  const first = manager.callTool('first', echo('first'));
  const second = manager.callTool('second', echo('second'));
  try {
    await assert.rejects(first, /Serena exited/);
    await assert.rejects(second, error => error.data?.state === 'failed' && typeof error.data.reason === 'string');
  } finally {
    await manager.shutdown('test cleanup').catch(() => undefined);
  }
});

test('malformed Serena output rejects the pending call and clears inFlight', async () => {
  const { manager, child } = managerFor({ behavior: 'malformed-output' });
  await manager.start();
  const states = [];
  manager.on('state', snapshot => states.push(snapshot));
  try {
    await assert.rejects(Promise.race([
      manager.callTool('bad-output', echo('bad')),
      pause(100).then(() => { throw new Error('pending call was stranded'); }),
    ]), /Invalid Serena output/);
    assert.equal(manager.snapshot().state, 'failed');
    assert.equal(manager.snapshot().inFlight, 0);
    assert.equal(states.at(-1).inFlight, 0);
  } finally {
    await killFixture(manager, child());
  }
});

test('buffers split stderr lines before redacting secrets', async () => {
  const { manager } = managerFor({ behavior: 'stderr-split-secret' });
  try {
    await manager.start();
    assert.match(manager.stderrTail, /api_key=\[redacted\]/i);
    assert.doesNotMatch(manager.stderrTail, /secret/);
  } finally {
    await manager.shutdown('test cleanup');
  }
});

test('mismatched manifest fails startup and releases the child', async () => {
  const { manager } = managerFor({ behavior: 'mismatched-tools' });
  await assert.rejects(manager.start(), /manifest mismatch/);
  await eventually(() => manager.snapshot().pid === null);
  assert.equal(manager.snapshot().state, 'failed');
  assert.equal(manager.snapshot().manifestCompatible, false);
});

test('taskkill failure retains child ownership and prevents another start', async () => {
  let taskkillCalls = 0;
  const { manager, child, spawns } = managerFor({
    taskkillImpl: async () => {
      taskkillCalls += 1;
      throw new Error('taskkill access denied');
    },
  });
  await manager.start();
  child().stdin.end = () => child().stdin;
  try {
    await assert.rejects(manager.shutdown('forced shutdown'), /termination failed/);
    assert.equal(taskkillCalls, 1);
    assert.equal(manager.snapshot().state, 'failed');
    assert.equal(manager.snapshot().pid, child().pid);
    await assert.rejects(manager.start(), /termination failed/);
    assert.equal(spawns(), 1);
  } finally {
    await killFixture(manager, child());
  }
});

test('non-exiting child after successful taskkill remains owned and failed', async () => {
  let taskkillCalls = 0;
  const { manager, child } = managerFor({
    taskkillImpl: async () => { taskkillCalls += 1; },
  });
  await manager.start();
  child().stdin.end = () => child().stdin;
  try {
    await assert.rejects(manager.shutdown('forced shutdown'), /termination failed/);
    assert.equal(taskkillCalls, 1);
    assert.equal(manager.snapshot().state, 'failed');
    assert.equal(manager.snapshot().pid, child().pid);
  } finally {
    await killFixture(manager, child());
  }
});
