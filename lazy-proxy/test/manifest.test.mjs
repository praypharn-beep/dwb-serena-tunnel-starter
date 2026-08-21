import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { compareToolLists, loadManifest } from '../manifest.mjs';

const fixturePath = new URL('./fixtures/valid-manifest.json', import.meta.url);

test('loadManifest returns a valid Serena manifest', async () => {
  const manifest = await loadManifest(fixturePath);
  assert.equal(manifest.protocolVersion, '2025-06-18');
  assert.deepEqual(manifest.tools.map(tool => tool.name), ['read_file']);
});

test('loadManifest rejects missing required fields', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lazy-proxy-'));
  const path = join(directory, 'bad-manifest.json');
  await writeFile(path, JSON.stringify({ manifestVersion: 1, serenaVersion: '1.7.0', tools: [] }));

  await assert.rejects(loadManifest(path), /protocolVersion/);
});

test('compareToolLists reports description-only changes', () => {
  const base = [{ name: 'read_file', description: 'Read a file', inputSchema: { type: 'object' } }];
  const live = [{ name: 'read_file', description: 'Read text from a file', inputSchema: { type: 'object' } }];

  assert.deepEqual(compareToolLists(base, live), {
    compatible: false,
    missing: [],
    added: [],
    changed: ['read_file'],
  });
});

test('compareToolLists ignores nested input schema key insertion order', () => {
  const base = [{
    name: 'read_file',
    description: 'Read a file',
    inputSchema: { type: 'object', properties: { path: { type: 'string' }, options: { type: 'object', additionalProperties: false } } },
  }];
  const live = [{
    name: 'read_file',
    description: 'Read a file',
    inputSchema: { properties: { options: { additionalProperties: false, type: 'object' }, path: { type: 'string' } }, type: 'object' },
  }];

  assert.deepEqual(compareToolLists(base, live), {
    compatible: true,
    missing: [],
    added: [],
    changed: [],
  });
});
