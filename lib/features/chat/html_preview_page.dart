import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';

/// Full-screen interactive preview of an HTML/CSS/JS file the agent handed to
/// the user. Renders in a real WebView so relative assets (styles, scripts,
/// images) resolve against the bridge, and offers a download action.
class HtmlPreviewPage extends StatefulWidget {
  final Attachment attachment;
  final String url;
  const HtmlPreviewPage(
      {super.key, required this.attachment, required this.url});

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _download() async {
    final repo = context.read<AppState>().repo;
    final path = widget.attachment.path;
    if (path == null) return;
    try {
      final localPath = await repo.downloadFile(path);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(localPath)]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.attachment.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              icon: const Icon(Icons.download_outlined),
              onPressed: _download,
              tooltip: 'Download'),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            Container(
              color: scheme.surface,
              alignment: Alignment.center,
              child: const CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
