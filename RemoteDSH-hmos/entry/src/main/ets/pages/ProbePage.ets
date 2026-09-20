// H1 探针页（NavDestination）：
// 探针 A——ArkWeb WebRTC 能力存在性（typeof RTCPeerConnection / createDataChannel / generateCertificate）
// 探针 B——ArkWeb ↔ PC Chrome 同局域网手动换 SDP（隔离"ArkWeb WebRTC 可用"与"werift 互通"）
import { HarnessService } from '../service/HarnessService';
import { RtcEngine } from '../rtc/RtcEngine';

@Component
export struct ProbePage {
  @State probeJson: string = ''
  @State sdpOut: string = ''
  @State answerInput: string = ''
  @State iceLines: string[] = []
  @State chanLines: string[] = []
  private svc: HarnessService = HarnessService.instance

  aboutToAppear(): void {
    const rtc: RtcEngine = this.svc.rtc
    rtc.addProbeListener('probe', (json: string) => {
      this.probeJson = json
    })
    rtc.addSdpListener('probe', (sdp: string, err: string) => {
      this.sdpOut = err !== '' ? `ERR: ${err}` : sdp
    })
    rtc.addIceListener('probe', (state: string) => {
      this.iceLines = this.iceLines.concat(state)
      if (this.iceLines.length > 30) {
        this.iceLines = this.iceLines.slice(-30)
      }
    })
    rtc.addChannelOpenListener('probe', (label: string) => {
      this.chanLines = this.chanLines.concat(`open: ${label}`)
    })
    rtc.addChannelCloseListener('probe', (label: string) => {
      this.chanLines = this.chanLines.concat(`close: ${label}`)
    })
    rtc.addErrorListener('probe', (msg: string) => {
      this.iceLines = this.iceLines.concat(`ERR: ${msg}`)
    })
  }

  aboutToDisappear(): void {
    this.svc.rtc.removeListener('probe')
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 12 }) {
          Text('探针 A：WebRTC 能力存在性')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Button('运行探针 A')
            .width('100%')
            .onClick(() => {
              this.svc.rtc.cmdProbe()
            })
          if (this.probeJson !== '') {
            Text(this.probeJson)
              .fontSize(12)
              .fontFamily('monospace')
              .copyOption(CopyOptions.InApp)
              .width('100%')
              .padding(8)
              .borderRadius(8)
              .backgroundColor($r('sys.color.comp_background_tertiary'))
          }

          Text('探针 B：对 PC Chrome 手动换 SDP')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 8 })
            .width('100%')
          Button('生成 offer（复制到 Chrome/webrtc-internals 对端）')
            .width('100%')
            .onClick(() => {
              this.sdpOut = ''
              this.svc.rtc.cmdOffer('[]')
            })
          if (this.sdpOut !== '') {
            Text(this.sdpOut)
              .fontSize(11)
              .fontFamily('monospace')
              .maxLines(12)
              .copyOption(CopyOptions.InApp)
              .width('100%')
              .padding(8)
              .borderRadius(8)
              .backgroundColor($r('sys.color.comp_background_tertiary'))
          }
          TextArea({ text: this.answerInput, placeholder: '粘贴 Chrome 的 answer SDP' })
            .height(72)
            .onChange((v: string) => {
              this.answerInput = v
            })
          Button('填入 answer → 建连')
            .width('100%')
            .onClick(() => {
              if (this.answerInput.trim().length === 0) {
                return
              }
              this.svc.rtc.cmdSetAnswer(this.answerInput.trim())
            })

          Text('通道')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 8 })
            .width('100%')
          ForEach(this.chanLines, (l: string) => {
            Text(l).fontSize(12).fontFamily('monospace').width('100%')
          }, (l: string, i: number) => `${i}/${l}`)

          Text('ICE 状态')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 8 })
            .width('100%')
          ForEach(this.iceLines, (l: string) => {
            Text(l).fontSize(12).fontFamily('monospace').width('100%')
          }, (l: string, i: number) => `${i}/${l}`)
        }
        .padding(16)
        .constraintSize({ minHeight: '100%' })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
    }
    .title('H1 探针')
  }
}
