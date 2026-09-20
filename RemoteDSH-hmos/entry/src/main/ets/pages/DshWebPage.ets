// DSH 前端页（NavDestination）：UI Web 组件加载本地代理 http://127.0.0.1:13080
// 携 QR t= launch token 鉴权（dsh web 对无 token 请求返回 authentication required）
// 同时是 F2/H3「明文 loopback」实证项（E4 鸿蒙等价）
import { webview } from '@kit.ArkWeb';
import { HarnessService } from '../service/HarnessService';

@Component
export struct DshWebPage {
  @StorageProp('hState') hState: string = 'IDLE'
  private controller: webview.WebviewController = new webview.WebviewController()
  private watchdogTimer: number = -1
  private watchdogRounds: number = 0

  private loopbackUrl(): string {
    const pair = HarnessService.instance.pair
    if (pair !== null && pair.launchToken.length > 0) {
      return `http://127.0.0.1:13080/?token=${pair.launchToken}`
    }
    return 'http://127.0.0.1:13080'
  }

  // 引导看门狗（changelog 024）：26s 闪断打断主 bundle 执行 → ModuleLoader 停 queue、无人调
  // create → SPA 永不启动。周期探测（runJavaScript 不等 Promise，故用同步表达式 + 状态机）：
  // booted=已启动停止探测；ready=主模块已入队 → 补 create；waiting=资源仍在下载继续等。
  private startBootWatchdog(): void {
    this.stopBootWatchdog()
    this.watchdogRounds = 0
    this.watchdogTimer = setInterval(() => {
      this.watchdogRounds++
      if (this.watchdogRounds > 12) {
        HarnessService.instance.log('[DSH页] 引导看门狗超时（60s 未 boot，隧道状态见状态机日志）')
        this.stopBootWatchdog()
        return
      }
      const probe = `(function () {
        try {
          var ml = window.__ModuleLoader__;
          if (!ml) return 'no-ml';
          if (ml.mode !== 'queue') return 'booted';
          var has = false;
          for (var i = 0; i < ml.pendingQueue.length; i++) {
            if (ml.pendingQueue[i].id === '@deepseek-ai/dsh-client-modules') { has = true; break; }
          }
          if (!has) return 'waiting';
          try { ml.create({ boot: window.__DSH_BOOT__, recovery: window.__DSH_CONNECTION_RECOVERY__ }); return 'created'; }
          catch (e2) { return 'create-err: ' + e2.message; }
        } catch (e) { return 'err: ' + e.message; }
      })()`
      this.controller.runJavaScript(probe).then((v: string) => {
        const s = String(v)
        if (s === 'booted' || s === 'created') {
          HarnessService.instance.log(`[DSH页] 引导看门狗：${s}（第 ${this.watchdogRounds} 轮）`)
          this.stopBootWatchdog()
        } else if (s.startsWith('create-err') || s.startsWith('err')) {
          HarnessService.instance.log(`[DSH页] 引导看门狗：${s}`)
        }
      }).catch((_e: Error) => {})
    }, 5000)
  }

  private stopBootWatchdog(): void {
    if (this.watchdogTimer >= 0) {
      clearInterval(this.watchdogTimer)
      this.watchdogTimer = -1
    }
  }

  aboutToDisappear(): void {
    this.stopBootWatchdog()
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.hState === 'READY') {
          Web({ src: this.loopbackUrl(), controller: this.controller })
            .width('100%')
            .height('100%')
            .onControllerAttached(() => {
              HarnessService.instance.log(`DSH Web 已挂载 ${this.loopbackUrl()}（明文 loopback 实证）`)
            })
            .onPageEnd((event) => {
              HarnessService.instance.log(`[DSH页] onPageEnd url=${event.url}`)
              this.startBootWatchdog()
            })
            .onErrorReceive((event) => {
              if (event && event.request.isMainFrame()) {
                HarnessService.instance.log(`[DSH页] 主文档错误 ${event.request.getRequestUrl()} code=${event.error.getErrorInfo()}`)
              }
            })
            .onHttpErrorReceive((event) => {
              if (event && event.request.isMainFrame()) {
                HarnessService.instance.log(`[DSH页] 主文档 HTTP ${event.response.getResponseCode()} ${event.request.getRequestUrl()}`)
              }
            })
            .onConsole((event) => {
              HarnessService.instance.log(`[DSH页][console] ${event?.message ?? ''}`)
              return false
            })
        } else {
          Column({ space: 8 }) {
            Text(`隧道未就绪（${this.hState}）`)
              .fontSize(16)
            Text('完成配对并等状态变为 READY 后再打开')
              .fontSize(13)
              .opacity(0.7)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('DSH')
  }
}
