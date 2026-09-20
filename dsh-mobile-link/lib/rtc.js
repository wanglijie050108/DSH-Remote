// werift PeerConnection 封装（01 §4.2/§4.4）：整证书注入 + 双 DataChannel + 非 trickle offer + 重建
// 选型依据：werift 纯 TS，避免原生模块运行期崩溃波及 DSH 进程（01 §3）
import { RTCPeerConnection } from 'werift'

// ★ W1 实测（remotedsh-contract/scripts/poc-werift-loopback.mjs）：RTCCertificate 第三参必须是
//   {hash, signature} 枚举对象；传字符串会导致 DTLS 握手必败。
export const SIGNATURE_HASH = { hash: 4 /* HashAlgorithm.sha256_4 */, signature: 3 /* SignatureAlgorithm.ecdsa_3 */ }
export const GATHER_TIMEOUT_MS = 20_000

export function turnIceServers(turn) {
  return turn.uris.map((urls) => /^turns?:/.test(urls)
    ? { urls, username: turn.username, credential: turn.credential }
    : { urls })
}

export async function withTimeout(promise, timeoutMs, onTimeout, message) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          try { onTimeout?.() } finally { reject(new Error(message)) }
        }, timeoutMs)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

/**
 * 创建 offer 侧 PeerConnection（插件恒为 offer 方，契约 §4.1；手机 MUST NOT createDataChannel）。
 * 单阶段 ICE：iceServers 必须在**首次 gather 前**就绪（契约 §4.3/§5——否则 offer 静默缺 relay 候选）。
 * @returns {{ pc, dataCh, ctlCh, offer: RTCSessionDescription }}
 */
export async function createOfferPeer({ certificate, iceServers, iceTransportPolicy, log = () => {} }) {
  const pc = new RTCPeerConnection({ certificates: [certificate], iceServers, iceTransportPolicy })
  // label 识别（契约 §3 v1.0.4 写死）：'data' 有序可靠（OPEN/DATA/FIN）；'ctl' 无序可靠（PING/PONG/WINDOW/RST）
  const dataCh = pc.createDataChannel('data', { ordered: true })
  const ctlCh = pc.createDataChannel('ctl', { ordered: false })
  const offer = await pc.createOffer()
  await withTimeout(
    pc.setLocalDescription(offer),
    GATHER_TIMEOUT_MS,
    () => pc.close(),
    `ICE gather timeout (${GATHER_TIMEOUT_MS}ms)`,
  )
  const candidateTypes = [...pc.localDescription.sdp.matchAll(/a=candidate:.* typ (\S+)/g)].map((m) => m[1])
  if (candidateTypes.length === 0) throw new Error('offer 无候选（gather 失败）')
  if (iceTransportPolicy === 'relay' && candidateTypes.some((type) => type !== 'relay')) {
    throw new Error(`relay-only 未生效：offer 含 ${candidateTypes.join('/')} 候选`)
  }
  log(`offer ready: ${candidateTypes.length} candidates（${candidateTypes.join('/')}）`)
  return { pc, dataCh, ctlCh, offer: pc.localDescription }
}

/** answer 侧（fake/调试用；正式链路中手机是 answerer，插件不调用） */
export async function acceptAnswer(pc, answerSdp) {
  await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp })
}
