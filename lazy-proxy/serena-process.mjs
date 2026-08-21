import { EventEmitter } from 'node:events';
import { execFile } from 'node:child_process';
import { spawn as spawnChild } from 'node:child_process';
import { createJsonLineReader, writeJsonLine } from './protocol.mjs';
import { compareToolLists } from './manifest.mjs';

const STDERR_LIMIT_BYTES = 16 * 1024;
const DEFAULT_MAX_QUEUED_CALLS = 32;

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function makeError(message, data) {
  const error = new Error(message);
  if (data !== undefined) error.data = data;
  return error;
}

function sanitizeStderr(value) {
  return String(value)
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/(api[_-]?key\s*[=:]\s*)\S+/gi, '$1[redacted]')
    .replace(/(authorization:\s*bearer\s+)\S+/gi, '$1[redacted]')
    .trim();
}

function defaultClock() {
  return {
    now: () => Date.now(),
    setTimeout: (callback, delay) => setTimeout(callback, delay),
    clearTimeout: timer => clearTimeout(timer),
  };
}
function defaultTaskkill(pid) {
  return new Promise((resolve, reject) => {
    execFile('taskkill.exe', ['/PID', String(pid), '/T', '/F'], error => {
      if (error) reject(error);
      else resolve();
    });
  });
}

export class SerenaProcessManager extends EventEmitter {
  constructor({ command, args, manifest, startupTimeoutMs, idleTimeoutMs, shutdownGraceMs, spawnImpl = spawnChild, clock = defaultClock(), taskkillImpl = defaultTaskkill, maxQueuedCalls = DEFAULT_MAX_QUEUED_CALLS }) {
    super();
    this.command = command;
    this.args = args;
    this.manifest = manifest;
    this.startupTimeoutMs = startupTimeoutMs;
    this.idleTimeoutMs = idleTimeoutMs;
    this.shutdownGraceMs = shutdownGraceMs;
    this.spawnImpl = spawnImpl;
    this.clock = clock;

    this.taskkillImpl = taskkillImpl;
    this.maxQueuedCalls = Number.isSafeInteger(maxQueuedCalls) && maxQueuedCalls > 0 ? maxQueuedCalls : DEFAULT_MAX_QUEUED_CALLS;
    this.state = 'stopped';
    this.child = null;
    this.reader = null;
    this.pending = new Map();
    this.startPromise = null;
    this.shutdownPromise = null;
    this.callTail = Promise.resolve();
    this.inFlight = 0;
    this.queuedCalls = 0;
    this.lastActivityAt = null;
    this.idleDeadline = null;
    this.idleTimer = null;
    this.lastError = null;
    this.manifestCompatible = null;
    this.stderrTail = '';
    this.stderrBuffer = '';
  }

  snapshot() {
    return {
      state: this.state,
      pid: this.child?.pid ?? null,
      inFlight: this.inFlight,
      lastActivityAt: this.lastActivityAt,
      idleDeadline: this.idleDeadline,
      lastError: this.lastError,
      manifestCompatible: this.manifestCompatible,
    };
  }

  async start() {
    if (this.state === 'ready' || this.state === 'busy') {
      return { pid: this.child.pid, tools: this.manifest.tools };
    }
    if (this.state === 'failed') throw makeError(this.lastError ?? 'Serena is in a failed state');
    if (this.state === 'stopping') throw makeError('Serena is stopping');
    if (this.startPromise) return this.startPromise;

    this.startPromise = this.#start();
    try {
      return await this.startPromise;
    } finally {
      this.startPromise = null;
    }
  }

  async callTool(requestId, params) {
    if (this.state === 'failed' || this.state === 'stopping') throw this.#unavailableError();
    if (this.queuedCalls >= this.maxQueuedCalls) {
      throw makeError('Serena call queue is full', { state: this.state, maxQueuedCalls: this.maxQueuedCalls });
    }
    this.queuedCalls += 1;
    const queued = this.callTail.then(async () => {
      if (this.state === 'failed' || this.state === 'stopping') throw this.#unavailableError();
      try {
        await this.start();
      } catch (error) {
        if (this.state === 'failed' || this.state === 'stopping') throw this.#unavailableError();
        throw error;
      }
      if (this.state === 'failed' || this.state === 'stopping') throw this.#unavailableError();
      return this.#runCall(requestId, params);
    });
    const returned = queued.finally(() => { this.queuedCalls -= 1; });
    this.callTail = returned.catch(() => undefined);
    return returned;
  }

  #unavailableError() {
    return makeError('Serena is unavailable', { state: this.state, reason: this.lastError });
  }

  async shutdown(reason = 'shutdown requested') {
    if (this.shutdownPromise) return this.shutdownPromise;
    this.shutdownPromise = this.#shutdown(reason);
    try {
      await this.shutdownPromise;
    } finally {
      this.shutdownPromise = null;
    }
  }

  async #start() {
    this.#clearIdleTimer();
    this.lastError = null;
    this.manifestCompatible = null;
    this.#setState('starting');
    let child;
    try {
      child = this.spawnImpl(this.command, this.args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
      this.#attachChild(child);
      await this.#withStartupTimeout(async () => {
        await this.#request('lazy-proxy-initialize', 'initialize', {
          protocolVersion: this.manifest.protocolVersion,
          capabilities: {},
          clientInfo: { name: 'lazy-serena-proxy', version: '1.0.0' },
        });
        await writeJsonLine(child.stdin, { jsonrpc: '2.0', method: 'notifications/initialized', params: {} });
        const listed = await this.#request('lazy-proxy-tools-list', 'tools/list', {});
        const comparison = compareToolLists(this.manifest.tools, listed?.tools ?? []);
        this.manifestCompatible = comparison.compatible;
        if (!comparison.compatible) {
          throw makeError(`Serena tool manifest mismatch: missing ${comparison.missing.join(', ') || 'none'}; added ${comparison.added.join(', ') || 'none'}; changed ${comparison.changed.join(', ') || 'none'}`);
        }
      });
      this.lastActivityAt = this.clock.now();
      this.#setState('ready');
      this.#scheduleIdleShutdown();
      return { pid: child.pid, tools: this.manifest.tools };
    } catch (error) {
      this.lastError = errorMessage(error);
      this.#setState('failed');
      await this.#terminateChild();
      throw error;
    }
  }

  async #runCall(requestId, params) {
    if (!params || typeof params !== 'object' || Array.isArray(params)) {
      throw makeError('tools/call params must be an object');
    }
    this.#clearIdleTimer();
    this.inFlight += 1;
    this.lastActivityAt = this.clock.now();
    this.#setState('busy');
    try {
      const result = await this.#request(requestId, 'tools/call', params);
      return result;
    } finally {
      this.inFlight -= 1;
      this.lastActivityAt = this.clock.now();
      if (this.state === 'busy') this.#setState('ready');
      if (this.inFlight === 0 && this.state === 'ready') this.#scheduleIdleShutdown();
      this.#emitState();
    }
  }

  async #shutdown(reason) {
    this.#clearIdleTimer();
    if (!this.child && !this.startPromise && this.queuedCalls === 0) {
      this.#setStopped();
      return;
    }
    if (this.state !== 'failed') this.#setState('stopping');
    try {
      await this.callTail;
    } catch {
      // The queued call has already captured the relevant failure.
    }
    const terminated = await this.#terminateChild();
    if (!terminated) throw makeError(this.lastError ?? 'Serena termination failed');
    this.lastError = null;
    this.#setStopped();
  }

  #attachChild(child) {
    this.child = child;
    this.reader = createJsonLineReader(child.stdout, {
      onMessage: message => this.#onMessage(message),
      onError: error => this.#onProtocolError(error),
    });
    this.onStderr = chunk => this.#appendStderr(chunk);
    this.onChildError = error => this.#onChildExit(error);
    this.onChildExit = (code, signal) => this.#onChildExit(makeError(`Serena exited (${signal ?? code ?? 'unknown'})`));
    child.stderr.on('data', this.onStderr);
    child.once('error', this.onChildError);
    child.once('exit', this.onChildExit);
  }

  #detachChild(child) {
    if (!child) return;
    this.reader?.close();
    this.reader = null;
    child.stderr?.off('data', this.onStderr);
    child.off('error', this.onChildError);
    child.off('exit', this.onChildExit);
    if (this.child === child) this.child = null;
  }

  #onMessage(message) {
    if (!Object.hasOwn(message, 'id')) return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    if (message.error) {
      pending.reject(makeError(message.error.message ?? 'Serena returned an error', message.error.data));
    } else {
      pending.resolve(message.result);
    }
  }

  #onChildExit(error) {
    const child = this.child;
    if (!child) return;
    this.#detachChild(child);
    this.#rejectPending(error);
    if (this.state !== 'stopped' && this.state !== 'stopping' && this.state !== 'failed') {
      this.lastError = errorMessage(error);
      this.#setState('failed');
    }
  }
  #onProtocolError(error) {
    const failure = makeError(`Invalid Serena output: ${errorMessage(error)}`);
    this.lastError = failure.message;
    this.#clearIdleTimer();
    this.#rejectPending(failure);
    if (this.state !== 'stopped' && this.state !== 'stopping' && this.state !== 'failed') {
      this.#setState('failed');
    } else {
      this.#emitState();
    }

  }
  #request(id, method, params) {
    const child = this.child;
    if (!child?.stdin || child.stdin.destroyed) return Promise.reject(makeError('Serena process is not available'));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      writeJsonLine(child.stdin, { jsonrpc: '2.0', id, method, params }).catch(error => {
        if (this.pending.delete(id)) reject(error);
      });
    });
  }

  async #withStartupTimeout(operation) {
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = this.clock.setTimeout(() => reject(makeError(`Serena startup timed out after ${this.startupTimeoutMs}ms`)), this.startupTimeoutMs);
    });
    try {
      return await Promise.race([operation(), timeout]);
    } finally {
      this.clock.clearTimeout(timer);
    }
  }

  #scheduleIdleShutdown() {
    this.#clearIdleTimer();
    this.idleDeadline = this.clock.now() + this.idleTimeoutMs;
    this.idleTimer = this.clock.setTimeout(() => {
      this.idleTimer = null;
      this.idleDeadline = null;
      if (this.inFlight === 0 && (this.state === 'ready' || this.state === 'busy')) {
        void this.shutdown('idle timeout');
      }
    }, this.idleTimeoutMs);
    this.#emitState();
  }

  #clearIdleTimer() {
    if (this.idleTimer) this.clock.clearTimeout(this.idleTimer);
    this.idleTimer = null;
    this.idleDeadline = null;
  }

  async #terminateChild() {
    const child = this.child;
    if (!child) return true;
    this.#rejectPending(makeError('Serena process is stopping'));
    try { child.stdin?.end(); } catch { /* stdin may already be closed */ }
    if (await this.#waitForExit(child, this.shutdownGraceMs) && this.#confirmChildExit(child)) return true;
    if (this.#confirmChildExit(child)) return true;
    try {
      await this.taskkillImpl(child.pid);
    } catch (error) {
      return this.#terminationFailure(child, error);
    }
    if (this.#confirmChildExit(child)) return true;
    if (await this.#waitForExit(child, this.shutdownGraceMs) && this.#confirmChildExit(child)) return true;
    return this.#terminationFailure(child);
  }
  #confirmChildExit(child) {
    if (this.child !== child) return true;
    if (child.exitCode === null && child.signalCode === null) return false;
    this.#detachChild(child);
    return true;
  }

  #terminationFailure(child, error) {
    if (this.child !== child) return true;
    this.lastError = `Serena termination failed${error ? `: ${errorMessage(error)}` : ''}`;
    if (this.state !== 'failed') this.#setState('failed');
    else this.#emitState();
    return false;
  }

  #waitForExit(child, timeoutMs) {
    if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
    return new Promise(resolve => {
      const timer = this.clock.setTimeout(() => finish(false), timeoutMs);
      const onExit = () => finish(true);
      const finish = result => {
        this.clock.clearTimeout(timer);
        child.off('exit', onExit);
        resolve(result);
      };
      child.once('exit', onExit);
    });
  }

  #appendStderr(chunk) {
    this.stderrBuffer += String(chunk);
    let newlineIndex;
    while ((newlineIndex = this.stderrBuffer.indexOf('\n')) !== -1) {
      let line = this.stderrBuffer.slice(0, newlineIndex);
      this.stderrBuffer = this.stderrBuffer.slice(newlineIndex + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      this.#appendStderrLine(line);
    }
    if (Buffer.byteLength(this.stderrBuffer, 'utf8') > STDERR_LIMIT_BYTES) {
      this.stderrBuffer = '[stderr line truncated]';
    }
  }

  #appendStderrLine(line) {
    this.stderrTail += `${sanitizeStderr(line)}\n`;
    while (Buffer.byteLength(this.stderrTail, 'utf8') > STDERR_LIMIT_BYTES) {
      this.stderrTail = this.stderrTail.slice(1);
    }

  }
  #rejectPending(error) {
    for (const { reject } of this.pending.values()) reject(error);
    this.pending.clear();
  }

  #setStopped() {
    this.#clearIdleTimer();
    this.#setState('stopped');
  }

  #setState(state) {
    this.state = state;
    this.#emitState();
  }

  #emitState() {
    this.emit('state', this.snapshot());
  }
}
