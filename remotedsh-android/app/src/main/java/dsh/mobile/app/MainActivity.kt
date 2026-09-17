// MainActivity —— 三屏 + WebView 壳（03 §3.4）
// 扫码屏 / 状态屏 / WebView 屏；WebView 安全红线逐条落实。
package dsh.mobile.app

import android.os.Bundle
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

const val AUTHORITY_URL = "http://127.0.0.1:13080"

class MainActivity : ComponentActivity() {
    private var webView: WebView? = null
    private var lastInterruptedAt: Long? = null

    // 使用 Compose observable state，UI 会自动响应变化
    private var appState by mutableStateOf<AppState>(AppState.Idle)
    private var launchToken: String? = null

    // 供外部模块（SignalClient/状态机）更新状态
    fun updateState(newState: AppState) { appState = newState }
    fun setLaunchToken(token: String?) { launchToken = token }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    when (val s = appState) {
                        is AppState.Scanning, is AppState.Idle -> ScanScreen(onScan = { /* zxing-embedded 启动扫码 */ })
                        is AppState.NeedPair, is AppState.Reconnecting, is AppState.Busy, is AppState.UpgradeRequired,
                        is AppState.Signaling, is AppState.Punching -> StatusScreen(s)
                        is AppState.Connected -> WebViewScreen()
                    }
                }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun ScanScreen(onScan: () -> Unit) {
        Column(verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Button(onClick = onScan) { Text("扫码配对") }
        }
    }

    @androidx.compose.runtime.Composable
    private fun StatusScreen(s: AppState) {
        Column(verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            val text = when (s) {
                is AppState.NeedPair -> s.message
                is AppState.UpgradeRequired -> s.message
                is AppState.Busy -> s.message
                is AppState.Reconnecting -> "正在重连…"
                is AppState.Signaling -> "正在配对…"
                is AppState.Punching -> "正在建立隧道…"
                else -> ""
            }
            Text(text)
        }
    }

    @androidx.compose.runtime.Composable
    private fun WebViewScreen() {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                WebView(context).apply { configureSecureWebView(this) }
            },
        )
    }

    /** WebView 配置清单（03 §3.4 安全红线逐条） */
    private fun configureSecureWebView(wv: WebView) {
        webView = wv
        wv.settings.run {
            javaScriptEnabled = true
            domStorageEnabled = true // 官方前端 localStorage 需要
            allowFileAccess = false
            allowContentAccess = false
        }
        android.webkit.WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG) // release 关闭
        android.webkit.CookieManager.getInstance().setAcceptCookie(true)
        wv.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                // 禁止任何导航离开 127.0.0.1
                val host = request?.url?.host ?: return true
                return !(host == "127.0.0.1" || host == "localhost")
            }

            override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: android.webkit.WebResourceResponse?) {
                // 「QR 里没有 t、本地也没有 cookie」路径（03 §3.4）：401 → 状态屏提示，不反复重试
                if (request?.isForMainFrame == true && errorResponse?.statusCode == 401) {
                    appState = AppState.NeedPair("本地登录已失效，请在 PC 上用 `dsh web` 重新生成带 token 的二维码后重新扫码")
                }
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                lastInterruptedAt = System.currentTimeMillis() // 主框架错误视作中断计时起点（§4）
            }
        }
        wv.webChromeClient = object : WebChromeClient() {
            override fun onCreateWindow(view: WebView?, dialog: Boolean, userGesture: Boolean, resultMsg: android.os.Message?): Boolean = false // 挡 window.open / target=_blank
        }
        wv.setDownloadListener { _, _, _, _, _ -> /* 拒绝下载（DSH 有 /export 下载入口） */ }
        wv.setSupportMultipleWindows(false)
        // token 交换：GET http://127.0.0.1:13080/?token=<QR 中的 t> → 303 + Set-Cookie → 固定 loadUrl
        val token = launchToken
        if (token != null) {
            wv.loadUrl("$AUTHORITY_URL/?token=$token")
        } else {
            wv.loadUrl("$AUTHORITY_URL/") // 无 t 分支：靠 onReceivedHttpError 401 引导
        }
    }

    /** 隧道重建完成回调（由连接层调用）：中断 >10s → reload（§4 必需路径） */
    fun onTunnelReconnected() {
        val now = System.currentTimeMillis()
        if (shouldReloadOnReconnect(lastInterruptedAt, now)) {
            webView?.reload()
        }
        lastInterruptedAt = null
    }
}