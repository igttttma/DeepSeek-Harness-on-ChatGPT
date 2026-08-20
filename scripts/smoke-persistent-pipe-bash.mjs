import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const runtimeRoot = path.resolve(process.argv[2] ?? 'dist/stage/dsh-runtime')
const gitBin = process.env.DSH_TEST_BASH_BIN
  ?? (process.platform === 'win32' ? 'C:\\Program Files\\Git\\usr\\bin' : '/usr/bin')
if (!existsSync(path.join(gitBin, process.platform === 'win32' ? 'bash.exe' : 'bash'))) {
  throw new Error(`smoke Bash not found in ${gitBin}; set DSH_TEST_BASH_BIN`)
}
process.env.PATH = `${gitBin}${path.delimiter}${process.env.PATH ?? ''}`

const importRuntime = relativePath => import(pathToFileURL(path.join(runtimeRoot, relativePath)).href)
const [{ Context }, { default: SystemPrompt }, { default: ToolRuntime }, { default: LocalSubprocessRuntime }, PipeBash] = await Promise.all([
  importRuntime('node_modules/@deepseek-ai/cordis/lib/index.js'),
  importRuntime('packages/core/system-prompt/lib/index.js'),
  importRuntime('packages/core/tools/lib/index.js'),
  importRuntime('packages/subprocess/subprocess-local/lib/index.js'),
  importRuntime('packages/compat/tool-bash-persistent-pipe/lib/index.js'),
])

const workspace = await mkdtemp(path.join(tmpdir(), 'dsh-pipe-bash-smoke-'))
const ctx = new Context()
let callNumber = 0

function text(result) {
  return result.content.filter(block => block.type === 'text').map(block => block.text).join('')
}

try {
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(LocalSubprocessRuntime)
  await ctx.plugin(PipeBash, {
    shellCommand: 'bash',
    timeoutMs: 2_000,
    maxOutputChars: 128,
    disposeGraceMs: 100,
  })

  const ownerScope = ctx.plugin(() => {})
  const owner = {
    id: 'pipe-bash-smoke-owner',
    session: { header: { cwd: workspace } },
    ctx: ownerScope.ctx,
  }
  const executeResult = (command, signal = new AbortController().signal) => ctx.tools.execute({
    signal,
    callId: `pipe-bash-smoke-${++callNumber}`,
    name: 'bash',
    arguments: { command },
    agent: owner,
  })
  const execute = async (command, signal) => text(await executeResult(command, signal))

  assert.deepEqual(ctx.tools.schemas().map(schema => schema.name), ['bash'])
  assert.equal(await execute('export KEEP=pipe; keep_fn() { printf function-ok; }; mkdir nested; cd nested'), '')
  const state = await execute('printf "cwd=%s keep=%s " "$PWD" "$KEEP"; keep_fn')
  assert.match(state, /cwd=.*\/nested keep=pipe function-ok/)
  assert.equal(await execute('value="line one"\nprintf "%s:%s\\n" "$value" "it\'s fine"'), "line one:it's fine")
  assert.equal(await execute('printf out; printf err >&2; false'), 'outerr\n[exit code: 1]')

  const large = await execute('for i in $(seq 1 200); do printf "line-%04d\\n" "$i"; done')
  assert.match(large, /line-0200/)
  assert.match(large, /response clipped/)

  const timedOut = await execute('printf before; sleep 5; printf after')
  assert.match(timedOut, /timed out/)
  assert.match(timedOut, /before/)
  assert.doesNotMatch(timedOut, /\nafter(?:\n|$)/)
  assert.match(timedOut, /shell was reset/)

  const resetState = await execute('printf "cwd=%s keep=%s\\n" "$PWD" "${KEEP-unset}"')
  assert.match(resetState, /keep=unset/)
  assert.doesNotMatch(resetState, /\/nested/)

  assert.equal(await execute('export CANCEL_KEEP=present'), '')
  const cancellation = new AbortController()
  const cancelled = executeResult('printf cancel-before; sleep 5; printf cancel-after', cancellation.signal)
  setTimeout(() => cancellation.abort(new Error('smoke cancellation')), 100)
  await cancelled.catch(() => undefined)
  assert.equal(await execute('printf "%s" "${CANCEL_KEEP-unset}"'), 'unset')

  const exited = await execute('printf leaving; exit 9')
  assert.match(exited, /leaving/)
  assert.match(exited, /shell exited: code 9/)
  assert.match(exited, /shell was reset/)

  await ownerScope.dispose()

  const missingCtx = new Context()
  try {
    await missingCtx.plugin(SystemPrompt)
    await missingCtx.plugin(ToolRuntime)
    await missingCtx.plugin(LocalSubprocessRuntime)
    await missingCtx.plugin(PipeBash, { shellCommand: 'definitely-missing-dsh-bash' })
    const missingScope = missingCtx.plugin(() => {})
    const missingOwner = {
      id: 'missing-bash-owner',
      session: { header: { cwd: workspace } },
      ctx: missingScope.ctx,
    }
    const missingResult = await missingCtx.tools.execute({
      signal: new AbortController().signal,
      callId: 'missing-bash-call',
      name: 'bash',
      arguments: { command: 'true' },
      agent: missingOwner,
    })
    assert.equal(missingResult.isError, true)
    assert.match(text(missingResult), /was not found on PATH/)
  } finally {
    await missingCtx.fiber.dispose()
  }

  console.log(JSON.stringify({ ok: true, runtimeRoot, bashBin: gitBin, calls: callNumber }))
} finally {
  await ctx.fiber.dispose()
  await rm(workspace, { recursive: true, force: true })
}
