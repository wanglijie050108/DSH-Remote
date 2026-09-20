// 本地代理（03 §3.2）：TCPSocketServer 绑 127.0.0.1:13080，authority 固定
// 红线：仅 loopback 可连；隧道未就绪 → 立即 close，不排队不缓冲；端口被占不回退
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = '[Proxy]'
const DOMAIN: number = 0xD001

export type StreamHandler = (conn: socket.TCPSocketConnection) => boolean

export class LocalProxy {
  private server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance()
  private listening: boolean = false
  public onAccept: StreamHandler = (_conn: socket.TCPSocketConnection) => false

  public isListening(): boolean {
    return this.listening
  }

  public start(port: number): Promise<boolean> {
    const addr: socket.NetAddress = { address: '127.0.0.1', port: port, family: 1 }
    return new Promise<boolean>((resolve) => {
      this.server.on('connect', (client: socket.TCPSocketConnection) => {
        this.handleConnect(client)
      })
      this.server.on('error', (err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'server error %{public}s', JSON.stringify(err))
      })
      this.server.listen(addr).then(() => {
        this.listening = true
        hilog.info(DOMAIN, TAG, 'local proxy on 127.0.0.1:%{public}d', port)
        resolve(true)
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'listen %{public}d fail %{public}s（端口被占不回退）', port, JSON.stringify(e))
        resolve(false)
      })
    })
  }

  public stop(): void {
    if (!this.listening) {
      return
    }
    this.listening = false
    this.server.close().then(() => {}).catch((_e: BusinessError) => {})
  }

  private handleConnect(client: socket.TCPSocketConnection): void {
    client.getRemoteAddress().then((remote: socket.NetAddress) => {
      if (!isLoopback(remote.address)) {
        hilog.warn(DOMAIN, TAG, 'non-loopback connect from %{public}s → destroy', remote.address)
        client.close().then(() => {}).catch((_e: BusinessError) => {})
        return
      }
      const accepted = this.onAccept(client)
      if (!accepted) {
        // 隧道未就绪/开流失败：立即 close，不排队不缓冲（03 §3.2）
        client.close().then(() => {}).catch((_e: BusinessError) => {})
      }
    }).catch((_e: BusinessError) => {
      client.close().then(() => {}).catch((_e2: BusinessError) => {})
    })
  }
}

function isLoopback(ip: string): boolean {
  return ip === '127.0.0.1' || ip === '::1' || ip.startsWith('127.')
}
