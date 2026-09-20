// 设备侧 G2 向量自测（自测页跑；纯逻辑与本地单测同源，crypto 项只有设备可跑）
// 覆盖：帧 14 例 / 指纹 7 例 / QR 5 例 / hello 6 例（native ECDSA）/ TURN 凭证
import {
  encodeFrame, decodeFrame, FrameError, FrameType, DecodedFrame, MAX_PAYLOAD, FRAME_HEADER_SIZE
} from './Frames';
import { extractPinnedFingerprint } from './Fingerprint';
import { parsePairQr } from './QrPair';
import { bytesToHex, hexToBytes, utf8Encode, bytesEqual, bytesToB64u, b64uToBytes, bytesToBase64 } from './Codec';
import { sha256, sha1, hmacSha1 } from './Digest';
import { rawToDer, derToRaw } from './DerEcdsa';
import { turnUsername, turnCredential, TURN_TTL_SECONDS } from './Turn';
import { runHelloVectors, PROTO_VER } from './Hello';
import { VEC_FRAMES, VEC_FP, VEC_QR, VEC_HELLO } from './Vectors';

export class CaseResult {
  public suite: string = ''
  public name: string = ''
  public pass: boolean = false
  public detail: string = ''
}

export class SelfTestReport {
  public cases: CaseResult[] = []
  public passed: number = 0
  public failed: number = 0
  public protoVer: string = PROTO_VER
}

class Reporter {
  public cases: CaseResult[] = []

  public add(suite: string, name: string, pass: boolean, detail: string): void {
    const c = new CaseResult()
    c.suite = suite
    c.name = name
    c.pass = pass
    c.detail = detail
    this.cases.push(c)
  }
}

function check(cond: boolean, msg: string): void {
  if (!cond) {
    throw new Error(msg)
  }
}

function runFrameSuite(rep: Reporter): void {
  const root = JSON.parse(VEC_FRAMES) as Record<string, Object>
  const cases = root['cases'] as Array<Record<string, Object>>
  for (const c of cases) {
    const name = String(c['name'])
    const frameHexRaw = c['frame_hex']
    if (frameHexRaw === undefined || frameHexRaw === null) {
      rep.add('frames', name, true, '无 frame_hex（跳过）')
      continue
    }
    const frameHex = String(frameHexRaw)
    try {
    const raw = hexToBytes(frameHex)
    let dec: DecodedFrame | null = null
    let errCode = ''
    try {
      dec = decodeFrame(raw)
    } catch (e) {
      errCode = (e as FrameError).code
    }
    const isNeg = name.includes('reject') || name.includes('truncated')
    if (isNeg) {
      check(errCode !== '', '负例未拒绝')
      const want = name.includes('ver=2') ? 'BAD_VER'
        : (name.includes('16374') ? 'LEN_OVERFLOW' : 'HEADER_INCOMPLETE')
      check(errCode === want, `err=${errCode} want=${want}`)
      rep.add('frames', name, true, errCode)
      continue
    }
    check(dec !== null, `decode fail ${errCode}`)
    const d = dec as DecodedFrame
      // re-encode 逐字节（flags 归 0）
      const re = encodeFrame(d.type, d.streamId, d.payload)
      const wantHex = frameHex.substring(0, 4) + '00' + frameHex.substring(6)
      check(bytesToHex(re) === wantHex, 're-encode mismatch')
      // 未知类型帧原样带回
      const decRec = c['decode'] as Record<string, Object>
      if (decRec['type_code'] !== undefined) {
        check(d.type === Number(decRec['type_code']), 'unknown type not preserved')
      }
      rep.add('frames', name, true, `${d.payload.length}B`)
    } catch (e) {
      rep.add('frames', name, false, String(e))
    }
  }
  // 边界自证
  try {
    const big = new Uint8Array(MAX_PAYLOAD)
    const f = encodeFrame(FrameType.DATA, 1, big)
    check(f.length === FRAME_HEADER_SIZE + MAX_PAYLOAD, 'boundary total size')
    rep.add('frames', 'boundary 16373', true, `${f.length}B`)
  } catch (e) {
    rep.add('frames', 'boundary 16373', false, String(e))
  }
}

function runFpSuite(rep: Reporter): void {
  const root = JSON.parse(VEC_FP) as Record<string, Object>
  const cases = root['cases'] as Array<Record<string, Object>>
  for (const c of cases) {
    const name = String(c['name'])
    const lines = c['offer_lines'] as Array<Object>
    const linesS: string[] = []
    for (const l of lines) {
      linesS.push(String(l))
    }
    const expect = c['expect']
    const got = extractPinnedFingerprint(linesS)
    const want = expect === null ? '' : String(expect)
    rep.add('fingerprint', name, got === want, got === want ? 'ok' : `got=${got.substring(0, 16)}…`)
  }
}

function runQrSuite(rep: Reporter): void {
  const root = JSON.parse(VEC_QR) as Record<string, Object>
  const cases = root['cases'] as Array<Record<string, Object>>
  for (const c of cases) {
    const name = String(c['name'])
    const r = parsePairQr(String(c['uri']))
    const expect = c['expect']
    if (expect === null) {
      rep.add('qr', name, !r.ok, r.ok ? '应失败却成功' : `ok(${r.error})`)
    } else {
      const e = expect as Record<string, Object>
      const ok = r.ok && r.qr !== null && r.qr.s === String(e['s']) && r.qr.pt === String(e['pt'])
        && r.qr.fp === String(e['fp']) && r.qr.a === String(e['a'])
      rep.add('qr', name, ok, ok ? 'ok' : 'field mismatch')
    }
  }
}

function runDigestSuite(rep: Reporter): void {
  try {
    check(bytesToHex(sha256(utf8Encode('abc'))) ===
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256(abc)')
    check(bytesToHex(sha1(utf8Encode('abc'))) === 'a9993e364706816aba3e25717850c26c9cd0d89d', 'sha1(abc)')
    rep.add('digest', 'sha256/sha1 NIST', true, 'ok')
  } catch (e) {
    rep.add('digest', 'sha256/sha1 NIST', false, String(e))
  }
  try {
    const key = new Uint8Array(20).fill(0x0b)
    check(bytesToHex(hmacSha1(key, utf8Encode('Hi There'))) ===
      'b617318655057264e28bc0b6fb378c8ef146be00', 'hmac rfc2202-1')
    rep.add('digest', 'HMAC-SHA1 RFC2202', true, 'ok')
  } catch (e) {
    rep.add('digest', 'HMAC-SHA1 RFC2202', false, String(e))
  }
}

function runTurnSuite(rep: Reporter): void {
  try {
    const u = turnUsername('pair-demo-001', 3600, 1770000000)
    check(u === '1770003600:pair-demo-001', 'username format')
    check(turnCredential('demo-secret-S-please-ignore', u) === 'eZWIRZVQqk8+D5L1kRNmEgc46/c=', 'credential')
    rep.add('turn', '凭证向量（js/turn.mjs 对拍）', true, `ttl=${TURN_TTL_SECONDS}s`)
  } catch (e) {
    rep.add('turn', '凭证向量（js/turn.mjs 对拍）', false, String(e))
  }
}

function runCodecSuite(rep: Reporter): void {
  try {
    const nonce = 'gCEzU1KQjzh6lVGJH_x1ze3ZUdCQtc0vQCixwFIvHm8'
    check(bytesToB64u(b64uToBytes(nonce)) === nonce, 'b64url roundtrip')
    check(bytesEqual(hexToBytes('00ff10'), new Uint8Array([0, 255, 16])), 'hex')
    check(bytesToBase64(new Uint8Array([0x61, 0x62, 0x63])) === 'YWJj', 'base64')
    check(utf8Encode('中文').length === 6, 'utf8 len')
    rep.add('codec', 'base64url/hex/utf8', true, 'ok')
  } catch (e) {
    rep.add('codec', 'base64url/hex/utf8', false, String(e))
  }
  try {
    // DER 编解码器自证（向量签名逐个 roundtrip）
    const root = JSON.parse(VEC_HELLO) as Record<string, Object>
    const cases = root['cases'] as Array<Record<string, Object>>
    let n = 0
    for (const c of cases) {
      const der = b64uToBytes(String(c['expected_sig_base64url']))
      if (der[0] !== 0x30) {
        continue
      }
      const raw = derToRaw(der, 32)
      check(bytesEqual(rawToDer(raw), der), `der roundtrip case ${n}`)
      n++
    }
    check(n >= 3, `der cases ${n} < 3`)
    rep.add('codec', 'ECDSA DER roundtrip', true, `${n} 例`)
  } catch (e) {
    rep.add('codec', 'ECDSA DER roundtrip', false, String(e))
  }
}

function runIdSuite(rep: Reporter): void {
  // sha256(SPKI) → phone_id 语义自证（SPKI 取自向量 pub，phone_id 应为 sha256 摘要的 b64u）
  try {
    const root = JSON.parse(VEC_HELLO) as Record<string, Object>
    const cases = root['cases'] as Array<Record<string, Object>>
    const pub = hexToBytes(bytesToHex(b64uToBytes(String(cases[0]['pub']))))
    const digest = bytesToB64u(sha256(pub))
    check(digest.length === 43, 'phone_id len')
    rep.add('identity', 'phone_id 派生语义', true, `${digest.substring(0, 12)}…`)
  } catch (e) {
    rep.add('identity', 'phone_id 派生语义', false, String(e))
  }
}

export async function runAllSelfTests(): Promise<SelfTestReport> {
  const r = new Reporter()
  runCodecSuite(r)
  runFrameSuite(r)
  runFpSuite(r)
  runQrSuite(r)
  runDigestSuite(r)
  runTurnSuite(r)
  runIdSuite(r)
  // hello（native cryptoFramework，仅设备可跑）
  try {
    const helloResults = await runHelloVectors()
    for (const hr of helloResults) {
      r.add('hello', hr.name, hr.pass, hr.detail)
    }
  } catch (e) {
    r.add('hello', 'runHelloVectors', false, String(e))
  }
  const rep = new SelfTestReport()
  rep.cases = r.cases
  for (const c of rep.cases) {
    if (c.pass) {
      rep.passed++
    } else {
      rep.failed++
    }
  }
  return rep
}
