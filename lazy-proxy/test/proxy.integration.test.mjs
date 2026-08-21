import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const cliPath = fileURLToPath(new URL('../cli.mjs', import.meta.url));
const fakeSerenaPath = fileURLToPath(new URL('./fixtures/fake-serena.mjs', import.meta.url));
const echoTool = {
  name: 'echo',
  description: 'Return the supplied text',
  inputSchema: {
    type: 'object',
    properties: { text: { type: 'string' } },
    required: ['text'],
    additionalProperties: false,
  },
};

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function eventually(predicate, message = 'condition was not met') {
  const deadline = Date.now() + 2_000;
  while (!await predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await delay(10);
  }
}

async function createHarness({ maxQueue = 8, behavior = 'normal' } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'lazy-proxy-'));
  const manifestPath = join(directory, 'manifest.json');
  const markerPath = join(directory, 'spawn-marker.txt');
  const exitMarkerPath = join(directory, 'exit-marker.txt');
  const wrapperPath = join(directory, 'fake-serena-wrapper.mjs');
  await writeFile(manifestPath, JSON.stringify({
    manifestVersion: 1,
    serenaVersion: 'test',
    protocolVersion: '2025-06-18',
    tools: [echoTool],
  }));
  await writeFile(wrapperPath, [
    "import { appendFileSync, writeFileSync } from 'node:fs';",
    "appendFileSync(process.env.SPAWN_MARKER, `${process.pid}\\n`);",
    "process.on('exit', () => writeFileSync(process.env.EXIT_MARKER, String(process.pid)));",
    `await import(${JSON.stringify(new URL(`file:///${fakeSerenaPath.replace(/\\\\/g, '/')}`).href)});`,
  ].join('\n'));

  const child = spawn(process.execPath, [
    cliPath,
    '--manifest', manifestPath,
    '--command', process.execPath,
    '--command-args', JSON.stringify([wrapperPath]),
    '--status', '127.0.0.1:0',
  ], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      LAZY_SERENA_MAX_QUEUE: String(maxQueue),
      FAKE_SERENA_BEHAVIOR: behavior,
      SPAWN_MARKER: markerPath,
      EXIT_MARKER: exitMarkerPath,
    },
  });
  const pending = new Map();
  let nextId = 1;
  let stdoutBuffer = '';
  let stderr = '';
  let downstreamExited = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdoutBuffer += chunk;
    let newline;
    while ((newline = stdoutBuffer.indexOf('\n')) !== -1) {
      const line = stdoutBuffer.slice(0, newline);
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      pending.get(message.id)?.resolve(message);
      pending.delete(message.id);
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));

  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
  const status = async () => {
    const match = stderr.match(/status (http:\/\/[^\s]+)/);
    assert.ok(match, `status URL unavailable; stderr was: ${stderr}`);
    return (await fetch(`${match[1]}/status`)).json();
  };
  await eventually(() => /status http:\/\//.test(stderr), 'CLI did not announce its status URL');
  return {
    request,
    status,
    marker: () => existsSync(markerPath) ? readFile(markerPath, 'utf8') : '',
    exitMarker: () => downstreamExited || existsSync(exitMarkerPath),
    async close() {
      if (child.exitCode === null) child.kill('SIGTERM');
      await exited;
      downstreamExited = existsSync(exitMarkerPath);
      await rm(directory, { recursive: true, force: true });
    },
  };
}

test('initialize and tools/list do not start fake Serena', async () => {
  const harness = await createHarness();
  try {
    const initialized = await harness.request('initialize', { protocolVersion: '2025-06-18' });
    assert.equal(initialized.result.protocolVersion, '2025-06-18');
    assert.deepEqual((await harness.request('tools/list')).result.tools, [echoTool]);
    assert.equal(await harness.marker(), '');
    assert.equal((await harness.status()).serena, 'stopped');
  } finally {
    await harness.close();
  }
});

test('first tools/call starts Serena and returns the tool result', async () => {
  const harness = await createHarness();
  try {
    const response = await harness.request('tools/call', { name: 'echo', arguments: { text: 'hello' } });
    assert.deepEqual(response.result, { content: [{ type: 'text', text: 'hello' }] });
    assert.match(await harness.marker(), /^\d+\n$/);
    assert.equal((await harness.status()).serena, 'ready');
  } finally {
    await harness.close();
  }
});

test('concurrent first calls produce one Serena pid', async () => {
  const harness = await createHarness();
  try {
    const [first, second] = await Promise.all([
      harness.request('tools/call', { name: 'echo', arguments: { text: 'one' } }),
      harness.request('tools/call', { name: 'echo', arguments: { text: 'two' } }),
    ]);
    assert.equal(first.result.content[0].text, 'one');
    assert.equal(second.result.content[0].text, 'two');
    assert.equal((await harness.marker()).trim().split('\n').length, 1);
  } finally {
    await harness.close();
  }
});

test('queue overflow returns JSON-RPC -32001 without starting another child', async () => {
  const harness = await createHarness({ maxQueue: 1, behavior: 'slow-start' });
  try {
    const first = harness.request('tools/call', { name: 'echo', arguments: { text: 'first' } });
    const overflow = await harness.request('tools/call', { name: 'echo', arguments: { text: 'second' } });
    assert.equal(overflow.error.code, -32001);
    await first;
    assert.equal((await harness.marker()).trim().split('\n').length, 1);
  } finally {
    await harness.close();
  }
});

test('unknown tools are rejected before downstream dispatch', async () => {
  const harness = await createHarness();
  try {
    const response = await harness.request('tools/call', { name: 'unknown_tool', arguments: {} });
    assert.equal(response.error.code, -32601);
    assert.equal(await harness.marker(), '');
  } finally {
    await harness.close();
  }
});

test('SIGTERM closes the downstream child', async () => {
  const harness = await createHarness();
  let pid;
  try {
    await harness.request('tools/call', { name: 'echo', arguments: { text: 'live' } });
    pid = Number((await harness.marker()).trim());
    assert.ok(Number.isInteger(pid));
  } finally {
    await harness.close();
  }
  await eventually(() => {
    try { process.kill(pid, 0); return false; } catch { return true; }
  }, 'fake Serena remained alive after proxy shutdown');
});
