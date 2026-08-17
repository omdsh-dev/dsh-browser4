#!/usr/bin/env node
/**
 * dsh-browser4 install hook — runs at `dsh plugin add` time (prepare /
 * postinstall lifecycle scripts).
 *
 * It does exactly what the bundled browser4-cli SKILL.md documents:
 *
 * 1. Installs browser4-cli following the SKILL.md "Installation" section
 *    (`npm install -g browser4-cli` -> `browser4-cli install`, with the
 *    platform bootstrap script as fallback when npm is unavailable).
 * 2. Unpacks the bundled SKILL files with `browser4-cli skills unpack` into
 *    the DSH user skill roots, so every profile/preset discovers them:
 *      - $DSH_HOME/skills        (default ~/.dsh/skills)
 *      - $DSH_AGENTS_HOME/skills (default ~/.agents/skills)
 *
 * Set DSH_BROWSER4_SKIP_CLI_INSTALL=1 to skip step 1 and only refresh the
 * unpacked skill files (browser4-cli must already be installed).
 */
import { spawnSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'

const WINDOWS = process.platform === 'win32'
const SKIP_CLI_INSTALL = process.env.DSH_BROWSER4_SKIP_CLI_INSTALL === '1'
const BOOTSTRAP_SCRIPT_BASE = 'https://browser4.oss-cn-beijing.aliyuncs.com/scripts/install-browser4-cli.'

/** Quote one argument for the platform shell, only when it needs quoting. */
function quote(arg) {
  const text = String(arg)
  if (!/[\s"&|<>^%!()]/.test(text)) return text
  if (WINDOWS) return `"${text.replace(/"/g, '\\"')}"`
  return `'${text.replace(/'/g, `'\\''`)}'`
}

/**
 * Build a shell command line. Each argument is quoted individually; the
 * child process is spawned with windowsVerbatimArguments on Windows so
 * Node passes the /c command line through unchanged.
 */
function buildCmdline(command, args) {
  const parts = [WINDOWS ? quote(command) : command, ...args.map(quote)]
  return parts.join(' ')
}

/** Run a command line through the platform shell with explicit quoting. */
function run(command, args = [], options = {}) {
  const cmdline = buildCmdline(command, args)
  const result = WINDOWS
    ? spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', cmdline], { stdio: 'inherit', windowsVerbatimArguments: true, ...options })
    : spawnSync('/bin/sh', ['-c', cmdline], { stdio: 'inherit', ...options })
  if (result.error) throw result.error
  if (result.status !== 0) {
    throw new Error(`"${cmdline}" failed with exit code ${result.status}`)
  }
  return result
}

/** Probe quietly: true when the command resolves and exits 0. */
function probe(command, args = []) {
  const cmdline = buildCmdline(command, args)
  const result = WINDOWS
    ? spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', cmdline], { stdio: 'pipe', windowsVerbatimArguments: true })
    : spawnSync('/bin/sh', ['-c', cmdline], { stdio: 'pipe' })
  return result.status === 0
}

function installBrowser4CliBinary() {
  if (probe(WINDOWS ? 'npm.cmd' : 'npm', ['--version'])) {
    // Cross-platform method from SKILL.md -> Installation.
    run(WINDOWS ? 'npm.cmd' : 'npm', ['install', '-g', 'browser4-cli'])
  } else if (WINDOWS) {
    // Windows bootstrap script from SKILL.md -> Installation.
    run('powershell.exe', ['-NoProfile', '-Command', `irm ${BOOTSTRAP_SCRIPT_BASE}ps1 | iex`])
  } else {
    // Linux / macOS bootstrap script from SKILL.md -> Installation.
    run('sh', ['-c', `curl -fsSL ${BOOTSTRAP_SCRIPT_BASE}sh | bash`])
  }
}

function ensureBrowser4Cli() {
  if (SKIP_CLI_INSTALL) {
    console.log('==> [dsh-browser4] DSH_BROWSER4_SKIP_CLI_INSTALL=1: skipping browser4-cli install')
    return
  }
  if (probe('browser4-cli', ['--version'])) {
    console.log('==> [dsh-browser4] browser4-cli is already installed')
  } else {
    console.log('==> [dsh-browser4] installing browser4-cli (SKILL.md Installation section) ...')
    installBrowser4CliBinary()
  }
  console.log('==> [dsh-browser4] running `browser4-cli install` (runtime bundle) ...')
  run('browser4-cli', ['install'])
}

function unpackSkills() {
  const home = homedir()
  const dshHome = resolve(process.env.DSH_HOME || join(home, '.dsh'))
  const agentsHome = resolve(process.env.DSH_AGENTS_HOME || join(home, '.agents'))
  const targets = [
    { label: 'DSH home', dir: join(dshHome, 'skills') },
    { label: 'agents home', dir: join(agentsHome, 'skills') },
  ]
  for (const target of targets) {
    mkdirSync(target.dir, { recursive: true })
    console.log(`==> [dsh-browser4] unpacking bundled SKILL files into ${target.dir} ...`)
    run('browser4-cli', ['skills', 'unpack', target.dir])
  }
}

try {
  ensureBrowser4Cli()
  if (!probe('browser4-cli', ['--version'])) {
    throw new Error(
      'browser4-cli is not on PATH after install; open a new shell and re-run "node scripts/install-browser4.mjs"',
    )
  }
  unpackSkills()
  console.log('==> [dsh-browser4] done: browser4-cli is ready and SKILL files are unpacked for DSH')
} catch (error) {
  console.error(`[dsh-browser4] install failed: ${error instanceof Error ? error.message : String(error)}`)
  console.error('[dsh-browser4] manual steps: see skills/browser4-cli/SKILL.md -> Installation')
  process.exit(1)
}
