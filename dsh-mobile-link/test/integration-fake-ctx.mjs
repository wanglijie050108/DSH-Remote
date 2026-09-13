// 集成测试（E10 雏形）：真实插件代码 + fake DSH ctx + fake-bridge + fake-phone → 隧道回环
// 运行：node test/integration-fake-ctx.mjs（约 25s）
// 覆盖 01 §1 DoD：装配成功 → QR（pair.ready.ok 后）→ 扫码 → 隧道 → 字节回环；
// boot_id 免扫码恢复由 fake-phone resume / fake-bridge 组合在 S2 冒烟中已验证。
import net from 'node:net'
import { once } from 'node:events'
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const CONTRACT = join(ROOT, '..', 'remotedsh-contract')
const env = {
  ...process.env,
  DSML_SIGNAL_URL: '127.0.0.1',
  DSH_HOME: mkdtempSync(join(tmpdir(), 'dsml-e2e-')),
}
const PORT_BRIDGE = 18090
env.DSML_SIGNAL_URL = `ws://127.0.0.1:${PORT_BRIDGE}` // fake-bridge 是明文 ws（开发期形态，05 §0.1）

// 1. echo 目标（模拟 DSH 端口）
const echo = net.createServer((s) => { s.on('data', (d) => s.write(d)); s.on('error', () => {}) })
echo.listen(0, '127.0.0.1')
await once(echo, 'listening')
const echoPort = echo.address().port

// 2. fake-bridge
const bridge = spawn('node', [join(CONTRACT, 'tools', 'fake-bridge.mjs'), '--port', String(PORT_BRIDGE)], { stdio: 'pipe' })
await new Promise((r) => setTimeout(r, 1200))

// 3. fake DSH ctx + 真实插件 apply()
const captured = []
const origLog = console.log
console.log = (...a) => { captured.push(a.map(String).join(' ')); origLog(...a) }
const ctx = {
  webServer: { port: echoPort }, // ★ 装配取真实端口（陷阱断言：webServer.host 可能是 0.0.0.0）
  connection: { authenticatedUrl: (base) => `${base}?token=fake-launch-token-123` },
  listeners: {},
  on(event, fn) { this.listeners[event] = fn },
  effect(_setup, label) { ctx._dispose = null; return () => {} }, // 本测试不测 dispose；真实清理路径由单测+§2.2 评审覆盖
}
process.env.DSML_SIGNAL_URL = env.DSML_SIGNAL_URL
process.env.DSH_HOME = env.DSH_HOME
const { apply } = await import(pathToFileURL(join(ROOT, 'lib', 'index.js')).href + `?e2e=${Date.now()}`)
const handle = apply(ctx)
origLog('plugin applied:', handle)

// 4. 从控制台输出提取 QR URI（等 pair.ready.ok → printQr）
let qrUri = null
for (let i = 0; i < 40 && !qrUri; i++) {
  await new Promise((r) => setTimeout(r, 500))
  qrUri = captured.join('\n').match(/dshlink:\/\/pair\?\S+/)?.[0] ?? null
}
if (!qrUri) { origLog('E2E FAIL: QR 未打印'); process.exit(1) }
origLog('QR captured:', qrUri.slice(0, 64) + '…')

// 5. fake-phone 扫码
const phone = spawn('node', [join(CONTRACT, 'tools', 'fake-phone.mjs'), 'scan', '--name', 'intg', '--qr', qrUri, '--proxy', '13080'], {
  stdio: 'pipe', cwd: CONTRACT,
})
const phoneLog = []
phone.stdout.on('data', (d) => phoneLog.push(d.toString()))
phone.stderr.on('data', (d) => phoneLog.push(d.toString()))

// 6. 等 TUNNEL READY → 经 13080 回环
let ready = false
for (let i = 0; i < 60 && !ready; i++) {
  await new Promise((r) => setTimeout(r, 1000))
  ready = phoneLog.join('').includes('TUNNEL READY')
}
if (!ready) {
  origLog('E2E FAIL: TUNNEL READY 未出现\nphone log:\n' + phoneLog.join(''))
  process.exit(1)
}

const result = await new Promise((resolve) => {
  const s = net.connect(13080, '127.0.0.1')
  let got = ''
  s.on('data', (d) => {
    got += d.toString()
    if (got === 'INTEGRATION-OK') { s.destroy(); resolve(true) }
  })
  s.on('connect', () => s.write('INTEGRATION-OK'))
  s.on('error', (e) => resolve(false))
  setTimeout(() => resolve(false), 10000)
})

console.log = origLog
if (!result) origLog('phone log tail:\n' + phoneLog.join('').split('\n').slice(-25).join('\n'))
phone.kill()
bridge.kill()
echo.close()
rmSync(env.DSH_HOME, { recursive: true, force: true })
console.log(result ? 'INTEGRATION E2E: PASS' : 'INTEGRATION E2E: FAIL')
process.exit(result ? 0 : 1)
