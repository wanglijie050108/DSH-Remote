// DSH 页：隧道 READY 后经本地代理加载（纯浏览器路径；隧道重建 6s 内的请求会挂，需重试）。
// AppBar 标题实时显示诊断（readyState/ModuleLoader.mode/错误），自动探针跨越断线窗口。
// 看门狗：主 bundle 被断线掐死后浏览器不会自动重试（024 白屏机制）→ 检测「卡 queue 且无正文」
// 连续 4 次（≈12s）自动 reload，直至 SPA 启动。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:remotedsh_flutter/service/harness.dart';

class DshWebPage extends StatefulWidget {
  const DshWebPage({super.key});

  @override
  State<DshWebPage> createState() => _DshWebPageState();
}

class _DshWebPageState extends State<DshWebPage> {
  late final WebViewController _controller;
  String _status = '加载中…';
  Timer? _probeTimer;
  int _stuckCount = 0;
  bool _spaUp = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFF8E1))
      ..setOnConsoleMessage((m) {
        final msg = m.message.length > 200 ? m.message.substring(0, 200) : m.message;
        Harness.instance.log('[console.${m.level.name}] $msg');
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          _set('onPageFinished');
          Harness.instance.log('[DSH页] onPageFinished url=$url');
        },
        onWebResourceError: (e) {
          Harness.instance
              .log('[DSH页] 资源错误 isMain=${e.isForMainFrame} ${e.description}');
        },
      ));
    _load();
    _probeTimer = Timer.periodic(const Duration(seconds: 3), (_) => _probeBoot());
  }

  void _set(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _load() async {
    final url = Harness.instance.dshUrl;
    Harness.instance.log('DSH Web 加载 $url');
    _set('加载中…');
    try {
      await _controller.loadRequest(Uri.parse(url));
    } catch (e) {
      _set('loadRequest 异常');
      Harness.instance.log('[DSH页] loadRequest 异常: $e');
    }
  }

  Future<void> _probeBoot() async {
    Object? r;
    try {
      r = await _controller.runJavaScriptReturningResult(
          'JSON.stringify({rs:document.readyState,ml:(window.__ModuleLoader__&&window.__ModuleLoader__.mode)||"-",bl:((document.body&&document.body.innerText)||"").length})');
    } catch (e) {
      _set('probe 失败');
      Harness.instance.log('[DSH页] probe 失败: $e');
      return;
    }
    Map? m;
    if (r is Map) {
      m = r;
    } else if (r is String) {
      var s = r.trim();
      if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
        s = s.substring(1, s.length - 1); // js 字符串字面量剥壳
      }
      try {
        final v = json.decode(s);
        if (v is Map) m = v;
      } catch (_) {}
    }
    if (m == null) return;
    final rs = m['rs'];
    final ml = m['ml'];
    final bl = m['bl'];
    Harness.instance.log('[DSH页] probe rs=$rs ml=$ml bl=$bl');
    if (!_spaUp && ml is String && ml != 'queue' && ml != '-') {
      _spaUp = true;
      _stuckCount = 0;
      _set('SPA 启动 (mode=$ml)');
      return;
    }
    if (!_spaUp && bl is num && bl > 0) {
      _spaUp = true;
      _stuckCount = 0;
      _set('页面有内容 ($bl 字符)');
      return;
    }
    if (rs == 'complete' && ml == 'queue' && bl == 0) {
      _stuckCount++;
      _set('卡 queue ($_stuckCount/4)');
      if (_stuckCount >= 4 && !_spaUp) {
        _stuckCount = 0;
        Harness.instance.log('[DSH页] 主 bundle 卡 queue → reload 重试');
        _load();
      }
    } else {
      _stuckCount = 0;
      _set('rs=$rs ml=$ml bl=$bl');
    }
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_status, style: const TextStyle(fontSize: 13)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _probeBoot),
          IconButton(
              icon: const Icon(Icons.replay),
              onPressed: () {
                _stuckCount = 0;
                _spaUp = false;
                _load();
              }),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
