// 主控台（@Entry + Navigation 根容器；router 全面禁用红线）
// 布局：Stack{ 隐藏 RTC Web(1×1) + Navigation 控制台 }；隐藏 Web 常驻挂载承载 RTCPeerConnection
import { HarnessService } from '../service/HarnessService';
import { RtcEngine } from '../rtc/RtcEngine';
import { SelfTestPage } from './SelfTestPage';
import { ProbePage } from './ProbePage';
import { LogsPage } from './LogsPage';
import { DshWebPage } from './DshWebPage';

@Entry
@Component
struct Index {
  @StorageProp('hState') hState: string = 'IDLE'
  @StorageProp('hDetail') hDetail: string = ''
  @StorageProp('logTail') logTail: string = ''
  @State qrInput: string = ''
  @State relayOnly: boolean = false
  @State webReady: boolean = false
  private svc: HarnessService = HarnessService.instance
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    this.svc.rtc.addReadyListener('index', () => {
      this.webReady = true
    })
    this.webReady = this.svc.rtc.pageReady // onReady 可能早于页面挂载已触发
  }

  @Builder
  navPages(name: string) {
    if (name === 'SelfTest') {
      SelfTestPage()
    } else if (name === 'Probe') {
      ProbePage()
    } else if (name === 'Logs') {
      LogsPage()
    } else if (name === 'DshWeb') {
      DshWebPage()
    }
  }

  build() {
    Stack() {
      // 隐藏 RTC 承载页：1×1 + 近乎透明（保证渲染进程执行 JS；Visibility.None 有暂停风险，H1 验证项）
      Web({ src: $rawfile('rtc.html'), controller: this.svc.rtc.controller })
        .javaScriptProxy({
          object: this.svc.rtc.proxy,
          name: 'hpc',
          methodList: RtcEngine.proxyMethodList(),
          controller: this.svc.rtc.controller,
        })
        .width(1)
        .height(1)
        .opacity(0.01)
        .hitTestBehavior(HitTestMode.None)
        .onPermissionRequest((event) => {
          event.request.grant(event.request.getAccessibleResource())
        })
        .onPageEnd(() => {
          if (!this.webReady) {
            this.svc.log('rtc.html onPageEnd（onReady 未达，可能 JS 异常）')
          }
        })

      Navigation(this.pathStack) {
        Scroll() {
          Column({ space: 16 }) {
            Text('RemoteDSH 鸿蒙 Harness')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .width('100%')
            Text(`契约 v1.0.5 · API 24 · RTC=${this.webReady ? '就绪' : '初始化中'}`)
              .fontSize(13)
              .opacity(0.7)
              .width('100%')

            // 状态卡片
            Column({ space: 4 }) {
              Text(`状态：${this.hState}`)
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
              Text(this.hDetail)
                .fontSize(13)
                .opacity(0.75)
            }
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .borderRadius(12)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .width('100%')

            // 配对输入
            Column({ space: 8 }) {
              Text('配对（粘贴 dshlink:// QR 内容）')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
              TextArea({ text: this.qrInput, placeholder: 'dshlink://pair?v=1&s=…' })
                .height(72)
                .onChange((v: string) => {
                  this.qrInput = v
                })
              Row({ space: 8 }) {
                Button('配对')
                  .layoutWeight(1)
                  .onClick(() => {
                    if (this.qrInput.trim().length === 0) {
                      this.svc.log('QR 输入为空')
                      return
                    }
                    this.svc.pairFromQr(this.qrInput)
                  })
                Button('免扫码重连')
                  .layoutWeight(1)
                  .onClick(() => {
                    this.svc.resume()
                  })
                Button('停止/bye')
                  .layoutWeight(1)
                  .backgroundColor($r('sys.color.warning'))
                  .onClick(() => {
                    this.svc.stop()
                  })
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')

            // relay-only 开关
            Row() {
              Text('relay-only（强制走 TURN 中继，G3-H 判据）')
                .fontSize(14)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.relayOnly })
                .onChange((on: boolean) => {
                  this.relayOnly = on
                  this.svc.setRelayOnly(on)
                })
            }
            .width('100%')

            // 工具入口
            Row({ space: 8 }) {
              Button('自测')
                .layoutWeight(1)
                .onClick(() => {
                  this.pathStack.pushPathByName('SelfTest', null)
                })
              Button('探针')
                .layoutWeight(1)
                .onClick(() => {
                  this.pathStack.pushPathByName('Probe', null)
                })
              Button('日志')
                .layoutWeight(1)
                .onClick(() => {
                  this.pathStack.pushPathByName('Logs', null)
                })
              Button('打开DSH')
                .layoutWeight(1)
                .onClick(() => {
                  this.pathStack.pushPathByName('DshWeb', null)
                })
            }
            .width('100%')

            // 日志预览
            Column() {
              Text(this.logTail === '' ? '（暂无日志）' : this.logTail)
                .fontSize(11)
                .fontFamily('monospace')
                .maxLines(8)
                .copyOption(CopyOptions.InApp)
            }
            .width('100%')
            .padding(8)
            .borderRadius(8)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
          }
          .padding(16)
          .constraintSize({ minHeight: '100%' })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
      }
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .navDestination(this.navPages)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }
}
