const fs = require('fs');
const path = require('path');

const runtimeRoot = path.resolve(process.argv[2] || '');
const dryRun = process.argv.includes('--dry-run');
if (!runtimeRoot || !fs.existsSync(runtimeRoot)) {
  console.error('Usage: node prune-workspace-runtime.js <stageRuntimeRoot> [--dry-run]');
  process.exit(2);
}

const sourceRoots = ['apps', 'packages', 'vendor', 'native']
  .map((name) => path.join(runtimeRoot, name))
  .filter((entry) => fs.existsSync(entry));
const candidateFiles = new Set();
const runtimeFiles = new Set();
const packageRoots = [];

function normalize(file) {
  return path.normalize(file);
}

function walk(directory, visit) {
  const stack = [directory];
  while (stack.length) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (entry.name === 'node_modules') continue;
        stack.push(fullPath);
      } else {
        visit(fullPath);
      }
    }
  }
}

for (const root of sourceRoots) {
  walk(root, (file) => {
    if (path.basename(file) === 'package.json') packageRoots.push(path.dirname(file));
    if (!/\.(?:cjs|mjs|js|json)$/i.test(file)) return;
    const normalized = normalize(file);
    runtimeFiles.add(normalized);
    if (/[\\/]lib[\\/]types[\\/]/i.test(normalized) && /\.(?:cjs|mjs|js)$/i.test(normalized)) {
      candidateFiles.add(normalized);
    }
  });
}

const packageByName = new Map();
for (const packageRoot of packageRoots) {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
    if (manifest.name) packageByName.set(manifest.name, { root: packageRoot, manifest });
  } catch {}
}

function addRuntimeTarget(targets, packageRoot, value) {
  if (typeof value !== 'string' || value.includes('*')) return;
  const clean = value.replace(/^\.\//, '');
  if (/\.d\.(?:ts|mts|cts)$/i.test(clean)) return;
  const target = normalize(path.join(packageRoot, clean));
  if (runtimeFiles.has(target)) targets.add(target);
}

function collectExportTargets(targets, packageRoot, value, condition = '') {
  if (typeof value === 'string') {
    if (condition !== 'types') addRuntimeTarget(targets, packageRoot, value);
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    collectExportTargets(targets, packageRoot, child, key);
  }
}

function expandWildcardExports(targets, packageRoot, value, condition = '') {
  if (typeof value === 'string') {
    if (condition === 'types' || !value.includes('*')) return;
    const clean = value.replace(/^\.\//, '').replaceAll('/', path.sep);
    const parts = clean.split('*');
    const prefix = normalize(path.join(packageRoot, parts[0]));
    const suffix = parts[1] || '';
    for (const file of runtimeFiles) {
      if (file.startsWith(prefix) && file.endsWith(suffix)) targets.add(file);
    }
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    expandWildcardExports(targets, packageRoot, child, key);
  }
}

const reachable = new Set();
const queue = [];
function mark(file) {
  const normalized = normalize(file);
  if (!runtimeFiles.has(normalized) || reachable.has(normalized)) return;
  reachable.add(normalized);
  queue.push(normalized);
}

for (const file of runtimeFiles) {
  if (!candidateFiles.has(file)) mark(file);
}
for (const { root, manifest } of packageByName.values()) {
  const targets = new Set();
  addRuntimeTarget(targets, root, manifest.main);
  addRuntimeTarget(targets, root, manifest.module);
  collectExportTargets(targets, root, manifest.exports);
  expandWildcardExports(targets, root, manifest.exports);
  for (const target of targets) mark(target);
}

const specifierPattern = /(?:\brequire\s*\(\s*|\bimport\s*\(\s*|\bfrom\s+|\bexport\s+(?:[\w*{}\s,]+)\s+from\s+)['"]([^'"]+)['"]/g;
function resolveFile(base) {
  const candidates = [base, `${base}.js`, `${base}.mjs`, `${base}.cjs`, `${base}.json`, path.join(base, 'index.js')];
  return candidates.find((candidate) => runtimeFiles.has(normalize(candidate)));
}

while (queue.length) {
  const file = queue.shift();
  if (!/\.(?:cjs|mjs|js)$/i.test(file)) continue;
  let contents;
  try {
    contents = fs.readFileSync(file, 'utf8');
  } catch {
    continue;
  }
  specifierPattern.lastIndex = 0;
  let match;
  while ((match = specifierPattern.exec(contents))) {
    const specifier = match[1];
    if (specifier.startsWith('.')) {
      const resolved = resolveFile(path.resolve(path.dirname(file), specifier));
      if (resolved) mark(resolved);
      continue;
    }
    const packageName = specifier.startsWith('@')
      ? specifier.split('/').slice(0, 2).join('/')
      : specifier.split('/')[0];
    const workspacePackage = packageByName.get(packageName);
    if (!workspacePackage) continue;
    const subpath = specifier.slice(packageName.length).replace(/^\//, '');
    if (subpath) {
      const resolved = resolveFile(path.join(workspacePackage.root, subpath));
      if (resolved) mark(resolved);
    } else {
      const resolved = resolveFile(path.join(workspacePackage.root, workspacePackage.manifest.main || 'lib/index.js'));
      if (resolved) mark(resolved);
    }
  }
}

const dropped = [...candidateFiles].filter((file) => !reachable.has(file));
let droppedBytes = 0;
for (const file of dropped) {
  try {
    droppedBytes += fs.statSync(file).size;
    if (!dryRun) fs.rmSync(file, { force: true });
  } catch {}
}

console.log(JSON.stringify({
  ok: true,
  dryRun,
  candidates: candidateFiles.size,
  kept: candidateFiles.size - dropped.length,
  dropped: dropped.length,
  droppedBytes,
  droppedMb: Math.round((droppedBytes / 1024 / 1024) * 100) / 100,
  examples: dropped.slice(0, 30).map((file) => path.relative(runtimeRoot, file).replaceAll('\\', '/')),
}, null, 2));
