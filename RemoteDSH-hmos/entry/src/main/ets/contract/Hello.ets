// hello 规范化与签名 ArkTS port（契约 §4.1/§4.2，对齐 remotedsh-contract/js/hello.mjs）
// 被签字节串 = UTF-8 "hello|" + String(ts) + "|" + nonce；sig = ECDSA P-256/SHA-256 DER → base64url（禁 P1363）
// ECDSA 走 native cryptoFramework：官方文档明确 sign/verify 接口仅支持 DER 格式（华为开发者文章
// 「ECDSA签名 r||s 和 DER 格式互转」），native 输出直接透传即可——真机实测 sign 输出 71~72B DER，
// 误当 64B 裸 r‖s 切半会报 BAD_RAW raw len=71（DerEcdsa 的假设是错的）。id 摘要用纯 TS sha256。
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { utf8Encode, bytesToB64u, bytesToHex, b64uToBytes } from './Codec';
import { sha256 } from './Digest';
import { VEC_HELLO } from './Vectors';

export const PROTO_VER: string = '1.0.5'

export function canonicalBytes(ts: number, nonce: string): Uint8Array {
  if (!Number.isSafeInteger(ts) || ts < 0) {
    throw new Error('ts must be a non-negative integer (epoch seconds)')
  }
  return utf8Encode(`hello|${ts}|${nonce}`)
}

/** 手机身份：ECC P-256 密钥对 + 派生 id。密钥材料经 preferences 持久化（PKCS8 + SPKI 两份 DER base64）。 */
export class PhoneIdentity {
  // 框架约束（官方文档）：convertKey 只传一种材料时返回「只包含公钥或私钥」的 KeyPair —— 只给私钥
  // 拿不到公钥（PKCS8 不内嵌公钥点）。因此分开持有两把钥匙，恢复路径必须同时提供两份 DER。
  private priKey: cryptoFramework.PriKey | null = null
  private pubKey: cryptoFramework.PubKey | null = null
  private cachedPubB64u: string = ''

  private constructor() {
  }

  private static async fromKeys(pri: cryptoFramework.PriKey | null, pub: cryptoFramework.PubKey | null): Promise<PhoneIdentity> {
    const id = new PhoneIdentity()
    id.priKey = pri
    id.pubKey = pub
    return id
  }

  /** 生成新身份（首次启动） */
  public static async generate(): Promise<PhoneIdentity> {
    const gen = cryptoFramework.createAsyKeyGenerator('ECC256')
    const kp = await gen.generateKeyPair()
    return PhoneIdentity.fromKeys(kp.priKey, kp.pubKey)
  }

  /** preferences 持久化恢复：PKCS8（私）+ SPKI（公）两份 DER 同时给（convertKey 参数序：公在前、私在后） */
  public static async fromPkcs8AndSpkiDer(priDer: Uint8Array, spkiDer: Uint8Array): Promise<PhoneIdentity> {
    const gen = cryptoFramework.createAsyKeyGenerator('ECC256')
    const priBlob: cryptoFramework.DataBlob = { data: priDer }
    const pubBlob: cryptoFramework.DataBlob = { data: spkiDer }
    const kp = await gen.convertKey(pubBlob, priBlob)
    return PhoneIdentity.fromKeys(kp.priKey, kp.pubKey)
  }

  /** 向量自测路径：PKCS8 PEM（契约向量私钥）。框架约束：仅私钥 → 无公钥（pub 一致性由 generate-export 用例承担） */
  public static async fromPkcs8Pem(pem: string): Promise<PhoneIdentity> {
    const gen = cryptoFramework.createAsyKeyGenerator('ECC256')
    const kp = await gen.convertPemKey(null, pem)
    return PhoneIdentity.fromKeys(kp.priKey, kp.pubKey)
  }

  public getPkcs8Der(): Uint8Array {
    if (this.priKey === null) { throw new Error('identity not loaded') }
    return this.priKey.getEncodedDer('PKCS8').data // API 12-24 私钥 DER 仅支持 PKCS8 取值
  }

  public getPubSpkiDer(): Uint8Array {
    if (this.pubKey === null) { throw new Error('identity not loaded') }
    // 格式取值 API 12-24 仅 'X509|COMPRESSED'/'X509|UNCOMPRESSED'；X509 即 SPKI，无压缩点 = 契约 pub 形态
    return this.pubKey.getEncodedDer('X509|UNCOMPRESSED').data
  }

  /** pub = SPKI DER → base64url（契约 §4.1） */
  public getPubB64u(): string {
    if (this.cachedPubB64u === '') {
      this.cachedPubB64u = bytesToB64u(this.getPubSpkiDer())
    }
    return this.cachedPubB64u
  }

  /** phone_id = sha256(SPKI DER) → base64url（契约 §4.1） */
  public getPhoneId(): string {
    return bytesToB64u(sha256(this.getPubSpkiDer()))
  }

  /** 签名：native 输出即 DER（官方：sign/verify 仅支持 DER），0x30 哨兵防平台行为变更后静默发坏包上桥 */
  public async signCanonical(msg: Uint8Array): Promise<Uint8Array> {
    if (this.priKey === null) { throw new Error('identity not loaded') }
    const signer = cryptoFramework.createSign('ECC256|SHA256')
    await signer.init(this.priKey)
    const input: cryptoFramework.DataBlob = { data: msg }
    const der = await signer.sign(input)
    if (der.data.length === 0 || der.data[0] !== 0x30) {
      const head = der.data.length > 0 ? der.data[0].toString(16) : 'empty'
      throw new Error(`unexpected native sig format: len=${der.data.length}, first=0x${head}`)
    }
    return der.data
  }

  /** 验签（向量自测/负例用）：native verify 仅接受 DER，直接透传（禁先转裸 r‖s） */
  public static async verify(spkiDer: Uint8Array, msg: Uint8Array, sigDer: Uint8Array): Promise<boolean> {
    const gen = cryptoFramework.createAsyKeyGenerator('ECC256')
    const pubBlob: cryptoFramework.DataBlob = { data: spkiDer }
    const kp = await gen.convertKey(pubBlob, null)
    const verifier = cryptoFramework.createVerify('ECC256|SHA256')
    await verifier.init(kp.pubKey)
    const msgBlob: cryptoFramework.DataBlob = { data: msg }
    const sigBlob: cryptoFramework.DataBlob = { data: sigDer }
    return await verifier.verify(msgBlob, sigBlob)
  }
}

export class HelloMessage {
  public t: string = 'hello'
  public role: string = 'app'
  public boot_id: string | null = null
  public pub: string = ''
  public ts: number = 0
  public nonce: string = ''
  public sig: string = ''
  public proto_ver: string = PROTO_VER
}

/** 随机 32B nonce → base64url（契约 §4.2） */
export async function randomNonce(): Promise<string> {
  const rand = cryptoFramework.createRandom()
  const blob: cryptoFramework.DataBlob = await rand.generateRandom(32)
  return bytesToB64u(blob.data)
}

/** 组装 hello 消息（role=app 无 boot_id；契约 §4.3 仅 agent MUST） */
export async function buildAppHello(identity: PhoneIdentity, nowSec: number): Promise<HelloMessage> {
  const m = new HelloMessage()
  m.role = 'app'
  m.pub = identity.getPubB64u()
  m.ts = nowSec
  m.nonce = await randomNonce()
  m.sig = bytesToB64u(await identity.signCanonical(canonicalBytes(m.ts, m.nonce)))
  return m
}

// ---- 设备侧向量自测（G2 · hello-signature.json；随机化 ECDSA 断言「验证通过」+ 被签字节串逐字节一致） ----

export class HelloVectorResult {
  public name: string = ''
  public pass: boolean = false
  public detail: string = ''
}

export async function runHelloVectors(): Promise<HelloVectorResult[]> {
  const root = JSON.parse(VEC_HELLO) as Record<string, Object>
  const meta = root['_meta'] as Record<string, Object>
  const pkcs8Pem = String(meta['private_key_pkcs8_pem'])
  const cases = root['cases'] as Array<Record<string, Object>>
  const results: HelloVectorResult[] = []
  const identity = await PhoneIdentity.fromPkcs8Pem(pkcs8Pem)
  for (const c of cases) {
    const name = String(c['name'])
    const ts = Number(c['ts'])
    const nonce = String(c['nonce'])
    const msgHex = c['expected_msg_hex']
    const sigB64u = String(c['expected_sig_base64url'])
    const pubB64u = String(c['pub'])
    const expectVerify = c['expect_verify'] === true
    let pass = true
    const details: string[] = []
    // ① 被签字节串逐字节一致
    if (msgHex !== null && msgHex !== undefined) {
      const want = String(msgHex)
      const got = bytesToHex(canonicalBytes(ts, nonce))
      if (want !== got) {
        pass = false
        details.push(`msg mismatch got=${got.substring(0, 16)}…`)
      }
    }
    // ② 向量签名验证 = expect_verify（fail-closed 场景必须 false）
    const pubDer = b64uToBytes(pubB64u)
    const sigDer = b64uToBytes(sigB64u)
    let verified = false
    try {
      verified = await PhoneIdentity.verify(pubDer, canonicalBytes(ts, nonce), sigDer)
    } catch (e) {
      verified = false
    }
    if (verified !== expectVerify) {
      pass = false
      details.push(`verify=${verified} expect=${expectVerify}`)
    }
    // ③④ 自产签名可被向量公钥验证（随机化 ECDSA 只断言验证通过）且 DER ≤72B
    if (expectVerify) {
      const own = await identity.signCanonical(canonicalBytes(ts, nonce))
      let ownOk = false
      try {
        ownOk = await PhoneIdentity.verify(pubDer, canonicalBytes(ts, nonce), own)
      } catch (e) {
        ownOk = false
      }
      if (!ownOk) {
        pass = false
        details.push('own-sign verify failed')
      }
      if (own.length > 72) {
        pass = false
        details.push(`sig DER len=${own.length} > 72`)
      }
    }
    const r = new HelloVectorResult()
    r.name = name
    r.pass = pass
    r.detail = details.length === 0 ? 'ok' : details.join('; ')
    results.push(r)
  }
  // ⑤ pub 一致性改由「生成身份」承担：PEM 恢复只有私钥、无法导出 SPKI 与向量 pub 比对（框架约束：
  // convertKey 只传一种材料 → KeyPair 只含该把钥匙）。改为断言 generate() 的 SPKI 导出为标准
  // P-256 无压缩形态（91B、27B 固定前缀，与向量 pub 前缀同构），且该导出可直接参与验签（导出↔签名往返）。
  const exportResult = new HelloVectorResult()
  exportResult.name = 'generate-export-roundtrip'
  const genIdentity = await PhoneIdentity.generate()
  const spki = genIdentity.getPubSpkiDer()
  const P256_SPKI_PREFIX: number[] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04]
  let prefixOk = spki.length === 27 + 64
  for (let i = 0; prefixOk && i < P256_SPKI_PREFIX.length; i++) {
    prefixOk = spki[i] === P256_SPKI_PREFIX[i]
  }
  let roundtripOk = false
  if (prefixOk) {
    const first = cases[0]
    const msg = canonicalBytes(Number(first['ts']), String(first['nonce']))
    roundtripOk = await PhoneIdentity.verify(spki, msg, await genIdentity.signCanonical(msg))
  }
  exportResult.pass = prefixOk && roundtripOk && genIdentity.getPkcs8Der().length > 0
  exportResult.detail = exportResult.pass ? 'ok' : `prefixOk=${prefixOk} roundtripOk=${roundtripOk} spkiLen=${spki.length}`
  results.push(exportResult)
  return results
}
