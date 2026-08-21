import { createJsonLineReader, jsonRpcError, jsonRpcResult, writeJsonLine } from './protocol.mjs';

const DEFAULT_MAX_QUEUED_CALLS = 32;

function validQueueLimit(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : DEFAULT_MAX_QUEUED_CALLS;
}

function asSafeErrorData(error) {
  if (!error || typeof error !== 'object' || !error.data || typeof error.data !== 'object' || Array.isArray(error.data)) return undefined;
  const data = {};
  for (const key of ['state', 'reason', 'maxQueuedCalls']) {
    if (Object.hasOwn(error.data, key)) data[key] = error.data[key];
  }
  return Object.keys(data).length > 0 ? data : undefined;
}

function errorMessage(error, fallback) {
  return error instanceof Error && error.message ? error.message : fallback;
}

export function createProxyServer({ input, output, manifest, manager, maxQueuedCalls }) {
  const toolNames = new Set(manifest.tools.map(tool => tool.name));
  const queueLimit = validQueueLimit(maxQueuedCalls);
  let queued = 0;
  let reader = null;
  let closed = false;
  let closePromise = null;

  const respond = async response => {
    if (!closed) await writeJsonLine(output, response);
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
    const isNotification = !Object.hasOwn(message, 'id');
    switch (message.method) {
      case 'initialize':
        if (!isNotification) {
          await respond(jsonRpcResult(message.id, {
            protocolVersion: manifest.protocolVersion,
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: 'lazy-serena-proxy', version: '1.0.0' },
          }));
        }
        return;
      case 'notifications/initialized':
      case 'ping':
        if (!isNotification && message.method === 'ping') await respond(jsonRpcResult(message.id, {}));
        return;
      case 'tools/list':
        if (!isNotification) await respond(jsonRpcResult(message.id, { tools: manifest.tools }));
        return;
      case 'tools/call':
        if (!isNotification) await handleCall(message);
        return;
      default:
        if (!isNotification) await respond(jsonRpcError(message.id, -32601, `Unsupported method: ${String(message.method)}`));
    }
  };

  return {
    get queued() { return queued; },
    run() {
      if (reader) return;
      reader = createJsonLineReader(input, {
        onMessage: message => { void handleMessage(message); },
        onError: error => { process.stderr.write(`lazy-serena-proxy: invalid upstream JSON-RPC (${errorMessage(error, 'unknown error')})\n`); },
      });
    },
    close() {
      if (closePromise) return closePromise;
      closed = true;
      reader?.close();
      closePromise = Promise.resolve(manager.shutdown('proxy shutdown')).catch(() => undefined);
      return closePromise;
    },
  };
}
