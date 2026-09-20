// G2 向量自测页（NavDestination）：设备上跑契约自测（含 native ECDSA hello 向量）
import { runAllSelfTests, CaseResult, SelfTestReport } from '../contract/SelfTest';

@Component
export struct SelfTestPage {
  @State running: boolean = false
  @State cases: CaseResult[] = []
  @State summary: string = '尚未运行'

  private run(): void {
    if (this.running) {
      return
    }
    this.running = true
    this.summary = '运行中…'
    runAllSelfTests().then((rep: SelfTestReport) => {
      this.cases = rep.cases
      this.summary = `通过 ${rep.passed} / 失败 ${rep.failed}（共 ${rep.cases.length} 例 · proto ${rep.protoVer}）`
      this.running = false
    }).catch((e: Error) => {
      this.summary = `自测异常：${String(e)}`
      this.running = false
    })
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Button(this.running ? '运行中…' : '运行自测')
          .width('100%')
          .enabled(!this.running)
          .onClick(() => {
            this.run()
          })
        Text(this.summary)
          .fontSize(14)
          .width('100%')
        List({ space: 4 }) {
          ForEach(this.cases, (c: CaseResult) => {
            ListItem() {
            Row({ space: 8 }) {
              Text(c.pass ? '✓' : '✗')
                .fontSize(15)
                .fontColor(c.pass ? '#2e7d32' : '#c62828')
                .width(24)
              Column({ space: 2 }) {
                Text(`${c.suite} · ${c.name}`)
                  .fontSize(13)
                Text(c.detail)
                  .fontSize(11)
                  .opacity(0.6)
                  .maxLines(2)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .width('100%')
            }
          }, (c: CaseResult) => `${c.suite}/${c.name}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
      .padding(16)
      .width('100%')
      .height('100%')
    }
    .title('G2 向量自测')
  }
}
