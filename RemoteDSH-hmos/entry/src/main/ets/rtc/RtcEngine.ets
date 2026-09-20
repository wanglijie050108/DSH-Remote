// RTC 承载引擎（ArkTS 侧）：持有隐藏 ArkWeb 的 controller 与 javaScriptProxy 对象
// JS → ArkTS：hpc.onXxx(...)（proxy 对象方法）；ArkTS → JS：controller.runJavaScript('__h.xxx(...)')
// 帧中继用 base64（harness 专有折衷，见 06 §2）
// 事件用多播监听器（key 区分订阅方：'svc'=HarnessService，'probe'=探针页），页面销毁时移除。
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bytesToBase64 } from '../contract/Codec';

const TAG: string = '[RTC]'
const DOMAIN: number = 0xD001

export type SdpCallback = (sdp: string, err: string) => void
export type IceStateCallback = (state: string) => void
export type ChannelCallback = (label: string) => void
export type FrameCallback = (label: string, b64: string) => void
export type ProbeCallback = (json: string) => void
export type StringCallback = (msg: string) => void
export type VoidCallback = () => void

const RTC_PROXY_METHODS: string[] =
  ['onReady', 'onProbe', 'onSdp', 'onIceState', 'onDataOpen', 'onDataClose', 'onFrame', 'onRtcLog', 'onError']

/** javaScriptProxy 暴露给 rtc.html 的对象（方法名必须与 methodList 完全一致） */
export class RtcProxy {
  private engine: RtcEngine

  constructor(engine: RtcEngine) {
    this.engine = engine
  }

  onReady(): void { this.engine.handleReady() }
  onProbe(json: string): void { this.engine.handleProbe(json) }
  onSdp(sdp: string): void { this.engine.handleSdp(sdp) }
  onIceState(state: string): void { this.engine.handleIceState(state) }
  onDataOpen(label: string): void { this.engine.handleChannelOpen(label) }
  onDataClose(label: string): void { this.engine.handleChannelClose(label) }
  onFrame(label: string, b64: string): void { this.engine.handleFrame(label, b64) }
  onRtcLog(msg: string): void { this.engine.handleLog(msg) }
  onError(msg: string): void { this.engine.handleErr(msg) }
}

export class RtcEngine {
  public controller: webview.WebviewController = new webview.WebviewController()
  public proxy: RtcProxy
  public pageReady: boolean = false

  private readyMap: Map<string, VoidCallback> = new Map()
  private probeMap: Map<string, ProbeCallback> = new Map()
  private sdpMap: Map<string, SdpCallback> = new Map()
  private iceMap: Map<string, IceStateCallback> = new Map()
  private chanOpenMap: Map<string, ChannelCallback> = new Map()
  private chanCloseMap: Map<string, ChannelCallback> = new Map()
  private frameMap: Map<string, FrameCallback> = new Map()
  private logMap: Map<string, StringCallback> = new Map()
  private errorMap: Map<string, StringCallback> = new Map()

  constructor() {
    this.proxy = new RtcProxy(this)
  }

  public static proxyMethodList(): string[] {
    return RTC_PROXY_METHODS
  }

  // ---- 监听器注册/移除 ----
  public addReadyListener(key: string, fn: VoidCallback): void { this.readyMap.set(key, fn) }
  public addProbeListener(key: string, fn: ProbeCallback): void { this.probeMap.set(key, fn) }
  public addSdpListener(key: string, fn: SdpCallback): void { this.sdpMap.set(key, fn) }
  public addIceListener(key: string, fn: IceStateCallback): void { this.iceMap.set(key, fn) }
  public addChannelOpenListener(key: string, fn: ChannelCallback): void { this.chanOpenMap.set(key, fn) }
  public addChannelCloseListener(key: string, fn: ChannelCallback): void { this.chanCloseMap.set(key, fn) }
  public addFrameListener(key: string, fn: FrameCallback): void { this.frameMap.set(key, fn) }
  public addLogListener(key: string, fn: StringCallback): void { this.logMap.set(key, fn) }
  public addErrorListener(key: string, fn: StringCallback): void { this.errorMap.set(key, fn) }
  public removeListener(key: string): void {
    this.readyMap.delete(key)
    this.probeMap.delete(key)
    this.sdpMap.delete(key)
    this.iceMap.delete(key)
    this.chanOpenMap.delete(key)
    this.chanCloseMap.delete(key)
    this.frameMap.delete(key)
    this.logMap.delete(key)
    this.errorMap.delete(key)
  }

  // ---- JS → ArkTS 事件分发 ----
  public handleReady(): void {
    this.pageReady = true
    hilog.info(DOMAIN, TAG, 'page ready')
    this.readyMap.forEach((fn) => fn())
  }

  public handleProbe(json: string): void {
    this.probeMap.forEach((fn) => fn(json))
  }

  public handleSdp(sdp: string): void {
    this.sdpMap.forEach((fn) => fn(sdp, ''))
  }

  public handleIceState(state: string): void {
    this.iceMap.forEach((fn) => fn(state))
  }

  public handleChannelOpen(label: string): void {
    if (label.startsWith('bad:')) {
      this.handleChannelClose(label)
      return
    }
    this.chanOpenMap.forEach((fn) => fn(label))
  }

  public handleChannelClose(label: string): void {
    this.chanCloseMap.forEach((fn) => fn(label))
  }

  public handleFrame(label: string, b64: string): void {
    this.frameMap.forEach((fn) => fn(label, b64))
  }

  public handleLog(msg: string): void {
    this.logMap.forEach((fn) => fn(msg))
  }

  public handleErr(msg: string): void {
    hilog.error(DOMAIN, TAG, 'js err %{public}s', msg)
    this.errorMap.forEach((fn) => fn(msg))
  }

  // ---- ArkTS → JS 命令 ----
  public cmdAnswer(offerSdp: string, iceServersJson: string, relayOnly: boolean): void {
    this.run(`__h.answer(${JSON.stringify(offerSdp)}, ${JSON.stringify(iceServersJson)}, ${relayOnly ? 'true' : 'false'})`)
  }

  public cmdOffer(iceServersJson: string): void {
    this.run(`__h.offer(${JSON.stringify(iceServersJson)})`)
  }

  public cmdSetAnswer(answerSdp: string): void {
    this.run(`__h.setAnswer(${JSON.stringify(answerSdp)})`)
  }

  public cmdSend(label: string, bytes: Uint8Array): void {
    this.run(`__h.send(${JSON.stringify(label)}, ${JSON.stringify(bytesToBase64(bytes))})`)
  }

  public cmdClose(): void {
    this.run('__h.close()')
  }

  public cmdProbe(): void {
    this.run('__h.probe()')
  }

  private run(script: string): void {
    this.controller.runJavaScript(script).then((_v: string) => {}).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'runJavaScript fail %{public}s', JSON.stringify(e))
    })
  }
}
