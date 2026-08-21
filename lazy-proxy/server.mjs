import { createJsonLineReader, jsonRpcError, jsonRpcResult, writeJsonLine } from './protocol.mjs';

const DEFAULT_MAX_QUEUED_CALLS = 32;

function validQueueLimit(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : DEFAULT_MAX_QUEUED_CALLS;
}

function errorMessage(error, fallback) {
  return error instanceof Error && error.message ? error.message : fallback;
}

function asSafeErrorData(error) {
  if (!error || typeof error !== 'object' || !error.data || typeof error.data !== 'object' || Array.isArray(error.data)) return undefined;
  const data = {};
  for (const key of ['state', 'reason', 'maxQueuedCalls']) {
    if (Object.hasOwn(error.data, key)) data[key] = error.data[key];
  }
  return Object.keys(data).length > 0 ? data : undefined;
}

function validId(id) {
  return id === null || typeof id === 'string' || typeof id === 'number';
}

function validRequest(message) {
  return message !== null
    && typeof message === 'object'
    && !Array.isArray(message)
    && message.jsonrpc === '2.0'
    && typeof message.method === 'string'
    && message.method.length > 0
    && (!Object.hasOwn(message, 'id') || validId(message.id));
}

export function createProxyServer({ input, output, manifest, manager, maxQueuedCalls, onFatal = () => {} }) {
  const toolNames = new Set(manifest.tools.map(tool => tool.name));
  const queueLimit = validQueueLimit(maxQueuedCalls);
  let queued = 0;
  let activeDispatches = 0;
  let overflowResponsePending = false;
  let reader = null;
  let closed = false;
  let closePromise = null;
  let outputTail = Promise.resolve();
  let fatalNotified = false;

  const notifyFatal = error => {
    if (fatalNotified) return;
    fatalNotified = true;
    try { onFatal(error); } catch { /* fatal notification cannot restart the proxy */ }
  };

  const close = () => {
    if (closePromise) return closePromise;
    closed = true;
    reader?.close();
    output.off('error', onOutputError);
    closePromise = Promise.resolve().then(() => manager.shutdown('proxy shutdown'));
    return closePromise;
  };

  const triggerFatal = error => {
    const completion = close();
    completion.then(
      () => notifyFatal(new Error('MCP transport closed')),
      shutdownError => notifyFatal(new Error(`Serena shutdown failed: ${errorMessage(shutdownError, 'unknown error')}`)),
    );
    completion.catch(() => undefined);
  };

  const onOutputError = error => triggerFatal(error);

  const respond = response => {
    if (closed) return Promise.reject(new Error('MCP transport is closed'));
    const written = outputTail.then(() => writeJsonLine(output, response));
    outputTail = written.catch(error => {
      triggerFatal(error);
    });
    return written;
  };

  const handleCall = async message => {
    const params = message.params;
    if (!params || typeof params !== 'object' || Array.isArray(params) || typeof params.name !== 'string') {
      await respond(jsonRpcError(message.id, -32602, 'tools/call requires params.name'));
      return;
    }
    if (!toolNames.has(params.name)) {
      await respond(jsonRpcError(message.id, -32601, `Unknown Serena tool: ${params.name}`));
      return;
    }
    if (queued >= queueLimit) {
      await respond(jsonRpcError(message.id, -32001, 'Serena call queue is full', { maxQueuedCalls: queueLimit }));
      return;
    }
    queued += 1;
    try {
      await manager.start();
      const result = await manager.callTool(message.id, params);
      await respond(jsonRpcResult(message.id, result));
    } catch (error) {
      await respond(jsonRpcError(message.id, -32000, errorMessage(error, 'Serena is unavailable'), asSafeErrorData(error)));
    } finally {
      queued -= 1;
    }
  };

  const handleMessage = async message => {
    if (!validRequest(message)) {
      await respond(jsonRpcError(null, -32600, 'Invalid Request'));
      return;
    }
    const notification = !Object.hasOwn(message, 'id');
    switch (message.method) {
      case 'initialize':
        if (!notification) {
          await respond(jsonRpcResult(message.id, {
            protocolVersion: manifest.protocolVersion,
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: 'lazy-serena-proxy', version: '1.0.0' },
          }));
        }
        return;
      case 'notifications/initialized':
        return;
      case 'ping':
        if (!notification) await respond(jsonRpcResult(message.id, {}));
        return;
      case 'tools/list':
        if (!notification) await respond(jsonRpcResult(message.id, { tools: manifest.tools }));
        return;
      case 'tools/call':
        if (!notification) await handleCall(message);
        return;
      default:
        if (!notification) await respond(jsonRpcError(message.id, -32601, `Unsupported method: ${message.method}`));
    }
  };

  const dispatch = (work, requestId = undefined) => {
    if (closed) return;
    if (activeDispatches >= queueLimit) {
      if (requestId !== undefined && !overflowResponsePending) {
        overflowResponsePending = true;
        Promise.resolve(respond(jsonRpcError(requestId, -32001, 'Proxy dispatch queue is full', { maxQueuedCalls: queueLimit })))
          .catch(triggerFatal)
          .finally(() => { overflowResponsePending = false; });
      }
      return;
    }
    activeDispatches += 1;
    Promise.resolve()
      .then(work)
      .catch(triggerFatal)
      .finally(() => { activeDispatches -= 1; });
  };

  return {
    get queued() { return queued; },
    run() {
      if (reader) return;
      output.on('error', onOutputError);
      reader = createJsonLineReader(input, {
        onMessage: message => dispatch(() => handleMessage(message), Object.hasOwn(message, 'id') ? message.id : undefined),
        onError: error => dispatch(
          () => respond(jsonRpcError(null, error instanceof SyntaxError ? -32700 : -32600, error instanceof SyntaxError ? 'Parse error' : 'Invalid Request')),
          null,
        ),
      });
    },
    close,
  };
}