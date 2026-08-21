import { createInterface } from 'node:readline';

const behavior = process.env.FAKE_SERENA_BEHAVIOR ?? 'normal';
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

const write = message => process.stdout.write(`${JSON.stringify(message)}\n`);
const respond = (id, result) => write({ jsonrpc: '2.0', id, result });
let initialized = false;

for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
  if (!line) continue;
  const message = JSON.parse(line);

  if (message.method === 'initialize') {
    if (behavior === 'slow-start') {
      await new Promise(resolve => setTimeout(resolve, Number(process.env.FAKE_SERENA_START_DELAY_MS ?? 1_000)));
    }
    if (behavior === 'stderr-split-secret') {
      process.stderr.write('api_key=super');
      process.stderr.write('secret\n');
    }
    respond(message.id, { protocolVersion: message.params.protocolVersion, capabilities: {}, serverInfo: { name: 'fake-serena', version: '1.0.0' } });
    continue;
  }
  if (message.method === 'notifications/initialized') {
    initialized = true;
    continue;
  }

  if (message.method === 'tools/list') {
    if (!initialized) {
      write({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: 'initialized notification required' } });
      continue;
    }
    const tools = behavior === 'mismatched-tools'
      ? [{ ...echoTool, description: 'A changed description' }]
      : [echoTool];
    respond(message.id, { tools });
    continue;
  }

  if (message.method === 'tools/call') {
    if (behavior === 'crash-on-call') process.exit(17);
    if (behavior === 'malformed-output') {
      process.stdout.write('{malformed json}\n');
      continue;
    }

    if (process.env.FAKE_SERENA_HOLD_CALL === 'true') {
      await new Promise(resolve => setTimeout(resolve, Number(process.env.FAKE_SERENA_CALL_DELAY_MS ?? 100)));
    }
    respond(message.id, { content: [{ type: 'text', text: String(message.params.arguments?.text ?? '') }] });
  }
}
