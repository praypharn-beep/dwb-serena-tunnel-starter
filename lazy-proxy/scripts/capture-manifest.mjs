import { execFile, spawn } from 'node:child_process';
import { rename, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadManifest } from '../manifest.mjs';
import { createJsonLineReader, writeJsonLine } from '../protocol.mjs';

const CLIENT_PROTOCOL_VERSION = '2025-06-18';
const DEFAULT_STARTUP_TIMEOUT_MS = 30_000;
const TERMINATION_GRACE_MS = 2_000;
const TASKKILL_TIMEOUT_MS = 5_000;

function messageOf(error) {
  return error instanceof Error ? error.message : String(error);
}

function deferred() {
  let resolvePromise;
  let rejectPromise;
  const promise = new Promise((resolve_, reject_) => { resolvePromise = resolve_; rejectPromise = reject_; });
  return { promise, resolve: resolvePromise, reject: rejectPromise };
}

function waitForExit(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise(resolvePromise => {
    const timer = setTimeout(done, timeoutMs);
    const onExit = () => done();
    function done() {
      clearTimeout(timer);
      child.off('exit', onExit);
      resolvePromise();
    }
    child.once('exit', onExit);
  });
}

function runCommand(command, args, execFileImpl, timeoutMs) {
  return new Promise((resolvePromise, rejectPromise) => {
    execFileImpl(command, args, { windowsHide: true, timeout: timeoutMs }, (error, stdout) => {
      if (error) {
        // Never surface raw stderr here: execFile's Error.message embeds the child's stderr verbatim.
        rejectPromise(new Error(`Unable to read Serena version (${error.code ?? error.signal ?? 'unknown failure'})`));
        return;
      }
      resolvePromise(String(stdout ?? ''));
    });
  });
}

function parseVersion(output) {
  const match = /(\d+\.\d+\.\d+(?:[.+-][0-9A-Za-z.-]+)?)/.exec(output);
  if (!match) throw new Error('Unable to parse Serena version from --version output');
  return match[1];
}

async function terminateChild(child, execFileImpl) {
  if (!child) return;
  try { child.stdin?.end(); } catch { /* child stdin may already be closed */ }
  await waitForExit(child, TERMINATION_GRACE_MS);
  if (child.exitCode !== null || child.signalCode !== null) return;

  if (process.platform === 'win32') {
    await new Promise(resolvePromise => {
      execFileImpl('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, timeout: TASKKILL_TIMEOUT_MS }, () => resolvePromise());
    });
    await waitForExit(child, TERMINATION_GRACE_MS);
    return;
  }

  try { child.kill('SIGTERM'); } catch { /* child may already be gone */ }
  await waitForExit(child, TERMINATION_GRACE_MS);
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { child.kill('SIGKILL'); } catch { /* child may already be gone */ }
  await waitForExit(child, TERMINATION_GRACE_MS);
}

async function collectTools({ command, args, spawnImpl, startupTimeoutMs, execFileImpl }) {
  const child = spawnImpl(command, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  // Drain and discard stderr: never expose Serena stderr, and an unread pipe can block the child's writes.
  child.stderr?.on('data', () => {});
  const pending = new Map();
  let reader;
  let childError = null;
  let timeoutTimer;

  const rejectPending = error => {
    for (const entry of pending.values()) entry.reject(error);
    pending.clear();
  };
  const fail = error => {
    const normalized = error instanceof Error ? error : new Error(String(error));
    childError ??= normalized;
    rejectPending(normalized);
  };
  const onExit = (code, signal) => fail(new Error(`Serena exited (${signal ?? code ?? 'unknown'})`));
  const onError = error => fail(error);
  const request = (id, method, params) => {
    if (childError) return Promise.reject(childError);
    const entry = deferred();
    pending.set(id, entry);
    writeJsonLine(child.stdin, { jsonrpc: '2.0', id, method, params }).catch(error => {
      if (pending.delete(id)) entry.reject(error);
    });
    return entry.promise;
  };

  try {
    reader = createJsonLineReader(child.stdout, {
      onMessage(message) {
        if (!Object.hasOwn(message, 'id')) return;
        const entry = pending.get(message.id);
        if (!entry) return;
        pending.delete(message.id);
        if (message.error) entry.reject(new Error(message.error.message ?? 'Serena returned an error'));
        else entry.resolve(message.result);
      },
      onError(error) { fail(new Error(`Invalid Serena output: ${messageOf(error)}`)); },
    });
    child.once('exit', onExit);
    child.once('error', onError);
    const timeout = new Promise((_, rejectPromise) => {
      timeoutTimer = setTimeout(() => rejectPromise(new Error(`Serena startup timed out after ${startupTimeoutMs}ms`)), startupTimeoutMs);
    });
    const operation = (async () => {
      const initialized = await request('capture-initialize', 'initialize', {
        protocolVersion: CLIENT_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: 'lazy-serena-manifest-capture', version: '1.0.0' },
      });
      const protocolVersion = initialized?.protocolVersion;
      if (typeof protocolVersion !== 'string' || protocolVersion.length === 0) throw new Error('Serena initialize response has no protocolVersion');
      await writeJsonLine(child.stdin, { jsonrpc: '2.0', method: 'notifications/initialized', params: {} });
      const listed = await request('capture-tools-list', 'tools/list', {});
      if (!Array.isArray(listed?.tools)) throw new Error('Serena tools/list response has no tools array');
      return { protocolVersion, tools: listed.tools };
    })();
    return await Promise.race([operation, timeout]);
  } finally {
    clearTimeout(timeoutTimer);
    rejectPending(new Error('Serena manifest capture is stopping'));
    reader?.close();
    child.off('exit', onExit);
    child.off('error', onError);
    await terminateChild(child, execFileImpl);
  }
}

export async function captureManifest({
  output,
  command = 'serena',
  args = ['start-mcp-server', '--context', 'chatgpt'],
  versionCommand = command,
  versionArgs = ['--version'],
  spawnImpl = spawn,
  execFileImpl = execFile,
  startupTimeoutMs = DEFAULT_STARTUP_TIMEOUT_MS,
} = {}) {
  if (typeof output !== 'string' || output.length === 0) throw new TypeError('output must be a non-empty path');
  const outputPath = resolve(output);
  const temporaryPath = `${outputPath}.tmp`;
  let temporaryWritten = false;
  try {
    const [versionOutput, live] = await Promise.all([
      runCommand(versionCommand, versionArgs, execFileImpl, startupTimeoutMs),
      collectTools({ command, args, spawnImpl, startupTimeoutMs, execFileImpl }),
    ]);
    const manifest = {
      manifestVersion: 1,
      serenaVersion: parseVersion(versionOutput),
      protocolVersion: live.protocolVersion,
      tools: [...live.tools].sort((left, right) => left.name.localeCompare(right.name)),
    };
    await writeFile(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
    temporaryWritten = true;
    await loadManifest(temporaryPath);
    await rename(temporaryPath, outputPath);
    temporaryWritten = false;
    return manifest;
  } finally {
    if (temporaryWritten) await rm(temporaryPath, { force: true });
  }
}

function parseArguments(argv) {
  if (argv.length !== 2 || argv[0] !== '--output' || argv[1].length === 0) {
    throw new Error('Usage: node lazy-proxy/scripts/capture-manifest.mjs --output <path>');
  }
  return { output: argv[1] };
}

async function main() {
  const { output } = parseArguments(process.argv.slice(2));
  const manifest = await captureManifest({ output });
  process.stdout.write(`Captured ${manifest.tools.length} Serena tools (version ${manifest.serenaVersion}).\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    process.stderr.write(`capture-manifest: ${messageOf(error)}\n`);
    process.exitCode = 1;
  });
}
