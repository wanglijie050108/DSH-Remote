// 插件 hello 签名 vs 共享向量（契约 §4.2，01 §8）；boot_id 进程级稳定性（§2.3，05 风险 8 的单测）
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { createPrivateKey, createPublicKey } from 'node:crypto'
import { canonicalHelloBytes, signHelloBytes } from '../lib/bridge.js'
import { processBootId } from '../lib/index.js'

const VECTORS = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'remotedsh-contract', 'vectors')
const load = (f) => JSON.parse(readFileSync(join(VECTORS, f), 'utf8'))

test('plugin hello: canonical bytes byte-exact (G2)', () => {
  const v = load('hello-signature.json')
  for (const c of v.cases.filter(x => x.expected_msg_hex)) {
    assert.equal(canonicalHelloBytes(c.ts, c.nonce).toString('hex'), c.expected_msg_hex, c.name)
  }
})

test('plugin hello: own signatures verify against vector pub (DER)', () => {
  const v = load('hello-signature.json')
  const priv = createPrivateKey(v._meta.private_key_pkcs8_pem)
  const pub = createPublicKey(priv)
  for (const c of v.cases.filter(x => x.expect_verify)) {
    const sig = signHelloBytes(priv, c.ts, c.nonce) // Node 默认 DER 输出（§4.2 禁 P1363 满足）
    const der = Buffer.from(sig, 'base64url')
    assert.equal(der[0], 0x30, 'SEQUENCE tag')
    assert.ok(der.length <= 72)
    // 用 contract js 的 verifyHello 交叉验证
    import('../../remotedsh-contract/js/hello.mjs').then(({ verifyHello }) => {
      assert.equal(verifyHello(pub, c.ts, c.nonce, sig), true, c.name)
    })
  }
})

test('plugin boot_id: process-level across module reloads (热重载不变，05 风险 8)', async () => {
  const a = processBootId()
  // 模拟 live 热重载：重新 import index.js（模块缓存保留 globalThis 键 → 同一进程内 boot_id 不变）
  const mod = await import('../lib/index.js?hot-reload-sim=' + Math.random())
  const b = mod.processBootId()
  assert.equal(a, b, 'boot_id MUST be process-level（§2.3）')
  assert.ok(a.startsWith('boot-'))
})
