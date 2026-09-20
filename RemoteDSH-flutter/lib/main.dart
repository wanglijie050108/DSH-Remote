// RemoteDSH 鸿蒙真机验证工具（B1-flutter_webrtc-ohos 版）
// 架构：signal(ws) → punch(offer/answer, pin 红线) → WebRTC P2P（flutter_webrtc 原生栈）
//       → 隧道帧协议(11B 头) → 本地代理 127.0.0.1:13080 → WebView 加载 DSH
import 'package:flutter/material.dart';

// 3.7.12 工具链未将 path_provider_ohos 的 dartPluginClass 写入 Dart 注册表，
// 其 native 侧只实现 pigeon 通道 → 必须手动 registerWith，否则 MissingPluginException
import 'package:path_provider_ohos/path_provider_ohos.dart';

import 'package:remotedsh_flutter/service/harness.dart';
import 'package:remotedsh_flutter/ui/dsh_web_page.dart';

void main() {
  PathProviderOhos.registerWith();
  runApp(const RemoteDshApp());
}

class RemoteDshApp extends StatelessWidget {
  const RemoteDshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteDSH',
      theme: ThemeData(primarySwatch: Colors.indigo, useMaterial3: false),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _uriCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Harness.instance.loadState();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RemoteDSH 验证工具 (B1)')),
      body: AnimatedBuilder(
        animation: Harness.instance,
        builder: (context, _) {
          final h = Harness.instance;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _statusCard(h),
              _actionBar(h),
              const Divider(height: 1),
              Expanded(child: _logView(h)),
            ],
          );
        },
      ),
    );
  }

  String _phaseLabel(HarnessPhase p) {
    switch (p) {
      case HarnessPhase.idle:
        return 'IDLE';
      case HarnessPhase.pairing:
        return '配对中';
      case HarnessPhase.paired:
        return '已配对';
      case HarnessPhase.punching:
        return '打洞中';
      case HarnessPhase.connecting:
        return 'ICE 协商中';
      case HarnessPhase.ready:
        return '隧道就绪';
      case HarnessPhase.needPair:
        return '需重新扫码';
    }
  }

  Widget _statusCard(Harness h) {
    final phaseText = _phaseLabel(h.phase);
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                h.phase == HarnessPhase.ready
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: h.phase == HarnessPhase.ready
                    ? Colors.green
                    : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text('状态: $phaseText',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (h.proxyOn)
                const Chip(label: Text('代理 13080'), visualDensity: VisualDensity.compact),
            ]),
            if (h.pairId != null)
              Text('pair=${h.pairId} agent=${h.agentId ?? '-'}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            Text('fp=${(h.pinnedFp ?? '-').substring(0, (h.pinnedFp ?? '-').length > 16 ? 16 : (h.pinnedFp ?? '-').length)}…',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  Widget _actionBar(Harness h) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _uriCtrl,
              decoration: const InputDecoration(
                hintText: '粘贴 dshlink://pair?… （电脑 DSH 出二维码后复制链接）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              final uri = _uriCtrl.text.trim();
              if (uri.isNotEmpty) {
                Harness.instance.scan(uri);
              }
            },
            child: const Text('配对'),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: h.resume,
              child: const Text('免扫码重连'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: h.unpair,
              child: const Text('解除配对'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: h.phase == HarnessPhase.ready
                  ? () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const DshWebPage()))
                  : null,
              child: const Text('打开 DSH'),
            ),
          ),
        ]),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _logView(Harness h) {
    return Container(
      color: const Color(0xFF101418),
      child: ListView.builder(
        reverse: true,
        itemCount: h.logLines.length,
        itemBuilder: (context, i) {
          final idx = h.logLines.length - 1 - i;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Text(
              h.logLines[idx],
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11, color: Color(0xFF9CDCFE)),
            ),
          );
        },
      ),
    );
  }
}
