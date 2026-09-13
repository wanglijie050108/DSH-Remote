// verify-turn-werift —— 用 werift（项目真实 ICE 栈）对真实 coturn gather，验证能否拿到 relay 候选（G1 判据②的前置）
// 用法：node scripts/verify-turn-werift.mjs <host> <secret>
import { RTCPeerConnection } from 'werift'
import { createHmac } from 'node:crypto'

const [host = '127.0.0.1', secret = 'test'] = process.argv.slice(2)
const username = `${Math.floor(Date.now() / 1000) + 3600}:werift-probe`
const credential = createHmac('sha1', secret).update(username).digest('base64')

const pc = new RTCPeerConnection({
  iceServers: [
    { urls: `stun:${host}:3478` },
    { urls: `turn:${host}:3478?transport=udp`, username, credential },
    { urls: `turn:${host}:3478?transport=tcp`, username, credential }, // §5 兜底路径
  ],
})
pc.createDataChannel('probe', { ordered: true })
const offer = await pc.createOffer()
await pc.setLocalDescription(offer)
const sdp = pc.localDescription.sdp
const candidates = (sdp.match(/a=candidate:.+/g) || [])
const relay = candidates.filter(c => /typ relay/.test(c))
const srflx = candidates.filter(c => /typ srflx/.test(c))
const host_ = candidates.filter(c => /typ host/.test(c))
console.log(`候选统计: host=${host_.length} srflx=${srflx.length} relay=${relay.length}（G1 判据②要求三类一次收齐）`)
if (relay.length) {
  console.log('relay 候选:', relay[0])
  console.log('RESULT: PASS — werift 经真实 coturn 拿到 relay 候选')
  process.exit(0)
} else {
  console.log('RESULT: FAIL — 未取得 relay 候选')
  process.exit(1)
}
