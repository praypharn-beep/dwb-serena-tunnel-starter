import { resolve } from 'node:path';
import { loadManifest } from './manifest.mjs';
import { SerenaProcessManager } from './serena-process.mjs';
import { createProxyServer } from './server.mjs';
import { startStatusServer } from './status-server.mjs';

const DEFAULT_IDLE_MS = 15 * 60 * 1000;
const DEFAULT_STARTUP_MS = 30 * 1000;
const DEFAULT_STATUS_ADDR = '127.0.0.1:18012';
const DEFAULT_MAX_QUEUE = 32;

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
  const match = /^(127\.0\.0\.1|::1):(\d{1,5})$/.exec(value);
  if (!match) fail('LAZY_SERENA_STATUS_ADDR must be a loopback host and port');
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
  if (value === undefined) return ['start-mcp-server', '--context', 'chatgpt'];
  let parsed;
  try { parsed = JSON.parse(value); } catch { fail('--command-args must be a JSON array of strings'); }
  if (!Array.isArray(parsed) || parsed.some(argument => typeof argument !== 'string')) fail('--command-args must be a JSON array of strings');
  return parsed;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const manifestPath = options['--manifest'] ?? process.env.LAZY_SERENA_MANIFEST ?? resolve('lazy-proxy/serena-tools.json');
  const idleTimeoutMs = positiveInteger(process.env.LAZY_SERENA_IDLE_MS, 'LAZY_SERENA_IDLE_MS', DEFAULT_IDLE_MS);
  const startupTimeoutMs = positiveInteger(process.env.LAZY_SERENA_STARTUP_MS, 'LAZY_SERENA_STARTUP_MS', DEFAULT_STARTUP_MS);
  const maxQueuedCalls = positiveInteger(process.env.LAZY_SERENA_MAX_QUEUE, 'LAZY_SERENA_MAX_QUEUE', DEFAULT_MAX_QUEUE);
  const statusAddress = parseStatusAddress(options['--status'] ?? process.env.LAZY_SERENA_STATUS_ADDR ?? DEFAULT_STATUS_ADDR);
  const manifest = await loadManifest(manifestPath);
  const manager = new SerenaProcessManager({
    command: options['--command'] ?? 'serena',
    args: commandArgs(options['--command-args']),
    manifest,
    startupTimeoutMs,
    idleTimeoutMs,
    shutdownGraceMs: 5_000,
    maxQueuedCalls,
  });
  const proxy = createProxyServer({ input: process.stdin, output: process.stdout, manifest, manager, maxQueuedCalls });
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
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await proxy.close();
    await status.close();
  };
  const stopAndExit = () => { void stop().finally(() => process.exit(0)); };
  process.once('SIGTERM', stopAndExit);
  process.once('SIGINT', stopAndExit);
  process.stdin.once('end', stopAndExit);
}

main().catch(error => {
  process.stderr.write(`lazy-serena-proxy: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
