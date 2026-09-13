// core-proxy —— 本地 TCP 代理（03 §3.2）
// 红线：
//  1. ServerSocket 绑定固定 authority 127.0.0.1:13080；BindException → 硬失败（不做端口回退——换端口使 cookie 全失效）；
//  2. 仅接受 loopback 来源（防御性检查，不是安全边界——真正的边界是 DSH 的 HttpOnly cookie 与配对本身）；
//  3. 隧道未就绪时对新建本地连接：立即 close()，不排队、不缓冲；
//  4. 收到 FIN 只做半关闭（shutdownOutput），继续读——否则 HTTP 响应体会被静默截断（契约 §3.3）；
//  5. WS 长连接即普通流：升级请求与其后全部帧同一条 stream 保序透传（不吞 DSH 2s Ping、不做 UTF-8 转换）；
//  6. 流量控制按契约 §3.4：每方向初始信用 256KiB、WINDOW 回填 ≥64KiB 增量、并发 stream 上限 128。
package dsh.mobile.proxy

import dsh.mobile.contract.FrameCodec
import dsh.mobile.contract.Frames
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

interface TunnelSender {
    val ready: Boolean
    /** 返回 false = 未发送队列超限（单流 256KiB / 全局 512KiB），调用方暂停读 socket（§3.4.7） */
    fun sendFrame(type: Int, streamId: Long, payload: ByteArray): Boolean
    fun onSocketWritable(bytesWritten: Int) // 接收侧记账：驱动 WINDOW 增量回填
}

class LocalProxy(
    private val scope: CoroutineScope,
    private val authority: String = "127.0.0.1",
    private val port: Int = 13080,
) {
    private var server: ServerSocket? = null
    private val nextStreamId = AtomicLong(0)
    private val activeStreams = AtomicInteger(0)
    var onNewStream: ((streamId: Long, socket: Socket) -> Unit)? = null

    /** 启动。BindException → PortInUseException（App 层硬失败提示，不做端口回退）。 */
    @Throws(PortInUseException::class)
    fun start() {
        try {
            server = ServerSocket(port, 50, InetAddress.getByName(authority))
        } catch (e: Exception) {
            if (e is java.net.BindException) throw PortInUseException(port)
            throw e
        }
        scope.launch(Dispatchers.IO) {
            while (!server!!.isClosed) {
                val socket = try { server!!.accept() } catch (_: Exception) { break }
                handleAccepted(socket)
            }
        }
    }

    fun stop() {
        try { server?.close() } catch (_: Exception) {}
    }

    private fun handleAccepted(socket: Socket) {
        scope.launch(Dispatchers.IO) {
            try {
                // ② 仅接受 loopback（防御性检查，非安全边界，03 §3.2）
                if (!socket.inetAddress.isLoopbackAddress) {
                    socket.close(); return@launch
                }
            } catch (_: Exception) { return@launch }
            onAccepted(socket)
        }
    }

    /** 由 app 层注入：隧道就绪时返回 sender；未就绪 → null（③ 立即 close，不排队） */
    var senderProvider: (() -> TunnelSender?)? = null

    private fun onAccepted(socket: Socket) {
        val sender = senderProvider?.invoke()
        if (sender == null || !sender.ready) {
            try { socket.close() } catch (_: Exception) {}
            return
        }
        if (activeStreams.get() >= 128) { // §3.4.2 并发上限
            try { socket.close() } catch (_: Exception) {}
            return
        }
        val streamId = nextStreamId.incrementAndGet()
        activeStreams.incrementAndGet()
        // 手机侧发 OPEN（authority 一致性由对端断言，§1）
        sender.sendFrame(Frames.TYPE_OPEN, streamId, "{\"authority\":\"$authority:$port\"}".toByteArray(Charsets.UTF_8))
        onNewStream?.invoke(streamId, socket)
        // socket → DATA 帧泵（读侧受信用与队列约束）
        val input = socket.getInputStream()
        val buf = ByteArray(Frames.MAX_PAYLOAD)
        scope.launch(Dispatchers.IO) {
            try {
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (!sender.sendFrame(Frames.TYPE_DATA, streamId, buf.copyOf(n))) {
                        // 未发送队列超限：暂停读（§3.4.7），由 bufferedAmountLow 语义恢复（此处简化为轮询等待）
                        while (!sender.sendFrame(Frames.TYPE_DATA, streamId, buf.copyOf(n))) {
                            Thread.sleep(20)
                        }
                    }
                }
                // socket 读尽 → FIN（走 data，§3.4.8）
                sender.sendFrame(Frames.TYPE_FIN, streamId, ByteArray(0))
            } catch (_: Exception) {
            } finally {
                activeStreams.decrementAndGet()
            }
        }
        // 对端 DATA → socket 写（写侧不在 WebRTC 回调线程——红线 4；WINDOW 记账）
        // 具体接线由 app 层把 onDataChannel 帧路由到 RouteToSocket(streamId, bytes)
    }

    /** 对端 DATA 到达（由 core-rtc 帧分发调用）：写 socket + 记账 */
    fun routeToSocket(socket: Socket, payload: ByteArray, writtenSinceWindow: AtomicInteger) {
        socket.getOutputStream().write(payload)
        socket.getOutputStream().flush()
        val total = writtenSinceWindow.addAndGet(payload.size)
        if (total >= 64 * 1024) {
            writtenSinceWindow.set(0) // 增量语义（§3.4.5），由调用方取值发 WINDOW
        }
    }
}

class PortInUseException(val port: Int) : Exception("本地端口 $port 被占用，请关闭占用它的应用并重试（不做端口回退，03 §3.2）")
