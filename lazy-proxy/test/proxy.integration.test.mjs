import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { PassThrough } from 'node:stream';
import { copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createProxyServer } from '../server.mjs';

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

async function createHarness({ maxQueue = 8, behavior = 'normal', useDefaultCommand = false, taskkillFails = false, holdChildAfterStdin = false } = {}) {
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
    "appendFileSync(process.env.SPAWN_MARKER, `${process.pid}:${process.argv.slice(1).join('|')}\\n`);",
    "process.on('exit', () => writeFileSync(process.env.EXIT_MARKER, String(process.pid)));",
    `await import(${JSON.stringify(new URL(`file:///${fakeSerenaPath.replace(/\\\\/g, '/')}`).href)});`,
    "if (process.env.HOLD_CHILD_AFTER_STDIN === 'true') setInterval(() => {}, 1000);",
  ].join('\n'));
  if (useDefaultCommand) {
    await copyFile(process.execPath, join(directory, 'serena.exe'));
    await writeFile(join(directory, 'start-mcp-server'), `await import(${JSON.stringify(new URL(`file:///${wrapperPath.replace(/\\/g, '/')}`).href)});`);
  }
  const cliArgs = [cliPath, '--manifest', manifestPath, '--status', '127.0.0.1:0'];
  if (!useDefaultCommand) cliArgs.push('--command', process.execPath, '--command-args', JSON.stringify([wrapperPath]));

  const child = spawn(process.execPath, cliArgs, {
    cwd: useDefaultCommand ? directory : undefined,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      LAZY_SERENA_MAX_QUEUE: String(maxQueue),
      FAKE_SERENA_BEHAVIOR: behavior,
      SPAWN_MARKER: markerPath,
      EXIT_MARKER: exitMarkerPath,
      PATH: useDefaultCommand ? directory + ';' + process.env.PATH : process.env.PATH,
      NODE_ENV: taskkillFails ? 'test' : process.env.NODE_ENV,
      LAZY_SERENA_TEST_TASKKILL_FAIL: taskkillFails ? '1' : '',
      HOLD_CHILD_AFTER_STDIN: holdChildAfterStdin ? 'true' : 'false',
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
    stderr: () => stderr,
    child,
    marker: () => existsSync(markerPath) ? readFile(markerPath, 'utf8') : '',
    exitMarker: () => downstreamExited || existsSync(exitMarkerPath),
    async close({ signal = 'SIGTERM', endInput = false } = {}) {
      if (child.exitCode === null) {
        if (endInput) child.stdin.end();
        else child.kill(signal);
      }
      await exited;
      downstreamExited = existsSync(exitMarkerPath);
      const marker = existsSync(markerPath) ? await readFile(markerPath, 'utf8') : '';
      const downstreamPid = Number(marker.split(':')[0]);
      if (Number.isInteger(downstreamPid) && downstreamPid > 0) {
        await eventually(() => { try { process.kill(downstreamPid, 0); return false; } catch { return true; } });
      }
      let cleanupError;
      for (let attempt = 0; attempt < 20; attempt += 1) {
        try { await rm(directory, { recursive: true, force: true }); cleanupError = null; break; }
        catch (error) { cleanupError = error; await delay(50); }
      }
      if (cleanupError) throw cleanupError;
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
    assert.match(await harness.marker(), /^\d+:/);
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
    pid = Number((await harness.marker()).split(':')[0]);
    assert.ok(Number.isInteger(pid));
  } finally {
    await harness.close();
  }
  await eventually(() => {
    try { process.kill(pid, 0); return false; } catch { return true; }
  }, 'fake Serena remained alive after proxy shutdown');
});

function memoryManager({ shutdown = async () => {}, callTool = async (_id, params) => ({ ok: params.name }) } = {}) {
  return {
    starts: 0,
    shutdowns: 0,
    async start() { this.starts += 1; return { pid: 1, tools: [echoTool] }; },
    callTool,
    async shutdown(reason) { this.shutdowns += 1; return shutdown(reason); },
  };
}

function readMessages(stream) {
  const messages = [];
  let buffer = '';
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line) messages.push(JSON.parse(line));
    }
  });
  return messages;
}

test('proxy close propagates a lifecycle termination failure without discarding ownership', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const manager = memoryManager({ shutdown: async () => { throw new Error('Serena termination failed'); } });
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 1 });
  proxy.run();
  await assert.rejects(proxy.close(), /Serena termination failed/);
  assert.equal(manager.shutdowns, 1);
});

test('parser errors and invalid JSON-RPC requests receive their standard error codes', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const messages = readMessages(output);
  const manager = memoryManager();
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 4 });
  proxy.run();
  input.write('{bad json}\n');
  input.write('{}\n');
  input.write('{"jsonrpc":"1.0","id":2,"method":"ping"}\n');
  input.write('{"jsonrpc":"2.0","id":3,"method":"not/a/method"}\n');
  await eventually(() => messages.length === 4);
  assert.deepEqual(messages.map(message => [message.id, message.error.code]), [[null, -32700], [null, -32600], [null, -32600], [3, -32601]]);
  assert.equal(manager.starts, 0);
  await proxy.close();
});

test('ping and initialized notifications do not start Serena', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const messages = readMessages(output);
  const manager = memoryManager();
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 4 });
  proxy.run();
  input.write('{"jsonrpc":"2.0","id":1,"method":"ping"}\n');
  input.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
  await eventually(() => messages.length === 1);
  assert.deepEqual(messages[0].result, {});
  assert.equal(manager.starts, 0);
  await proxy.close();
});

test('serializes bounded output when a metadata flood meets backpressure', async () => {
  const input = new PassThrough();
  let writes = 0;
  const output = new PassThrough();
  output.write = () => { writes += 1; return false; };
  const manager = memoryManager();
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 1 });
  proxy.run();
  for (let id = 0; id < 100; id += 1) input.write(`${JSON.stringify({ jsonrpc: '2.0', id, method: 'ping' })}\n`);
  await delay(25);
  assert.equal(writes, 1);
  output.emit('drain');
  await delay(25);
  assert.ok(writes <= 2);
  await proxy.close();
});

test('a broken output initiates controlled shutdown without an unhandled rejection', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const manager = memoryManager();
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 1 });
  proxy.run();
  output.emit('error', new Error('broken stdout'));
  await eventually(() => manager.shutdowns === 1);
});

test('CLI defaults launch the exact Serena MCP command with approved timeouts', async () => {
  const harness = await createHarness({ useDefaultCommand: true });
  try {
    await harness.request('tools/call', { name: 'echo', arguments: { text: 'default' } });
    assert.match(await harness.marker(), /start-mcp-server\|--context\|chatgpt/);
  } finally {
    await harness.close();
  }
  const { PRODUCTION_DEFAULTS } = await import('../cli.mjs');
  assert.deepEqual(PRODUCTION_DEFAULTS, { idleTimeoutMs: 900000, startupTimeoutMs: 30000, statusAddress: '127.0.0.1:18012', maxQueuedCalls: 32 });
});

test('SIGINT closes the downstream child', async () => {
  const harness = await createHarness();
  let pid;
  try {
    await harness.request('tools/call', { name: 'echo', arguments: { text: 'live' } });
    pid = Number((await harness.marker()).split(':')[0]);
  } finally {
    await harness.close({ signal: 'SIGINT' });
  }
  await eventually(() => { try { process.kill(pid, 0); return false; } catch { return true; } });
});

test('stdin end closes the downstream child', async () => {
  const harness = await createHarness();
  let pid;
  try {
    await harness.request('tools/call', { name: 'echo', arguments: { text: 'live' } });
    pid = Number((await harness.marker()).split(':')[0]);
  } finally {
    await harness.close({ endInput: true });
  }
  await eventually(() => { try { process.kill(pid, 0); return false; } catch { return true; } });
});

test('notification method carrying an id receives a response without starting Serena', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const messages = readMessages(output);
  const manager = memoryManager();
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 2 });
  proxy.run();
  input.write('{"jsonrpc":"2.0","id":8,"method":"notifications/initialized"}\n');
  await eventually(() => messages.length === 1);
  assert.deepEqual(messages[0], { jsonrpc: '2.0', id: 8, result: {} });
  assert.equal(manager.starts, 0);
  await proxy.close();
});

test('overload explicitly closes transport rather than silently dropping request ids', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  let release;
  const manager = memoryManager({ callTool: () => new Promise(resolve => { release = resolve; }) });
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 1 });
  proxy.run();
  input.write('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{}}}\n');
  await eventually(() => manager.starts === 1);
  input.write('{"jsonrpc":"2.0","id":2,"method":"ping"}\n');
  input.write('{"jsonrpc":"2.0","id":3,"method":"ping"}\n');
  await eventually(() => output.writableEnded, 'overload did not explicitly close the MCP transport');
  release({ ok: true });
});

test('rejected response write during active backpressure closes the proxy cleanly', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  output.write = () => false;
  const manager = memoryManager();
  const proxy = createProxyServer({ input, output, manifest: { protocolVersion: '2025-06-18', tools: [echoTool] }, manager, maxQueuedCalls: 1 });
  proxy.run();
  input.write('{"jsonrpc":"2.0","id":1,"method":"ping"}\n');
  await delay(10);
  output.emit('error', new Error('write rejected while blocked'));
  await eventually(() => manager.shutdowns === 1);
});

test('CLI parser rejects IPv6 loopback before loading a manifest', async () => {
  const child = spawn(process.execPath, [cliPath], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, LAZY_SERENA_STATUS_ADDR: '::1:18012' },
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr += chunk; });
  const { code } = await new Promise(resolve => child.once('exit', (exitCode, signal) => resolve({ code: exitCode, signal })));
  assert.equal(code, 1);
  assert.match(stderr, /LAZY_SERENA_STATUS_ADDR/);
});

test('CLI keeps a failed-termination proxy alive and reports a nonzero shutdown failure', async () => {
  const harness = await createHarness({ taskkillFails: true, holdChildAfterStdin: true });
  let downstreamPid;
  try {
    await harness.request('tools/call', { name: 'echo', arguments: { text: 'hold' } });
    downstreamPid = Number((await harness.marker()).split(':')[0]);
    harness.child.stdin.end();
    await delay(7_000);
    assert.equal(harness.child.exitCode, null);
    const status = await harness.status();
    assert.equal(status.serena, 'failed');
    assert.match(harness.stderr(), /shutdown failed/i);
    assert.match(status.lastError, /termination failed/i);
  } finally {
    if (harness.child.exitCode === null) harness.child.kill('SIGKILL');
    if (Number.isInteger(downstreamPid) && downstreamPid > 0) {
      try { process.kill(downstreamPid, 'SIGKILL'); } catch { /* already stopped */ }
    }
    await harness.close();
  }
});
