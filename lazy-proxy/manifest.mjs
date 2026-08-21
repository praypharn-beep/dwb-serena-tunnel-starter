import { readFile } from 'node:fs/promises';

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function assertManifest(condition, message) {
  if (!condition) throw new TypeError(`Invalid Serena manifest: ${message}`);
}

function validateTool(tool, index, names) {
  assertManifest(tool !== null && typeof tool === 'object' && !Array.isArray(tool), `tools[${index}] must be an object`);
  assertManifest(isNonEmptyString(tool.name), `tools[${index}].name must be a non-empty string`);
  assertManifest(!names.has(tool.name), `tool names must be unique: ${tool.name}`);
  assertManifest(typeof tool.description === 'string', `tools[${index}].description must be a string`);
  assertManifest(tool.inputSchema !== null && typeof tool.inputSchema === 'object' && !Array.isArray(tool.inputSchema), `tools[${index}].inputSchema must be an object`);
  names.add(tool.name);
}

export async function loadManifest(path) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(path, 'utf8'));
  } catch (error) {
    throw new TypeError(`Unable to load Serena manifest: ${asMessage(error)}`);
  }

  assertManifest(parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed), 'root must be an object');
  assertManifest(parsed.manifestVersion === 1, 'manifestVersion must equal 1');
  assertManifest(isNonEmptyString(parsed.serenaVersion), 'serenaVersion must be a non-empty string');
  assertManifest(isNonEmptyString(parsed.protocolVersion), 'protocolVersion must be a non-empty string');
  assertManifest(Array.isArray(parsed.tools), 'tools must be an array');

  const names = new Set();
  parsed.tools.forEach((tool, index) => validateTool(tool, index, names));
  return parsed;
}

function asMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function canonicalTool(tool) {
  return JSON.stringify({
    name: tool.name,
    description: tool.description,
    inputSchema: tool.inputSchema,
  });
}

export function compareToolLists(manifestTools, liveTools) {
  const manifestByName = new Map(manifestTools.map(tool => [tool.name, canonicalTool(tool)]));
  const liveByName = new Map(liveTools.map(tool => [tool.name, canonicalTool(tool)]));
  const missing = [...manifestByName.keys()].filter(name => !liveByName.has(name)).sort();
  const added = [...liveByName.keys()].filter(name => !manifestByName.has(name)).sort();
  const changed = [...manifestByName.keys()]
    .filter(name => liveByName.has(name) && manifestByName.get(name) !== liveByName.get(name))
    .sort();

  return { compatible: missing.length === 0 && added.length === 0 && changed.length === 0, missing, added, changed };
}
