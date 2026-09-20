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
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
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
import androidx.lifecycle.viewmodel.compose.viewModel

const val AUTHORITY_URL = "http://127.0.0.1:13080"

class MainActivity : ComponentActivity() {
    private var webView: WebView? = null
    private var lastInterruptedAt: Long? = null

    // Compose observable state
    private var appState by mutableStateOf<AppState>(AppState.Idle)
    private var launchToken: String? = null

    // QR 扫描器（journeyapps zxing-android-embedded）
    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { viewModel.onQrScanned(it) }
    }

    // ViewModel
    private val viewModel by lazy {
        androidx.lifecycle.ViewModelProvider(this)[AppViewModel::class.java]
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 接线 ViewModel 回调
        viewModel.onNavigate = { url ->
            launchToken = if (url.contains("?token=")) {
                url.substringAfter("?token=")
            } else null
            appState = AppState.Connected(sinceMs = System.currentTimeMillis())
            webView?.let { loadInWebView(it, url) }
        }
        viewModel.onStateChange = { newState ->
            appState = newState
        }

        setContent {
            val vm: AppViewModel = viewModel()
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    when (val s = appState) {
                        is AppState.Scanning, is AppState.Idle -> ScanScreen(onScan = {
                            scanLauncher.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE))
                        })
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
                WebView(context).apply {
                    configureSecureWebView(this)
                    val token = launchToken
                    if (token != null) {
                        loadUrl("$AUTHORITY_URL/?token=$token")
                    } else {
                        loadUrl("$AUTHORITY_URL/")
                    }
                }
            },
        )
    }

    private fun loadInWebView(wv: WebView, url: String) {
        wv.loadUrl(url)
    }

    /** WebView 配置清单（03 §3.4 安全红线逐条） */
    private fun configureSecureWebView(wv: WebView) {
        webView = wv
        wv.settings.run {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
        }
        android.webkit.WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        android.webkit.CookieManager.getInstance().setAcceptCookie(true)
        wv.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val host = request?.url?.host ?: return true
                return !(host == "127.0.0.1" || host == "localhost")
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: android.webkit.WebResourceResponse?
            ) {
                if (request?.isForMainFrame == true && errorResponse?.statusCode == 401) {
                    appState = AppState.NeedPair("本地登录已失效，请在 PC 上用 `dsh web` 重新生成带 token 的二维码后重新扫码")
                }
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                lastInterruptedAt = System.currentTimeMillis()
            }
        }
        wv.webChromeClient = object : WebChromeClient() {
            override fun onCreateWindow(
                view: WebView?,
                dialog: Boolean,
                userGesture: Boolean,
                resultMsg: android.os.Message?
            ): Boolean = false
        }
        wv.setDownloadListener { _, _, _, _, _ -> /* 拒绝下载 */ }
        wv.setSupportMultipleWindows(false)
    }

    fun updateState(newState: AppState) {
        appState = newState
    }

    fun setLaunchToken(token: String?) {
        launchToken = token
    }
}