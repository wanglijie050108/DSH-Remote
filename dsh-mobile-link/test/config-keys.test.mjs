// 装配期 fail-fast 矩阵（01 §2.1 / §7）与身份密钥持久化（01 §4.1）
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loadConfig, ConfigError, SELF_RESCUE } from '../lib/config.js'
import { loadIdentity, createDtlsCertificate, KeysError, dshHome } from '../lib/keys.js'

const baseEnv = { DSML_SIGNAL_URL: 'bridge.example.com' }

test('config: ok case derives forward target from webServer.port', () => {
  const cfg = loadConfig(baseEnv, 3456)
  assert.equal(cfg.signalUrl, 'bridge.example.com')
  assert.equal(cfg.authority, '127.0.0.1:13080')
  assert.equal(cfg.forwardTarget, '127.0.0.1:3456') // ★ 用真实端口，不用 webServer.host（陷阱）
})

test('config: fail-fast matrix', () => {
  // 未设置 SIGNAL_URL
  assert.throws(() => loadConfig({}, null), (e) => e instanceof ConfigError && e.message.includes('DSML_SIGNAL_URL'))
  // 写成了完整端点（§7 的拼错形态）
  assert.throws(() => loadConfig({ DSML_SIGNAL_URL: 'wss://bridge.example.com/v1/signal' }, null), ConfigError)
  // authority ≠ 契约固定值
  assert.throws(() => loadConfig({ ...baseEnv, DSML_AUTHORITY: '127.0.0.1:9999' }, null), (e) => e.message.includes('127.0.0.1:13080'))
  // forward target 形态错误（非 IPv4:port）
  assert.throws(() => loadConfig({ ...baseEnv, DSML_FORWARD_TARGET: 'localhost:3080' }, null), ConfigError)
  // 显式 ws:// 允许（05 §0.1 开发期）；带路径则不允许
  assert.equal(loadConfig({ DSML_SIGNAL_URL: 'ws://127.0.0.1:8080' }, 1).signalScheme, 'ws://')
  assert.throws(() => loadConfig({ DSML_SIGNAL_URL: 'ws://127.0.0.1:8080/v1' }, null), ConfigError)
  // 每条报错自带自救指引（§2.1）
  try { loadConfig({}, null) } catch (e) { assert.ok(e.message.includes('disabled: true')) }
})

test('keys: generate → persist → reload → 同一身份与稳定指纹（§6）', (t) => {
  const home = mkdtempSync(join(tmpdir(), 'dsml-'))
  t.after(() => rmSync(home, { recursive: true, force: true }))
  const env = { DSH_HOME: home }
  const a = loadIdentity(env)
  assert.ok(a.privPem.includes('BEGIN PRIVATE KEY'))
  assert.ok(a.dtls.certPem.includes('BEGIN CERTIFICATE'))
  const b = loadIdentity(env) // 重启（再次载入）：不重新生成、指纹稳定
  assert.equal(b.pubB64u, a.pubB64u)
  assert.equal(b.dtls.certPem, a.dtls.certPem)
  const { fp: fp1 } = createDtlsCertificate(a)
  const { fp: fp2 } = createDtlsCertificate(b)
  assert.equal(fp1, fp2, '整证书持久化 → 指纹全生命周期稳定（skill §3.1）')
  assert.match(fp1, /^[0-9A-F]{2}(:[0-9A-F]{2}){31}$/)
  // 文件确实写在 $DSH_HOME/mobile-link/
  assert.ok(dshHome(env).includes(home))
  assert.ok(readFileSync(join(home, 'mobile-link', 'identity.json'), 'utf8').includes('privPem'))
})

test('keys: corrupted identity → KeysError（fail-fast 带恢复指引）', (t) => {
  const home = mkdtempSync(join(tmpdir(), 'dsml-'))
  t.after(() => rmSync(home, { recursive: true, force: true }))
  const env = { DSH_HOME: home }
  loadIdentity(env) // 先生成
  writeFileSync(join(home, 'mobile-link', 'identity.json'), '{ broken json')
  assert.throws(() => loadIdentity(env), (e) => e instanceof KeysError && e.message.includes('恢复方式'))
  // 字段缺失形态
  writeFileSync(join(home, 'mobile-link', 'identity.json'), JSON.stringify({ privPem: 'x' }))
  assert.throws(() => loadIdentity(env), KeysError)
})
