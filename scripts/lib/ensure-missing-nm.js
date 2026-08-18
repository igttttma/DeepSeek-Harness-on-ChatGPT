const fs = require('fs');
const path = require('path');

function usage() {
  console.error('Usage: node ensure-missing-nm.js <sourceRoot> <stageRuntimeRoot> <blacklistJson> [--browser-drop=a,b] [--cg-packages=a,b]');
  process.exit(2);
}

const sourceRoot = process.argv[2];
const stageRoot = process.argv[3];
const blacklistPath = process.argv[4];
if (!sourceRoot || !stageRoot || !blacklistPath) usage();

function parseListArg(prefix) {
  const arg = process.argv.find((a) => a.startsWith(prefix));
  if (!arg) return [];
  return arg.slice(prefix.length).split(',').map((s) => s.trim()).filter(Boolean);
}

const browserDrop = new Set(parseListArg('--browser-drop=').map((s) => s.replace(/\\/g, '/')));
const cgPackages = new Set(
  parseListArg('--cg-packages=').map((s) => s.replace(/\\/g, '/')).concat([
    'sharp','playwright','playwright-core','pdfjs-dist','tesseract.js','tesseract.js-core',
    'bmp-js','jpeg-js','pngjs','pixelmatch','semver','detect-libc','node-fetch','idb-keyval',
    'is-url','opencollective-postinstall','node-readable-to-web-readable-stream','regenerator-runtime',
    'tr46','webidl-conversions','whatwg-url','zlibjs','wasm-feature-detect',
    '@img/colour','@img/sharp-win32-x64','@napi-rs/canvas','@napi-rs/canvas-win32-x64-msvc'
  ])
);

const blacklist = JSON.parse(fs.readFileSync(blacklistPath, 'utf8').replace(/^\uFEFF/, ''));
const blNames = new Set((blacklist.npmPackages || []).map((s) => String(s).toLowerCase()));
const blScopes = new Set((blacklist.npmScopes || []).map((s) => String(s).toLowerCase()));
const blWs = new Set((blacklist.workspacePackageNames || []).map((s) => String(s)));
const keepWs = new Set((blacklist.keepWorkspacePackages || []).map((s) => String(s)));

const srcNm = path.join(sourceRoot, 'node_modules');
const dstNm = path.join(stageRoot, 'node_modules');

function isPlatformOptional(name) {
  return /^(@img\/sharp-(?!win32-x64)|@img\/sharp-libvips-|@koromix\/koffi-(?!win32-x64)|@esbuild\/(?!win32-x64)|fsevents$)/i.test(name);
}

function isBlacklistedName(name) {
  const n = name.toLowerCase();
  if (n.startsWith('@types/')) return true;
  if (blNames.has(n)) return true;
  if (browserDrop.has(name) || browserDrop.has(n)) return true;
  if (cgPackages.has(name) || cgPackages.has(n)) return true;
  if (isPlatformOptional(name)) return true;
  if (n.startsWith('@')) {
    const scope = n.split('/')[0];
    if (blScopes.has(scope)) return true;
  }
  if (name.startsWith('@deepseek-ai/') && blWs.has(name) && !keepWs.has(name)) return true;
  return false;
}

function isLinkLike(p) {
  try {
    if (fs.lstatSync(p).isSymbolicLink()) return true;
  } catch {
    return false;
  }
  try {
    fs.readlinkSync(p);
    return true;
  } catch {
    return false;
  }
}

function pkgDir(nmRoot, name) {
  return path.join(nmRoot, ...name.split('/'));
}

function existsPkg(nmRoot, name) {
  return fs.existsSync(path.join(pkgDir(nmRoot, name), 'package.json')) || fs.existsSync(pkgDir(nmRoot, name));
}

function findInPnpm(name) {
  const pnpm = path.join(srcNm, '.pnpm');
  if (!fs.existsSync(pnpm)) return null;
  const encoded = name.startsWith('@') ? name.replace('/', '+') : name;
  const ents = fs.readdirSync(pnpm);
  const prefix = encoded.toLowerCase() + '@';
  for (const ent of ents) {
    if (!ent.toLowerCase().startsWith(prefix)) continue;
    const cand = path.join(pnpm, ent, 'node_modules', ...name.split('/'));
    if (fs.existsSync(path.join(cand, 'package.json'))) return cand;
  }
  for (const ent of ents) {
    const cand = path.join(pnpm, ent, 'node_modules', ...name.split('/'));
    if (fs.existsSync(path.join(cand, 'package.json'))) return cand;
  }
  return null;
}

function resolveSourcePkg(name) {
  const top = pkgDir(srcNm, name);
  if (fs.existsSync(path.join(top, 'package.json'))) {
    if (isLinkLike(top)) {
      try {
        const target = fs.readlinkSync(top);
        const full = path.isAbsolute(target) ? target : path.resolve(path.dirname(top), target);
        if (fs.existsSync(path.join(full, 'package.json'))) return full;
      } catch {}
    }
    return top;
  }
  return findInPnpm(name);
}

function shouldSkipCopyDirName(name) {
  return /^(tests?|__tests__|coverage|docs?|examples?|fixtures|benchmarks?|\.git|\.github|\.turbo)$/i.test(name);
}

function copyPrivatePackage(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  const stack = [[src, dst]];
  while (stack.length) {
    const [s, d] = stack.pop();
    let ents;
    try {
      ents = fs.readdirSync(s, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ent of ents) {
      if (ent.name === 'node_modules') continue;
      if (ent.isDirectory() && shouldSkipCopyDirName(ent.name)) continue;
      if (ent.isSymbolicLink()) continue;
      const sp = path.join(s, ent.name);
      const dp = path.join(d, ent.name);
      if (ent.isDirectory()) {
        if (/^(darwin-|linux-|android-|win32-arm|prebuilds)/i.test(ent.name) && !/win32-x64/i.test(ent.name)) continue;
        fs.mkdirSync(dp, { recursive: true });
        stack.push([sp, dp]);
      } else if (ent.isFile()) {
        if (/\.(md|markdown|map|ts|tsx)$/i.test(ent.name)) continue;
        if (/\.development(\.min)?\.js$/i.test(ent.name)) continue;
        fs.copyFileSync(sp, dp);
      }
    }
  }
}

function readDeps(pkgPath, { includeOptional = false } = {}) {
  const pj = path.join(pkgPath, 'package.json');
  if (!fs.existsSync(pj)) return [];
  let j;
  try {
    j = JSON.parse(fs.readFileSync(pj, 'utf8'));
  } catch {
    return [];
  }
  const out = [];
  const sections = includeOptional
    ? ['dependencies', 'optionalDependencies', 'peerDependencies']
    : ['dependencies', 'peerDependencies'];
  for (const sec of sections) {
    const deps = j[sec] || {};
    for (const n of Object.keys(deps)) out.push(n);
  }
  return out;
}

function walkStagePackageJsonDeps(acc) {
  for (const rel of ['apps', 'packages', 'vendor', 'native', 'home', 'profiles']) {
    const dir = path.join(stageRoot, rel);
    if (!fs.existsSync(dir)) continue;
    const stack = [dir];
    while (stack.length) {
      const cur = stack.pop();
      let ents;
      try {
        ents = fs.readdirSync(cur, { withFileTypes: true });
      } catch {
        continue;
      }
      for (const ent of ents) {
        const p = path.join(cur, ent.name);
        if (ent.isDirectory()) {
          if (ent.name === 'node_modules' || ent.name === '.git') continue;
          stack.push(p);
        } else if (ent.name === 'package.json') {
          let j;
          try {
            j = JSON.parse(fs.readFileSync(p, 'utf8'));
          } catch {
            continue;
          }
          if (j.name && blWs.has(j.name) && !keepWs.has(j.name)) continue;
          for (const n of readDeps(path.dirname(p), { includeOptional: false })) acc.add(n);
        }
      }
    }
  }
}

const queue = [];
const seen = new Set();
const added = [];
const missingUnresolved = [];
const skipped = [];

function enqueue(name) {
  if (!name || seen.has(name)) return;
  if (name.startsWith('workspace:') || name.startsWith('link:') || name.startsWith('file:')) return;
  if (isBlacklistedName(name)) {
    skipped.push(name);
    return;
  }
  seen.add(name);
  queue.push(name);
}

const roots = new Set();
walkStagePackageJsonDeps(roots);
for (const n of roots) enqueue(n);

while (queue.length) {
  const name = queue.shift();
  if (existsPkg(dstNm, name)) {
    for (const d of readDeps(pkgDir(dstNm, name), { includeOptional: false })) enqueue(d);
    continue;
  }
  const src = resolveSourcePkg(name);
  if (!src) {
    missingUnresolved.push(name);
    continue;
  }
  const rel = path.relative(sourceRoot, src).replace(/\\/g, '/');
  if (/^(packages|vendor|apps|native)\//.test(rel)) continue;
  const dst = pkgDir(dstNm, name);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  copyPrivatePackage(src, dst);
  added.push(name);
  for (const d of readDeps(dst, { includeOptional: false })) enqueue(d);
}

const result = {
  ok: true,
  rootDeps: roots.size,
  added,
  addedCount: added.length,
  skippedUnique: [...new Set(skipped)].sort(),
  missingUnresolved: missingUnresolved.sort(),
  missingUnresolvedCount: missingUnresolved.length
};
console.log(JSON.stringify(result, null, 2));
