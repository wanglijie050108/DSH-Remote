#!/usr/bin/env node
// E1 —— 大响应字节保真（01 §1 DoD / §8）
// 靶子：组合 URL `/plugins/??<id1>/client.js,<id2>/client.js,…`（单个最大 620160B；48 个 ≈3.62MiB，01 §1）
// 两腿 MUST 固定同一个 Accept-Encoding（web profile 已开 compression: gzip，协商不同会假失败 —— F20）
// 用法：node scripts/e1-byte-fidelity.mjs --direct http://127.0.0.1:3080 --tunnel http://127.0.0.1:13080 --path "/plugins/??id1/client.js,id2/client.js"
import { createHash } from 'node:crypto'

const args = process.argv.slice(2)
const argOf = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d }
const direct = argOf('direct')
const tunnel = argOf('tunnel')
const path = argOf('path')
const enc = argOf('enc', 'identity') // 两腿固定同一 Accept-Encoding；identity 规避压缩，gzip 亦可
if (!direct || !tunnel || !path) { console.error('usage: e1-byte-fidelity.mjs --direct URL --tunnel URL --path "/plugins/??…"'); process.exit(1) }

async function fetchSha(base) {
  const res = await fetch(base + path, { headers: { 'Accept-Encoding': enc } })
  const body = Buffer.from(await res.arrayBuffer())
  return { status: res.status, len: body.length, sha256: createHash('sha256').update(body).digest('hex'), cenc: res.headers.get('content-encoding') }
}

const [a, b] = await Promise.all([fetchSha(direct), fetchSha(tunnel)])
console.log('direct :', a.status, a.len, 'B  sha256=' + a.sha256, 'cenc=' + a.cenc)
console.log('tunnel :', b.status, b.len, 'B  sha256=' + b.sha256, 'cenc=' + b.cenc)
const ok = a.status === b.status && a.len === b.len && a.sha256 === b.sha256 && a.cenc === b.cenc
console.log(ok ? 'E1 PASS' : 'E1 FAIL（len/sha256/content-encoding 不一致）')
process.exit(ok ? 0 : 1)
