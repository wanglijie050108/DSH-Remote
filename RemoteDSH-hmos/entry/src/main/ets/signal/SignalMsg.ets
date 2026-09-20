// 信令层：@ohos.net.webSocket 客户端（语义对齐 core-bridge / fake-phone 的 WS 用法）
// 职责：「一条连接」的生命周期 + 25s 心跳义务（契约 §4）；重连决策在 HarnessService
// 消息分发按 t 字段收窄；JSON 形状统一在 SignalMsg 收窄，不透传 any。
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TurnBlock } from '../contract/Turn';

const TAG: string = '[Signal]'
const DOMAIN: number = 0xD001

export class PairBrief {
  public pair_id: string = ''
  public agent_id: string = ''
}

/** 信令消息统一收窄形状（字段按契约 §4 全集） */
export class SignalMsg {
  public t: string = ''
  public pair: PairBrief | null = null
  public peer_online: boolean | null = null
  public pair_id: string = ''
  public agent_id: string = ''
  public turn: TurnBlock | null = null
  public sdp: string = ''
  public code: string = ''
  public msg: string = ''
  public reason: string = ''
}

export type SignalListener = (msg: SignalMsg) => void
export type SignalOpenListener = () => void
export type SignalCloseListener = () => void

function narrowTurn(raw: Object | undefined | null): TurnBlock | null {
  if (raw === undefined || raw === null) {
    return null
  }
  const r = raw as Record<string, Object>
  const tb = new TurnBlock()
  tb.username = r['username'] !== undefined ? String(r['username']) : ''
  tb.credential = r['credential'] !== undefined ? String(r['credential']) : ''
  tb.ttl = r['ttl'] !== undefined ? Number(r['ttl']) : 3600
  if (r['uris'] !== undefined) {
    const arr = r['uris'] as Array<Object>
    for (const u of arr) {
      tb.uris.push(String(u))
    }
  }
  return tb
}

export function parseSignalMsg(text: string): SignalMsg {
  const root = JSON.parse(text) as Record<string, Object>
  const m = new SignalMsg()
  m.t = root['t'] !== undefined ? String(root['t']) : ''
  if (root['pair'] !== undefined && root['pair'] !== null) {
    const p = root['pair'] as Record<string, Object>
    const pb = new PairBrief()
    pb.pair_id = p['pair_id'] !== undefined ? String(p['pair_id']) : ''
    pb.agent_id = p['agent_id'] !== undefined ? String(p['agent_id']) : ''
    m.pair = pb
  }
  if (root['peer_online'] !== undefined) {
    m.peer_online = root['peer_online'] === true
  }
  m.pair_id = root['pair_id'] !== undefined ? String(root['pair_id']) : ''
  m.agent_id = root['agent_id'] !== undefined ? String(root['agent_id']) : ''
  m.turn = narrowTurn(root['turn'])
  m.sdp = root['sdp'] !== undefined ? String(root['sdp']) : ''
  m.code = root['code'] !== undefined ? String(root['code']) : ''
  m.msg = root['msg'] !== undefined ? String(root['msg']) : ''
  m.reason = root['reason'] !== undefined ? String(root['reason']) : ''
  return m
}

export class SignalClient {
  private ws: webSocket.WebSocket = webSocket.createWebSocket()
  private heartbeat: number = -1
  private connected: boolean = false
  public onOpen: SignalOpenListener = () => {}
  public onMsg: SignalListener = () => {}
  public onClose: SignalCloseListener = () => {}

  public isUsable(): boolean {
    return this.connected
  }

  public connect(url: string): void {
    this.connected = false
    this.ws = webSocket.createWebSocket()
    this.ws.on('open', (_err: BusinessError, _value: Object) => {
      hilog.info(DOMAIN, TAG, 'open %{public}s', maskUrl(url))
      this.connected = true
      this.startHeartbeat()
      this.onOpen()
    })
    this.ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value !== 'string') {
        return // 信令全为文本帧（契约 §4）
      }
      try {
        this.onMsg(parseSignalMsg(value))
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'parse fail %{public}s', String(e))
      }
    })
    this.ws.on('close', (_err: BusinessError, _value: webSocket.CloseResult) => {
      hilog.info(DOMAIN, TAG, 'closed')
      this.stopHeartbeat()
      if (this.connected) {
        this.connected = false
        this.onClose()
      }
    })
    this.ws.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'error %{public}s', JSON.stringify(err))
    })
    this.ws.connect(url, (err: BusinessError, value: boolean) => {
      if (err || !value) {
        hilog.error(DOMAIN, TAG, 'connect fail %{public}s', JSON.stringify(err))
        this.connected = false
        this.onClose()
      }
    })
  }

  public sendJson(obj: Object): boolean {
    if (!this.connected) {
      return false
    }
    this.ws.send(JSON.stringify(obj)).then(() => {}).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'send fail %{public}s', JSON.stringify(e))
    })
    return true
  }

  public close(): void {
    this.stopHeartbeat()
    if (this.connected) {
      this.connected = false
      this.ws.close().then(() => {}).catch((_e: BusinessError) => {})
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat()
    this.heartbeat = setInterval(() => {
      const o: Record<string, string> = { 't': 'ping' }
      this.sendJson(o)
    }, 25000)
  }

  private stopHeartbeat(): void {
    if (this.heartbeat >= 0) {
      clearInterval(this.heartbeat)
      this.heartbeat = -1
    }
  }
}

/** 日志脱敏：信令 URL 只打协议+host */
function maskUrl(url: string): string {
  const idx = url.indexOf('?')
  return idx > 0 ? url.substring(0, idx) + '?…' : url
}
