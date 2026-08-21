import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadManifest } from './manifest.mjs';
import { SerenaProcessManager } from './serena-process.mjs';
import { createProxyServer } from './server.mjs';
import { startStatusServer } from './status-server.mjs';

export const PRODUCTION_DEFAULTS = Object.freeze({ idleTimeoutMs: 900000, startupTimeoutMs: 30000, statusAddress: '127.0.0.1:18012', maxQueuedCalls: 32 });
export const PRODUCTION_SERENA_COMMAND = Object.freeze({ command: 'serena', args: Object.freeze(['start-mcp-server', '--context', 'chatgpt']) });

function fail(message) {
  throw new Error(message);
}

function positiveInteger(value, name, fallback) {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) fail(`${name} must be a positive integer`);
  return parsed;
}

function parseStatusAddress(value) {
  const match = /^(127\.0\.0\.1):(\d{1,5})$/.exec(value);
  if (!match) fail('LAZY_SERENA_STATUS_ADDR must be 127.0.0.1 and a port');
  const port = Number(match[2]);
  if (port > 65535) fail('LAZY_SERENA_STATUS_ADDR port is out of range');
  return { host: match[1], port };
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!['--manifest', '--command', '--command-args', '--status'].includes(key)) fail(`Unknown option: ${key}`);
    const value = argv[index + 1];
    if (value === undefined) fail(`Missing value for ${key}`);
    options[key] = value;
    index += 1;
  }
  return options;
}

function commandArgs(value) {
  if (value === undefined) return [...PRODUCTION_SERENA_COMMAND.args];
  let parsed;
  try { parsed = JSON.parse(value); } catch { fail('--command-args must be a JSON array of strings'); }
  if (!Array.isArray(parsed) || parsed.some(argument => typeof argument !== 'string')) fail('--command-args must be a JSON array of strings');
  return parsed;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const manifestPath = options['--manifest'] ?? process.env.LAZY_SERENA_MANIFEST ?? resolve('lazy-proxy/serena-tools.json');
  const idleTimeoutMs = positiveInteger(process.env.LAZY_SERENA_IDLE_MS, 'LAZY_SERENA_IDLE_MS', PRODUCTION_DEFAULTS.idleTimeoutMs);
  const startupTimeoutMs = positiveInteger(process.env.LAZY_SERENA_STARTUP_MS, 'LAZY_SERENA_STARTUP_MS', PRODUCTION_DEFAULTS.startupTimeoutMs);
  const maxQueuedCalls = positiveInteger(process.env.LAZY_SERENA_MAX_QUEUE, 'LAZY_SERENA_MAX_QUEUE', PRODUCTION_DEFAULTS.maxQueuedCalls);
  const statusAddress = parseStatusAddress(options['--status'] ?? process.env.LAZY_SERENA_STATUS_ADDR ?? PRODUCTION_DEFAULTS.statusAddress);
  const manifest = await loadManifest(manifestPath);
  // This injection is unavailable outside the Node test environment.
  const testTaskkillImpl = process.env.NODE_ENV === 'test' && process.env.LAZY_SERENA_TEST_TASKKILL_FAIL === '1'
    ? async () => { throw new Error('Injected taskkill failure'); }
    : undefined;
  const manager = new SerenaProcessManager({
    command: options['--command'] ?? PRODUCTION_SERENA_COMMAND.command,
    args: commandArgs(options['--command-args']),
    manifest,
    startupTimeoutMs,
    idleTimeoutMs,
    shutdownGraceMs: 5_000,
    maxQueuedCalls,
    ...(testTaskkillImpl ? { taskkillImpl: testTaskkillImpl } : {}),
  });
  let requestStop = () => {};
  const proxy = createProxyServer({
    input: process.stdin,
    output: process.stdout,
    manifest,
    manager,
    maxQueuedCalls,
    onFatal: error => requestStop(error),
  });
  const status = await startStatusServer({
    ...statusAddress,
    snapshotProvider: () => {
      const snapshot = manager.snapshot();
      return {
        proxy: 'ready', serena: snapshot.state, pid: snapshot.pid, inFlight: snapshot.inFlight,
        queued: proxy.queued, lastActivityAt: snapshot.lastActivityAt, idleDeadline: snapshot.idleDeadline,
        manifestVersion: manifest.serenaVersion, manifestCompatible: snapshot.manifestCompatible, lastError: snapshot.lastError,
      };
    },
  });
  process.stderr.write(`lazy-serena-proxy status ${status.url}\n`);
  proxy.run();
  let stopPromise = null;
  const stop = () => {
    if (stopPromise) return stopPromise;
    stopPromise = (async () => {
      await proxy.close();
      await status.close();
    })();
    return stopPromise;
  };
  const reportStopFailure = error => {
    process.exitCode = 1;
    process.stderr.write(`lazy-serena-proxy: shutdown failed (${error instanceof Error ? error.message : String(error)})\n`);
  };
  requestStop = () => {
    void stop().then(
      () => { process.exitCode = 1; },
      reportStopFailure,
    );
  };
  const stopAndExit = () => {
    void stop().then(
      () => process.exit(0),
      reportStopFailure,
    );
  };
  process.once('SIGTERM', stopAndExit);
  process.once('SIGINT', stopAndExit);
  process.stdin.once('end', stopAndExit);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    process.stderr.write(`lazy-serena-proxy: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
