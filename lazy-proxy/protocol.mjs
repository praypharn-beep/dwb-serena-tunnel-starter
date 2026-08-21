const MAX_LINE_BYTES = 1024 * 1024;

function asError(error) {
  return error instanceof Error ? error : new Error(String(error));
}

/**
 * Reads newline-delimited JSON-RPC messages from a UTF-8 readable stream.
 * Invalid lines are reported and do not prevent later messages being read.
 */
export function createJsonLineReader(readable, { onMessage, onError }) {
  let buffer = '';
  let discardingOversizedLine = false;
  let closed = false;

  const reportError = error => {
    if (!closed) onError(asError(error));
  };

  const handleLine = line => {
    if (line.endsWith('\r')) line = line.slice(0, -1);
    if (line.length === 0) return;
    if (Buffer.byteLength(line, 'utf8') > MAX_LINE_BYTES) {
      reportError(new Error(`JSON-RPC line exceeds ${MAX_LINE_BYTES} bytes`));
      return;
    }
    try {
      const message = JSON.parse(line);
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        throw new TypeError('JSON-RPC message must be an object');
      }
      onMessage(message);
    } catch (error) {
      reportError(error);
    }
  };

  const onData = chunk => {
    if (closed) return;
    buffer += chunk;

    if (discardingOversizedLine) {
      const newlineIndex = buffer.indexOf('\n');
      if (newlineIndex === -1) {
        buffer = '';
        return;
      }
      buffer = buffer.slice(newlineIndex + 1);
      discardingOversizedLine = false;
    }

    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      handleLine(buffer.slice(0, newlineIndex));
      buffer = buffer.slice(newlineIndex + 1);
    }
    if (Buffer.byteLength(buffer, 'utf8') > MAX_LINE_BYTES) {
      buffer = '';
      discardingOversizedLine = true;
      reportError(new Error(`JSON-RPC line exceeds ${MAX_LINE_BYTES} bytes`));
    }
  };
  const onStreamError = error => reportError(error);

  readable.setEncoding('utf8');
  readable.on('data', onData);
  readable.on('error', onStreamError);

  return {
    close() {
      if (closed) return;
      closed = true;
      buffer = '';
      readable.off('data', onData);
      readable.off('error', onStreamError);
    },
  };
}

export function writeJsonLine(writable, message) {
  if (message === null || Array.isArray(message) || typeof message !== 'object') {
    return Promise.reject(new TypeError('JSON-RPC message must be an object'));
  }

  return new Promise((resolve, reject) => {
    let serialized;
    try {
      serialized = `${JSON.stringify(message)}\n`;
    } catch (error) {
      reject(error);
      return;
    }

    const onError = error => {
      cleanup();
      reject(error);
    };
    const onDrain = () => {
      cleanup();
      resolve();
    };
    const cleanup = () => {
      writable.off('error', onError);
      writable.off('drain', onDrain);
    };

    writable.once('error', onError);
    let wrote;
    try {
      wrote = writable.write(serialized);
    } catch (error) {
      cleanup();
      reject(error);
      return;
    }
    if (wrote) {
      cleanup();
      resolve();
    } else {
      writable.once('drain', onDrain);
    }
  });
}

export function jsonRpcResult(id, result) {
  return { jsonrpc: '2.0', id, result };
}

export function jsonRpcError(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return { jsonrpc: '2.0', id, error };
}
