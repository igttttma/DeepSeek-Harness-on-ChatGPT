const fs = require('fs');
const path = require('path');

function usage() {
  console.error('Usage: node prune-unreachable-nm.js <stageRuntimeRoot> [--dry-run]');
  process.exit(2);
}

const root = process.argv[2];
const dryRun = process.argv.includes('--dry-run');
if (!root) usage();

const runtimeRoot = path.resolve(root);
const nmRoot = path.join(runtimeRoot, 'node_modules');
if (!fs.existsSync(nmRoot)) {
  console.log(JSON.stringify({ ok: true, dropped: [], kept: 0, reason: 'no-node_modules' }));
  process.exit(0);
}

function isReparse(p) {
  try {
    const st = fs.lstatSync(p);
    return st.isSymbolicLink() || Boolean(st.isDirectory() && (st.mode & 0o100000) === 0 && st.nlink === 1 && false);
  } catch {
    return false;
  }
}

// Windows junctions: lstat usually reports isSymbolicLink=false for junctions on some Node builds;
// use readlink / attributes via fs.realpath vs path, and dirent.
function isLinkLike(p) {
  try {
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) return true;
  } catch {
    return false;
  }
  // Detect Windows junction: GetFileAttributes via powershell is heavy; use:
  // if reparse point, Node on Windows sets isSymbolicLink for symlinks; junctions often too.
  try {
    fs.readlinkSync(p);
    return true;
  } catch {
    return false;
  }
}

function listPrivatePackages(nm) {
  const out = [];
  for (const name of fs.readdirSync(nm)) {
    if (name === '.bin' || name.startsWith('.')) continue;
    const p = path.join(nm, name);
    if (isLinkLike(p)) continue;
    let st;
    try { st = fs.lstatSync(p); } catch { continue; }
    if (!st.isDirectory()) continue;
    if (name.startsWith('@')) {
      let kids = [];
      try { kids = fs.readdirSync(p); } catch { continue; }
      for (const kid of kids) {
        const cp = path.join(p, kid);
        if (isLinkLike(cp)) continue;
        let cst;
        try { cst = fs.lstatSync(cp); } catch { continue; }
        if (cst.isDirectory()) out.push(name + '/' + kid);
      }
    } else {
      out.push(name);
    }
  }
  return out;
}

function pkgPath(name) {
  return path.join(nmRoot, ...name.split('/'));
}

function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch {
    return null;
  }
}

function packageExists(name) {
  const p = pkgPath(name);
  try {
    return fs.existsSync(path.join(p, 'package.json')) || fs.existsSync(p);
  } catch {
    return false;
  }
}

const seedDirs = [];
for (const rel of ['apps', 'packages', 'vendor', 'native', 'home', 'profiles']) {
  const p = path.join(runtimeRoot, rel);
  if (fs.existsSync(p)) seedDirs.push(p);
}

const IMPORT_RE = /(?:\brequire\s*\(\s*|from\s+|import\s*\(\s*|export\s+(?:[\w*{}\s,]+)\s+from\s+)['"]([^'"]+)['"]/g;
const DYNAMIC_RE = /(?:import|require)\s*\(\s*['"]([^'"]+)['"]\s*\)/g;

function walkFiles(dir, acc) {
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    let ents;
    try { ents = fs.readdirSync(cur, { withFileTypes: true }); } catch { continue; }
    for (const ent of ents) {
      const p = path.join(cur, ent.name);
      if (ent.name === 'node_modules' || ent.name === '.git' || ent.name === 'dist-ssr') continue;
      if (ent.isSymbolicLink()) continue;
      if (ent.isDirectory()) {
        // skip tests-ish
        if (/^(tests?|__tests__|coverage|fixtures|docs|examples?)$/i.test(ent.name)) continue;
        stack.push(p);
      } else if (/\.(cjs|mjs|js)$/i.test(ent.name) && !/\.(test|spec|e2e)\./i.test(ent.name)) {
        acc.push(p);
      }
    }
  }
}

function resolvePackageName(spec) {
  if (!spec || spec.startsWith('.') || spec.startsWith('/') || spec.startsWith('node:') || spec.startsWith('data:') || spec.startsWith('http:') || spec.startsWith('https:') || spec.startsWith('file:')) {
    return null;
  }
  if (spec.startsWith('@')) {
    const parts = spec.split('/');
    if (parts.length < 2) return null;
    return parts[0] + '/' + parts[1];
  }
  return spec.split('/')[0];
}

function depsFromPackageJson(pkgName) {
  const pj = readJson(path.join(pkgPath(pkgName), 'package.json'));
  if (!pj) return [];
  const names = [];
  for (const section of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    const deps = pj[section] || {};
    for (const n of Object.keys(deps)) names.push(n);
  }
  return names;
}

function entryFilesFromPackage(pkgName) {
  const dir = pkgPath(pkgName);
  const pj = readJson(path.join(dir, 'package.json'));
  const files = [];
  if (!pj) return files;
  const add = (rel) => {
    if (!rel || typeof rel !== 'string') return;
    const cleaned = rel.replace(/^\.\//, '');
    const abs = path.join(dir, cleaned);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) files.push(abs);
  };
  if (typeof pj.main === 'string') add(pj.main);
  if (typeof pj.module === 'string') add(pj.module);
  if (typeof pj.exports === 'string') add(pj.exports);
  else if (pj.exports && typeof pj.exports === 'object') {
    const stack = [pj.exports];
    while (stack.length) {
      const cur = stack.pop();
      if (!cur) continue;
      if (typeof cur === 'string') add(cur);
      else if (typeof cur === 'object') {
        for (const v of Object.values(cur)) stack.push(v);
      }
    }
  }
  // also scan package dist/lib lightly if empty
  if (files.length === 0) {
    for (const cand of ['index.js', 'dist/index.js', 'lib/index.js', 'lib/bin.js']) {
      const abs = path.join(dir, cand);
      if (fs.existsSync(abs)) files.push(abs);
    }
  }
  return files;
}

const privatePkgs = listPrivatePackages(nmRoot);
const privateSet = new Set(privatePkgs);
const reachable = new Set();
const queue = [];

function mark(name) {
  if (!name || reachable.has(name)) return;
  if (!privateSet.has(name) && !packageExists(name)) return;
  // mark even if junction/external so we still traverse its deps if private exists
  if (!privateSet.has(name)) {
    // still follow package.json deps if present under nm as link? skip file walk for non-private
    reachable.add(name);
    for (const d of depsFromPackageJson(name)) {
      const pn = resolvePackageName(d);
      if (pn && privateSet.has(pn) && !reachable.has(pn)) queue.push(pn);
    }
    return;
  }
  reachable.add(name);
  queue.push(name);
}

// Seed: scan harvested source trees for imports, plus their package.json deps
const seedFiles = [];
for (const d of seedDirs) walkFiles(d, seedFiles);

function considerSpec(spec) {
  const pn = resolvePackageName(spec);
  if (pn) mark(pn);
}

for (const f of seedFiles) {
  let text;
  try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
  IMPORT_RE.lastIndex = 0;
  let m;
  while ((m = IMPORT_RE.exec(text))) considerSpec(m[1]);
  DYNAMIC_RE.lastIndex = 0;
  while ((m = DYNAMIC_RE.exec(text))) considerSpec(m[1]);
}

// Also seed dependencies declared by harvested workspace package.json files
function walkPkgJson(dir) {
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    let ents;
    try { ents = fs.readdirSync(cur, { withFileTypes: true }); } catch { continue; }
    for (const ent of ents) {
      const p = path.join(cur, ent.name);
      if (ent.isDirectory()) {
        if (ent.name === 'node_modules' || ent.name === '.git') continue;
        stack.push(p);
      } else if (ent.name === 'package.json') {
        const pj = readJson(p);
        if (!pj) continue;
        for (const section of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
          const deps = pj[section] || {};
          for (const n of Object.keys(deps)) mark(n);
        }
      }
    }
  }
}
for (const d of seedDirs) walkPkgJson(d);

// BFS through private packages
const seenFiles = new Set(seedFiles);
while (queue.length) {
  const name = queue.shift();
  for (const d of depsFromPackageJson(name)) {
    const pn = resolvePackageName(d);
    if (pn) mark(pn);
  }
  for (const f of entryFilesFromPackage(name)) {
    if (seenFiles.has(f)) continue;
    seenFiles.add(f);
    // also walk adjacent js under package (bounded)
  }
  // walk all js in package (except tests)
  const files = [];
  walkFiles(pkgPath(name), files);
  for (const f of files) {
    if (seenFiles.has(f)) continue;
    seenFiles.add(f);
    let text;
    try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
    IMPORT_RE.lastIndex = 0;
    let m;
    while ((m = IMPORT_RE.exec(text))) considerSpec(m[1]);
    DYNAMIC_RE.lastIndex = 0;
    while ((m = DYNAMIC_RE.exec(text))) considerSpec(m[1]);
  }
}

const drop = privatePkgs.filter((n) => !reachable.has(n)).sort();
const kept = privatePkgs.filter((n) => reachable.has(n)).sort();

function rmTree(p) {
  fs.rmSync(p, { recursive: true, force: true });
}

if (!dryRun) {
  for (const n of drop) {
    const p = pkgPath(n);
    if (isLinkLike(p)) continue;
    rmTree(p);
  }
  // cleanup empty scopes
  for (const name of fs.readdirSync(nmRoot)) {
    if (!name.startsWith('@')) continue;
    const sp = path.join(nmRoot, name);
    if (isLinkLike(sp)) continue;
    let kids = [];
    try { kids = fs.readdirSync(sp); } catch { continue; }
    if (kids.length === 0) rmTree(sp);
  }
}

const result = {
  ok: true,
  dryRun,
  privateBefore: privatePkgs.length,
  kept: kept.length,
  dropped: drop,
  droppedCount: drop.length,
  seedFiles: seedFiles.length
};
console.log(JSON.stringify(result, null, 2));
