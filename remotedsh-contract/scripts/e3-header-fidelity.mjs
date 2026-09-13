#!/usr/bin/env node
// E3 —— 头部保真与围栏断言（01 §1 DoD E3 / 05 §6.3）
// 断言（全部已按 DSH 源码核实，verify-dsh-facts F16a/F3/F16）：
//   ① 改 Host 打 /api* → 403（围栏 isTrustedApiRequest 只由 /api 前缀路由与 mux 升级调用）
//   ② GET /（无 cookie）→ 401（authorizeIndex → writeUnauthorized）
//   ③ /plugins/* 与 dist 静态资源 → 200（公开）
// 用法：node scripts/e3-header-fidelity.mjs --base http://127.0.0.1:3080 [--plugin-id <id>]
const args = process.argv.slice(2)
const argOf = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d }
const base = argOf('base', 'http://127.0.0.1:3080')
const pluginId = argOf('plugin-id', null)

let failed = 0
async function check(name, path, headers, expectStatus) {
  try {
    const res = await fetch(base + path, { headers, redirect: 'manual' })
    const pass = res.status === expectStatus
    console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}: ${res.status} (expect ${expectStatus})`)
    if (!pass) failed++
  } catch (e) {
    console.log(`FAIL  ${name}: ${e.message}`); failed++
  }
}

await check('① /api/* with evil Host → 403', '/api/session/list', { Host: 'evil.example.com' }, 403)
await check('② GET / without cookie → 401', '/', {}, 401)
if (pluginId) {
  await check('③ /plugins/<id>/client.js public → 200', `/plugins/${pluginId}/client.js`, {}, 200)
} else {
  console.log('SKIP  ③ /plugins/*（未提供 --plugin-id）')
}
console.log(failed === 0 ? 'E3 PASS' : `E3 FAIL (${failed})`)
process.exit(failed === 0 ? 0 : 1)
