/** Persistent model-facing Bash tool backed by managed stdio pipes, not a PTY. */

import { randomUUID } from 'node:crypto'
import { StringDecoder } from 'node:string_decoder'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'

const DEFAULT_DESCRIPTION = 'Run commands in a persistent bash shell. State, including the current directory and exported environment variables, persists across calls for this agent.'
const LOST_PREFIX_MESSAGE = '<response clipped><NOTE>The beginning of this command output was dropped by the pipe output limit. The following text is the earliest retained output.</NOTE>\n'
const TRUNCATED_MESSAGE = '<response clipped><NOTE>Only the most recent command output is retained.</NOTE>'
const SHELL_RESET_MESSAGE = 'The persistent bash shell was reset; the next bash call starts from the workspace with a fresh current directory and environment.'
const MAX_TIMER_DELAY_MS = 2_147_483_647

function quoteForBash(value) {
  return `$'${value
    .replaceAll('\\', '\\\\')
    .replaceAll("'", "\\'")
    .replaceAll('\r', '\\r')
    .replaceAll('\n', '\\n')}'`
}

function commandFrame(command) {
  const nonce = randomUUID()
  const start = `__DSH_PIPE_BASH_START_${nonce}__`
  const end = `__DSH_PIPE_BASH_END_${nonce}:`
  const quotedCommand = quoteForBash(command)
  const quotedStart = quoteForBash(start)
  const quotedEnd = quoteForBash(end)
  return {
    start,
    end,
    text: `printf '%s\\n' ${quotedStart}; { eval -- ${quotedCommand}; } 2>&1; __dsh_pipe_bash_status=$?; printf '%s%s\\n' ${quotedEnd} "$__dsh_pipe_bash_status"\n`,
  }
}

function trimOneTrailingNewline(text) {
  return text.replace(/\r?\n$/, '')
}

function appendStatus(content, marker) {
  if (marker === undefined) return content
  return content.length === 0 ? marker : `${content}\n${marker}`
}

function renderOutput(result, maxOutputChars) {
  let text = result.text
  let truncated = result.truncated
  if (text.length > maxOutputChars) {
    text = text.slice(-maxOutputChars)
    truncated = true
  }
  if (truncated && text.length > 0) text = LOST_PREFIX_MESSAGE + text
  if (truncated) text = appendStatus(text, TRUNCATED_MESSAGE)
  const exitMarker = result.exitCode !== undefined && result.exitCode !== 0
    ? `[exit code: ${result.exitCode}]`
    : undefined
  return appendStatus(text, exitMarker)
}

function renderShellExit(result, outcome, maxOutputChars) {
  const output = renderOutput(result, maxOutputChars)
  const marker = outcome?.signal != null
    ? `[shell killed by signal: ${outcome.signal}]`
    : outcome?.exitCode != null
      ? `[shell exited: code ${outcome.exitCode}]`
      : '[shell exited]'
  return appendStatus(output, marker)
}

class CommandInterrupted extends Error {
  constructor(result) {
    super('persistent pipe bash command interrupted')
    this.result = result
  }
}

class ShellExited extends Error {
  constructor(result, outcome, cause) {
    super('persistent pipe bash shell exited', cause === undefined ? undefined : { cause })
    this.result = result
    this.outcome = outcome
  }
}

class PipeShell {
  constructor(handle, maxOutputChars) {
    if (handle.stdin === undefined || handle.stdout === undefined || handle.stderr === undefined) {
      handle.terminate()
      throw new Error('persistent-pipe-bash: subprocess provider dropped a requested pipe')
    }
    this.handle = handle
    this.stdin = handle.stdin
    this.stdout = handle.stdout
    this.stderr = handle.stderr
    this.maxRetainedChars = maxOutputChars + 512
    this.stdoutDecoder = new StringDecoder('utf8')
    this.stderrDecoder = new StringDecoder('utf8')
    this.current = undefined
    this.diagnostics = ''
    this.closed = false
    this.outcome = undefined
    this.failure = undefined

    this.stdout.on('data', chunk => this.feedStdout(this.stdoutDecoder.write(chunk)))
    this.stderr.on('data', chunk => this.feedDiagnostic(this.stderrDecoder.write(chunk)))
    this.settled = handle.done.then(
      outcome => this.finish(outcome, undefined),
      error => this.finish(undefined, error),
    )
  }

  feedDiagnostic(text) {
    if (text.length === 0) return
    this.diagnostics = (this.diagnostics + text).slice(-this.maxRetainedChars)
  }

  feedStdout(text) {
    const command = this.current
    if (command === undefined || text.length === 0) return
    command.raw += text

    if (!command.started) {
      const startAt = command.raw.indexOf(command.start)
      if (startAt < 0) {
        command.raw = command.raw.slice(-(command.start.length + 2))
        return
      }
      command.started = true
      command.raw = command.raw.slice(startAt + command.start.length).replace(/^\r?\n/, '')
    }

    const endAt = command.raw.indexOf(command.end)
    if (endAt >= 0) {
      const status = /^(\d+)\r?\n/.exec(command.raw.slice(endAt + command.end.length))
      if (status === null) return
      const result = {
        text: trimOneTrailingNewline(command.raw.slice(0, endAt)),
        truncated: command.truncated,
        exitCode: Number(status[1]),
      }
      this.current = undefined
      command.cleanup()
      command.resolve(result)
      return
    }

    if (command.raw.length > this.maxRetainedChars) {
      command.raw = command.raw.slice(-this.maxRetainedChars)
      command.truncated = true
    }
  }

  snapshot(command = this.current) {
    if (command === undefined) return { text: '', truncated: false }
    const raw = command.started ? command.raw : ''
    return {
      text: trimOneTrailingNewline(raw.slice(-this.maxRetainedChars)),
      truncated: command.truncated || raw.length > this.maxRetainedChars,
    }
  }

  finish(outcome, error) {
    if (this.closed && this.outcome !== undefined) return
    const stdoutTail = this.stdoutDecoder.end()
    if (stdoutTail.length > 0) this.feedStdout(stdoutTail)
    const stderrTail = this.stderrDecoder.end()
    if (stderrTail.length > 0) this.feedDiagnostic(stderrTail)
    this.closed = true
    this.outcome = outcome
    this.failure = error
    const command = this.current
    if (command !== undefined) {
      const result = this.snapshot(command)
      if (this.diagnostics.length > 0) {
        result.text = appendStatus(result.text, `[stderr]\n${trimOneTrailingNewline(this.diagnostics)}`)
      }
      this.current = undefined
      command.cleanup()
      command.reject(new ShellExited(result, outcome, error))
    }
  }

  async run(commandText, signal) {
    if (this.closed) throw new ShellExited({ text: this.diagnostics, truncated: false }, this.outcome, this.failure)
    if (this.current !== undefined) throw new Error('persistent-pipe-bash: concurrent command on one shell')
    signal.throwIfAborted()
    const frame = commandFrame(commandText)
    const operation = Promise.withResolvers()
    const onAbort = () => {
      if (this.current !== command) return
      const result = this.snapshot(command)
      this.current = undefined
      command.cleanup()
      command.reject(new CommandInterrupted(result))
    }
    const command = {
      ...frame,
      raw: '',
      started: false,
      truncated: false,
      resolve: operation.resolve,
      reject: operation.reject,
      cleanup: () => signal.removeEventListener('abort', onAbort),
    }
    this.current = command
    signal.addEventListener('abort', onAbort, { once: true })
    if (signal.aborted) onAbort()
    if (this.current !== command) return operation.promise

    await new Promise((resolve, reject) => {
      this.stdin.write(frame.text, 'utf8', error => error == null ? resolve() : reject(error))
    }).catch((error) => {
      if (this.current === command) {
        this.current = undefined
        command.cleanup()
        command.reject(error)
      }
    })
    return operation.promise
  }

  async close() {
    if (!this.closed) this.handle.terminate()
    await Promise.allSettled([this.settled, this.handle.waitForExit()])
  }

  get exited() {
    return this.closed
  }
}

async function createShell(ctx, owner, config, signal) {
  const executable = await ctx.subprocess.resolveExecutable(config.shellCommand, undefined, signal)
  signal.throwIfAborted()
  const handle = ctx.subprocess.spawn({
    argv: [executable, ...config.shellArgs],
    cwd: owner.session.header.cwd ?? process.cwd(),
    stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' },
    graceMs: config.disposeGraceMs,
    env: {
      NO_COLOR: '1',
      TERM: 'dumb',
      PAGER: 'cat',
      GIT_PAGER: 'cat',
      CHERE_INVOKING: '1',
    },
  })
  return new PipeShell(handle, config.maxOutputChars)
}

function persistentShells(ctx, config) {
  const pending = new WeakMap()
  const live = new Map()
  const creations = new Set()
  const ownerCleanupInstalled = new WeakSet()
  const lifecycle = new AbortController()

  const reset = async (owner) => {
    pending.delete(owner)
    const shell = live.get(owner)
    live.delete(owner)
    if (shell !== undefined) await shell.close()
  }

  ctx.effect(() => async () => {
    lifecycle.abort(new Error('persistent pipe bash plugin disposed'))
    await Promise.allSettled([...creations])
    await Promise.allSettled([...live.values()].map(shell => shell.close()))
    live.clear()
  }, 'persistent pipe bash cleanup')

  const get = (owner, signal) => {
    const active = live.get(owner)
    if (active !== undefined && !active.exited) return Promise.resolve(active)
    if (active?.exited) live.delete(owner)
    const existing = pending.get(owner)
    if (existing !== undefined) return existing
    const combinedSignal = AbortSignal.any([signal, lifecycle.signal])
    const creation = createShell(ctx, owner, config, combinedSignal).then((shell) => {
      live.set(owner, shell)
      if (!ownerCleanupInstalled.has(owner)) {
        ownerCleanupInstalled.add(owner)
        owner.ctx.effect(() => async () => { await reset(owner) }, 'persistent pipe bash owner cleanup')
      }
      return shell
    })
    const tracked = creation.finally(() => {
      creations.delete(tracked)
      if (pending.get(owner) === tracked) pending.delete(owner)
    })
    creations.add(tracked)
    pending.set(owner, tracked)
    return tracked
  }

  return { get, reset }
}

async function executeCommand(shells, owner, command, config, upstream) {
  const timeout = new AbortController()
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    timeout.abort(new Error('persistent pipe bash command timed out'))
  }, config.timeoutMs)
  const signal = AbortSignal.any([upstream, timeout.signal])
  try {
    const shell = await shells.get(owner, signal)
    try {
      const result = await shell.run(command, signal)
      return renderOutput(result, config.maxOutputChars)
    } catch (error) {
      if (error instanceof CommandInterrupted) {
        await shells.reset(owner)
        if (timedOut) {
          return [
            `Your command timed out after ${Math.round(config.timeoutMs / 1000)} seconds. Below is partial output:`,
            renderOutput(error.result, config.maxOutputChars),
            SHELL_RESET_MESSAGE,
          ].filter(part => part.length > 0).join('\n')
        }
        upstream.throwIfAborted()
      }
      if (error instanceof ShellExited) {
        await shells.reset(owner)
        return [
          renderShellExit(error.result, error.outcome, config.maxOutputChars),
          SHELL_RESET_MESSAGE,
        ].filter(part => part.length > 0).join('\n')
      }
      await shells.reset(owner)
      throw error
    }
  } finally {
    clearTimeout(timer)
  }
}

export const name = 'tool-bash-persistent-pipe'
export const inject = ['tools', 'subprocess']

export const Config = z.object({
  shellCommand: z.string().default('bash'),
  shellArgs: z.array(z.string()).default(['--noprofile', '--norc']),
  timeoutMs: z.number().default(300_000),
  maxOutputChars: z.number().default(16_000),
  disposeGraceMs: z.number().default(3_000),
  description: z.string().default(DEFAULT_DESCRIPTION),
})

export function apply(ctx, config = {}) {
  const resolved = {
    shellCommand: config.shellCommand ?? 'bash',
    shellArgs: config.shellArgs ?? ['--noprofile', '--norc'],
    timeoutMs: config.timeoutMs ?? 300_000,
    maxOutputChars: config.maxOutputChars ?? 16_000,
    disposeGraceMs: config.disposeGraceMs ?? 3_000,
    description: config.description ?? DEFAULT_DESCRIPTION,
  }
  if (resolved.shellCommand.trim().length === 0) throw new Error('persistent-pipe-bash: shellCommand must be non-empty')
  if (!Array.isArray(resolved.shellArgs) || resolved.shellArgs.some(arg => typeof arg !== 'string')) {
    throw new Error('persistent-pipe-bash: shellArgs must contain only strings')
  }
  for (const field of ['timeoutMs', 'maxOutputChars', 'disposeGraceMs']) {
    const value = resolved[field]
    if (!Number.isSafeInteger(value) || value <= 0 || value > MAX_TIMER_DELAY_MS) {
      throw new Error(`persistent-pipe-bash: ${field} must be a positive safe timer-sized integer`)
    }
  }
  if (resolved.description.trim().length === 0) throw new Error('persistent-pipe-bash: description must be non-empty')

  const shells = persistentShells(ctx, resolved)
  const queues = new WeakMap()
  const serialized = async (owner, operation) => {
    const prior = queues.get(owner) ?? Promise.resolve()
    const run = prior.then(operation, operation)
    const tail = run.then(() => undefined, () => undefined)
    queues.set(owner, tail)
    try {
      return await run
    } finally {
      if (queues.get(owner) === tail) queues.delete(owner)
    }
  }

  ctx.tools.register(defineTool({
    name: 'bash',
    description: resolved.description,
    parameters: {
      command: {
        type: 'string',
        required: true,
        description: 'The bash command to run. Relative paths are preferred.',
      },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args, exec) {
      if (typeof args.command !== 'string' || args.command.trim().length === 0) {
        throw new Error('command must be a non-empty string')
      }
      const owner = exec.agent
      if (owner === undefined) throw new Error('bash requires an owning agent session')
      return serialized(owner, async () => {
        exec.signal.throwIfAborted()
        return executeCommand(shells, owner, args.command, resolved, exec.signal)
      })
    },
    presentCall: args => ({ card: 'terminal', title: args.command }),
  }))
}
