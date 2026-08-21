import { createServer } from 'node:http';

const STATUS_KEYS = [
  'proxy', 'serena', 'pid', 'inFlight', 'queued', 'lastActivityAt', 'idleDeadline',
  'manifestVersion', 'manifestCompatible', 'lastError',
];

function isLoopbackHost(host) {
  return host === '127.0.0.1' || host === '::1';
}

function statusBody(snapshotProvider) {
  const snapshot = snapshotProvider() ?? {};
  return Object.fromEntries(STATUS_KEYS.map(key => [key, snapshot[key] ?? null]));
}

function write(response, statusCode, contentType, body) {
  response.writeHead(statusCode, {
    'content-type': contentType,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  });
  response.end(body);
}

const UI = '<!doctype html><meta charset="utf-8"><title>Lazy Serena status</title><pre id="status">Loading…</pre><script>fetch("/status",{cache:"no-store"}).then(r=>r.json()).then(v=>document.getElementById("status").textContent=JSON.stringify(v,null,2)).catch(()=>document.getElementById("status").textContent="Status unavailable")</script>';

export async function startStatusServer({ host, port, snapshotProvider }) {
  if (!isLoopbackHost(host)) throw new RangeError('Status server host must be a loopback address');
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new RangeError('Status server port must be between 0 and 65535');
  if (typeof snapshotProvider !== 'function') throw new TypeError('snapshotProvider must be a function');

  const server = createServer((request, response) => {
    if (request.method === 'GET' && request.url === '/status') {
      write(response, 200, 'application/json; charset=utf-8', JSON.stringify(statusBody(snapshotProvider)));
      return;
    }
    if (request.method === 'GET' && request.url === '/ui') {
      write(response, 200, 'text/html; charset=utf-8', UI);
      return;
    }
    write(response, 404, 'text/plain; charset=utf-8', 'Not found');
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen({ host, port }, () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  const displayHost = host.includes(':') ? `[${host}]` : host;
  return {
    url: `http://${displayHost}:${address.port}`,
    close: () => new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())),
  };
}
