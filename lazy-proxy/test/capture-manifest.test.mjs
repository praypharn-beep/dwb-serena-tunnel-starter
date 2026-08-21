import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureManifest } from '../scripts/capture-manifest.mjs';

const fakeSerenaPath = fileURLToPath(new URL('./fixtures/fake-serena.mjs', import.meta.url));

async function withDirectory(run) {
  const directory = await mkdtemp(join(tmpdir(), 'lazy-serena-capture-'));
  try { return await run(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

function captureOptions({ behavior = 'normal' } = {}) {
  return {
    command: process.execPath,
    args: [fakeSerenaPath],
    versionCommand: process.execPath,
    versionArgs: ['-e', "process.stdout.write('fake-serena 1.2.3\\n')"],
    spawnImpl(command, args, options) {
      return spawn(command, args, { ...options, env: { ...process.env, ...options.env, FAKE_SERENA_BEHAVIOR: behavior } });
    },
  };
}

test('captures a validated, name-sorted manifest from the fake Serena server', async () => {
  await withDirectory(async directory => {
    const output = join(directory, 'serena-tools.json');
    const manifest = await captureManifest({ output, ...captureOptions() });

    assert.equal(manifest.manifestVersion, 1);
    assert.equal(manifest.serenaVersion, '1.2.3');
    assert.equal(manifest.protocolVersion, '2025-06-18');
    assert.deepEqual(manifest.tools.map(tool => tool.name), ['echo']);
    assert.deepEqual(JSON.parse(await readFile(output, 'utf8')), manifest);
    assert.equal(existsSync(`${output}.tmp`), false);
  });
});

test('sorts tools by name regardless of the order Serena reports them in', async () => {
  await withDirectory(async directory => {
    const output = join(directory, 'serena-tools.json');
    const manifest = await captureManifest({ output, ...captureOptions({ behavior: 'multi-tool-unsorted' }) });
    assert.deepEqual(manifest.tools.map(tool => tool.name), ['alpha', 'echo', 'zulu']);
  });
});

test('preserves an existing destination and removes its temporary file when post-write validation fails', async () => {
  await withDirectory(async directory => {
    const output = join(directory, 'serena-tools.json');
    const original = '{"previous":true}';
    await writeFile(output, original);

    await assert.rejects(
      captureManifest({ output, ...captureOptions({ behavior: 'invalid-tool' }) }),
      /Invalid Serena manifest/,
    );
    assert.equal(await readFile(output, 'utf8'), original);
    assert.equal(existsSync(`${output}.tmp`), false);
  });
});

test('preserves an existing destination and removes its temporary file when the child fails', async () => {
  await withDirectory(async directory => {
    const output = join(directory, 'serena-tools.json');
    const original = '{"previous":true}\\n';
    await writeFile(output, original);

    await assert.rejects(
      captureManifest({ output, ...captureOptions({ behavior: 'exit-before-list' }), startupTimeoutMs: 200 }),
      /Serena exited|process is not available/,
    );
    assert.equal(await readFile(output, 'utf8'), original);
    assert.equal(existsSync(`${output}.tmp`), false);
  });
});

test('capture handshake never requests a project activation', async () => {
  await withDirectory(async directory => {
    const output = join(directory, 'serena-tools.json');
    const tracePath = join(directory, 'requests.txt');
    const options = captureOptions();
    const originalSpawn = options.spawnImpl;
    options.spawnImpl = (command, args, spawnOptions) => originalSpawn(command, args, {
      ...spawnOptions,
      env: { ...spawnOptions.env, FAKE_SERENA_TRACE_PATH: tracePath },
    });

    await captureManifest({ output, ...options });
    const methods = (await readFile(tracePath, 'utf8')).trim().split('\n');
    assert.deepEqual(methods, ['initialize', 'notifications/initialized', 'tools/list']);
    assert.ok(!methods.some(method => /activate.*project|project.*activate/i.test(method)));
  });
});
