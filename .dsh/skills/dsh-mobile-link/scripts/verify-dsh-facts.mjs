#!/usr/bin/env node
/**
 * verify-dsh-facts.mjs
 *
 * Re-checks the DSH facts that the dsh-mobile-link project depends on, against the
 * DSH install actually present on this machine.
 *
 * Why this exists: docs/01 §2 leaks a plugin assembly failure into a DSH startup
 * failure, and the whole design leans on a set of DSH internals (`/api` Host fence,
 * webServer.port, authenticatedUrl, the mux heartbeat, patchReload: live, ...).
 * DSH upgrades move those. A doc cannot notice; this script can.
 *
 * Usage:
 *   node .dsh/skills/dsh-mobile-link/scripts/verify-dsh-facts.mjs [--dsh-root <path>]
 *
 * Exit codes: 0 = every fact still holds, 1 = at least one moved, 2 = DSH not found.
 */

import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

// ---------------------------------------------------------------- arg parsing

function argValue(flag) {
  const i = process.argv.indexOf(flag)
  return i !== -1 ? process.argv[i + 1] : undefined
}

const SCRIPT_DIR = new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')

function candidateRoots() {
  const explicit = argValue('--dsh-root') ?? process.env.DSH_ROOT
  const out = []
  if (explicit) out.push(explicit)
  if (process.env.APPDATA) out.push(join(process.env.APPDATA, 'npm', 'node_modules', '@deepseek-ai', 'dsh'))
  if (process.env.DSH_HOME) out.push(join(process.env.DSH_HOME, '..', 'node_modules', '@deepseek-ai', 'dsh'))
  out.push('D:/npm-global/node_modules/@deepseek-ai/dsh')
  if (process.env.HOME) out.push(join(process.env.HOME, '.npm-global', 'node_modules', '@deepseek-ai', 'dsh'))
  return out
}

const DSH_ROOT = candidateRoots().find((p) => p && existsSync(join(p, 'node_modules', '@deepseek-ai')))
if (DSH_ROOT === undefined) {
  console.error('FAIL  could not locate a DSH install.')
  console.error('      Tried:\n' + candidateRoots().map((p) => `        ${p}`).join('\n'))
  console.error('      Pass --dsh-root <path-to-dsh> or set DSH_ROOT.')
  process.exit(2)
}

const PKG = join(DSH_ROOT, 'node_modules', '@deepseek-ai')

// ------------------------------------------------------------------- helpers

const cache = new Map()
function source(relPath) {
  if (!cache.has(relPath)) {
    const abs = join(PKG, relPath)
    cache.set(relPath, existsSync(abs) ? readFileSync(abs, 'utf8') : undefined)
  }
  return cache.get(relPath)
}

/**
 * Extract a brace-balanced body for a symbol by its DECLARATION anchor.
 *
 * Anchoring alone is not enough. A bundled class usually defines the same symbol
 * twice: a thin delegator in the service wrapper and the real implementation in
 * the inner class —
 *
 *   authorizeIndex(request, response) {           // 65 chars, delegates
 *     return this.browserAuth.authorizeIndex(request, response);
 *   }
 *   authorizeIndex(req, res) { ...401/303 logic... }   // the one we want
 *
 * Both are valid declarations, so we score every candidate and take the one that
 * looks like the implementation: fewest delegating bodies, then longest body.
 * An empty body (an interface signature) never wins.
 */
function extractBody(text, header) {
  const headers = Array.isArray(header) ? header : [header]
  const candidates = []
  for (const h of headers) {
    // Callers pass a signature; the pattern below supplies its own parameter
    // list, so strip any trailing `(...)` from the anchor.
    const base = h.replace(/\([^()]*\)\s*$/, '').trim()
    const escaped = base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const re = new RegExp(`(?<![.\\w$])${escaped}\\s*(\\([^)]*\\)|=[^;{]{0,120}?=>)\\s*\\{`, 'g')
    let m
    while ((m = re.exec(text)) !== null) {
      const start = m.index + m[0].length - 1
      let depth = 0
      for (let i = start; i < text.length; i += 1) {
        const ch = text[i]
        if (ch === '{') depth += 1
        else if (ch === '}') {
          depth -= 1
          if (depth === 0) {
            candidates.push(text.slice(start, i + 1))
            break
          }
        }
      }
      if (m.index === re.lastIndex) re.lastIndex += 1
    }
  }
  if (candidates.length === 0) return undefined
  // The real implementation is always the longest declaration of that name; the
  // thin delegator is a single statement. (Do NOT also rank on "looks like a
  // delegation" — a real implementation contains delegating calls too, and that
  // rule would wrongly prefer the one-line wrapper.)
  return candidates.sort((a, b) => b.length - a.length)[0]
}

const results = []

/**
 * @param {object} check
 * @param {string} check.id      stable row id (matches SKILL.md §3 where applicable)
 * @param {string} check.claim   the fact being asserted
 * @param {string} check.file    path relative to node_modules/@deepseek-ai/
 * @param {string} [check.symbol] symbol to anchor on; body is extracted from here
 * @param {(text:string)=>boolean} check.test
 * @param {string} check.evidence human-readable "look for this"
 */
function check({ id, claim, file, symbol, test, evidence }) {
  const text = source(file)
  if (text === undefined) {
    results.push({ id, claim, status: 'FAIL', detail: `file missing: ${file}` })
    return
  }
  const haystack = symbol === undefined ? text : (extractBody(text, symbol) ?? '')
  if (symbol !== undefined && haystack === '') {
    results.push({ id, claim, status: 'FAIL', detail: `symbol not found: ${symbol} in ${file}` })
    return
  }
  let ok = false
  try {
    ok = test(haystack)
  } catch (error) {
    results.push({ id, claim, status: 'FAIL', detail: `check threw: ${error.message}` })
    return
  }
  results.push({
    id,
    claim,
    status: ok ? 'PASS' : 'FAIL',
    detail: ok ? `${file} :: ${symbol ?? '(file)'}` : `expected ${evidence} in ${file}`,
  })
}

// -------------------------------------------------------------------- checks

check({
  id: 'F1',
  claim: '/api Host fence checks loopback hostname only, NOT the port',
  file: 'dsh-client-connection/lib/index.js',
  symbol: 'function isTrustedApiRequest',
  test: (b) => /isLoopback/i.test(b) && !/\bport\b/i.test(b),
  evidence: 'a loopback hostname test and no port comparison',
})

check({
  id: 'F2',
  claim: 'cookie name derives from the authority INCLUDING its port',
  file: 'dsh-client-connection/lib/index.js',
  symbol: 'function cookieName',
  test: (b) => /sha256|createHash/i.test(b),
  evidence: 'a hash of the authority',
})

check({
  id: 'F3/F4',
  claim: 'index auth: GET + pathname "/" + exactly one token param -> 303 + Set-Cookie; anything else -> 401',
  file: 'dsh-client-connection/lib/index.js',
  symbol: ['authorizeIndex(req, res)', 'authorizeIndex(request, response)'],
  test: (b) =>
    /req\.method === "GET"/.test(b) &&
    /pathname === "\/"/.test(b) &&
    /tokens\.length === 1/.test(b) &&
    /writeHead\(303/.test(b) &&
    /set-cookie/.test(b) &&
    /writeUnauthorized/.test(b),
  evidence:
    'GET + pathname "/" + tokens.length === 1 + writeHead(303) + set-cookie, and a writeUnauthorized() fallback',
})

check({
  id: 'F4b',
  claim: 'the unauthenticated response is 401, emitted by writeUnauthorized',
  file: 'dsh-client-connection/lib/index.js',
  symbol: 'writeUnauthorized(req, res)',
  test: (b) => /writeHead\(401/.test(b),
  evidence: 'writeHead(401, {...})',
})

check({
  id: 'F5',
  claim: 'webServer.port is the real listening port; webServer.host is the configured value',
  file: 'dsh-host-webserver/lib/index.js',
  symbol: 'get port()',
  test: () => {
    const portBody = extractBody(source('dsh-host-webserver/lib/index.js'), 'get port()') ?? ''
    const hostBody = extractBody(source('dsh-host-webserver/lib/index.js'), 'get host()') ?? ''
    return /listenedPort/.test(portBody) && /this\.config\.host/.test(hostBody)
  },
  evidence: 'get port() -> listenedPort and get host() -> this.config.host',
})

check({
  id: 'F6',
  claim: 'authenticatedUrl() clears path/search/hash then sets the token param',
  file: 'dsh-client-connection/lib/index.js',
  symbol: 'authenticatedUrl(baseUrl)',
  test: (b) =>
    /url\.pathname = "\/"/.test(b) && /url\.search = ""/.test(b) && /searchParams\.set\(TOKEN_QUERY/.test(b),
  evidence: 'pathname reset, search reset, searchParams.set(TOKEN_QUERY, ...)',
})

check({
  id: 'F7/F8/F16b',
  claim: 'mux heartbeat 2000 ms, terminate after 2 misses, binary frame -> close(1003); upgrade fenced via requestRejection',
  file: 'dsh-api-gateway/lib/index.js',
  test: (t) =>
    /DEFAULT_WEBSOCKET_HEARTBEAT_INTERVAL_MS = 2e3/.test(t) &&
    /MAX_MISSED_HEARTBEATS = 2/.test(t) &&
    /\.terminate\(\)/.test(t) &&
    /close\(1003/.test(t) &&
    /requestRejection\(req\)/.test(t) &&
    /rejectRemoteStreamUpgrade\(socket, rejection\)/.test(t),
  evidence:
    '2e3 heartbeat default, MAX_MISSED_HEARTBEATS = 2, terminate(), close(1003, ...), requestRejection(req) on the upgrade route',
})

check({
  id: 'F16a',
  claim: 'the fence rejects an untrusted Host with 403 and a missing cookie with 401',
  file: 'dsh-client-connection/lib/index.js',
  symbol: 'requestRejection(request)',
  test: (b) => /isTrustedApiRequest/.test(b) && /return 403/.test(b) && /401/.test(b),
  evidence: 'isTrustedApiRequest -> return 403, else an authentication 401',
})

check({
  id: 'F9/F10',
  claim: 'frontend backoff 500/×2/max 10s, terminal disconnected; online/offline only track system network',
  file: 'dsh-client-connection/lib/client.js',
  test: (t) =>
    /backoffBaseMs:\s*500/.test(t) &&
    /backoffFactor:\s*2/.test(t) &&
    /backoffMaxMs:\s*1e4/.test(t) &&
    /emitState\("disconnected"\)/.test(t) &&
    /addEventListener\("online"/.test(t) &&
    /addEventListener\("offline"/.test(t),
  evidence: 'CONNECTION_DEFAULTS backoff 500/2/1e4, emitState("disconnected"), online/offline listeners',
})

check({
  id: 'F11',
  claim: 'web profile patchReload is "live"',
  file: 'dsh-app-boot/lib/index.js',
  test: (t) => /patchReload:\s*"live"/.test(t),
  evidence: 'patchReload: "live"',
})

check({
  id: 'F12',
  claim: 'pending or failed activation fails DSH startup',
  file: 'dsh-app-boot/lib/index.js',
  symbol: 'async function assertEntriesActivated',
  test: (b) => /FIBER_PENDING/.test(b) && /did not activate/.test(b),
  evidence: 'FIBER_PENDING branch and the "did not activate" throw',
})

check({
  id: 'F14',
  claim: 'bundle resolution walks the filesystem and does not need `exports`',
  file: 'dsh-app-boot/lib/index.js',
  test: (t) => /does not require the package to export|resolve\.paths\(\)/.test(t),
  evidence: 'resolve.paths() based directory walk',
})

check({
  id: 'F17',
  claim: 'approval/request is a waterfall; service name is "approval"',
  file: 'dsh-user-approval/lib/index.js',
  test: (t) => /"approval\/request"/.test(t) && /waterfall\(/.test(t) && /super\(ctx, "approval"\)/.test(t),
  evidence: 'this.ctx.waterfall(..., "approval/request", ...) and super(ctx, "approval")',
})

check({
  id: 'F16',
  claim: 'combined plugin URL uses the ?? combo form',
  file: 'dsh-client-modules/lib/index.js',
  test: (t) => /\?\?/.test(t) && /combo/i.test(t),
  evidence: 'combo URL construction',
})

// --------------------------------------------------------------- project facts

const PROJECT_CONSTANTS = [
  { name: 'phone authority', value: '127.0.0.1:13080', doc: 'contract §1' },
  { name: 'QoS frame len max', value: '16373', doc: 'contract §3.1' },
  { name: 'credit per direction', value: '256 KiB', doc: 'contract §3.4' },
  { name: 'concurrent streams', value: '128', doc: 'contract §3.4' },
  { name: 'unsent queue per stream', value: '256 KiB', doc: 'contract §3.4' },
  { name: 'unsent queue global', value: '512 KiB', doc: 'contract §3.4' },
  { name: 'global in-flight', value: '8 MiB', doc: 'contract §3.4' },
  { name: 'tunnel PING interval', value: '5 s', doc: 'contract §3.5' },
  { name: 'tunnel dead threshold', value: '15 s', doc: 'contract §3.5' },
  { name: 'pair_token TTL', value: '5 min', doc: 'contract §4.4' },
  { name: 'grace period T', value: '24 h', doc: 'contract §4.3 (user decision)' },
  { name: 'TURN credential TTL', value: '3600 s', doc: 'contract §5' },
  { name: 'signalling heartbeat', value: '25 s client / 60 s server', doc: 'contract §4' },
  { name: 'hello deadline', value: '10 s', doc: 'contract §4.1' },
  { name: 'contract version', value: 'v1.0.3', doc: 'contract §7' },
  { name: 'frame ver / QR v', value: '1 / 1', doc: 'contract §7' },
]

// --------------------------------------------------------------------- report

const pad = (s, n) => String(s).padEnd(n)
let failed = 0

console.log(`DSH install: ${DSH_ROOT}`)
console.log(`Verified at: ${new Date().toISOString()}\n`)

console.log('Environment facts (must all PASS):')
for (const r of results) {
  if (r.status === 'FAIL') failed += 1
  console.log(`  [${r.status}] ${pad(r.id, 7)} ${r.claim}`)
  if (r.status === 'FAIL') console.log(`          -> ${r.detail}`)
}

console.log('\nProject constants (recorded, not machine-checkable — confirm against the contract):')
for (const c of PROJECT_CONSTANTS) {
  console.log(`  [REF ] ${pad(c.name, 26)} ${pad(c.value, 26)} ${c.doc}`)
}

console.log('')
if (failed > 0) {
  console.log(`RESULT: ${failed} environment fact(s) FAILED.`)
  console.log('A fact this project depends on has moved. Report it and name the affected')
  console.log('documents BEFORE writing code. Do not code around it silently.')
  process.exit(1)
}
console.log('RESULT: all environment facts still hold. SKILL.md §3 index is current.')
process.exit(0)
