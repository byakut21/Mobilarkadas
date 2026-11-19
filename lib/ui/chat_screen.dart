import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/llm_engine.dart';
import 'model_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.engine});
  final LlmEngine engine;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  LlmEngine get e => widget.engine;

  @override
  void initState() {
    super.initState();
    e.addListener(_autoScroll);
  }

  @override
  void dispose() {
    e.removeListener(_autoScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    e.send(_input.text);
    _input.clear();
  }

  void _openModel() => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ModelScreen(engine: e)),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: e,
      builder: (context, _) {
        final generating = e.status == EngineStatus.generating;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Yerel Asistan'),
                Text(
                  e.isLoaded
                      ? e.settings.modelName
                      : 'Model yüklü değil • çevrimdışı',
                  style: Theme.of(context).textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Sohbeti temizle',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: generating ? null : e.clearChat,
              ),
              IconButton(
                tooltip: 'Model ve parametreler',
                icon: const Icon(Icons.tune),
                onPressed: _openModel,
              ),
            ],
          ),
          body: Column(
            children: [
              if (e.lastError != null)
                MaterialBanner(
                  content: Text(e.lastError!),
                  backgroundColor: cs.errorContainer,
                  actions: [
                    TextButton(
                      onPressed: () => setState(() => e.lastError = null),
                      child: const Text('Kapat'),
                    ),
                  ],
                ),
              Expanded(
                child: e.messages.isEmpty
                    ? _EmptyState(loaded: e.isLoaded, onOpen: _openModel)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: e.messages.length,
                        itemBuilder: (_, i) {
                          final m = e.messages[i];
                          final isUser = m.role == 'user';
                          final typing = !isUser &&
                              generating &&
                              i == e.messages.length - 1;
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: GestureDetector(
                              onLongPress: () {
                                Clipboard.setData(ClipboardData(text: m.text));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Kopyalandı')),
                                );
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.all(12),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.85,
                                ),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? cs.primaryContainer
                                      : cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: SelectableText(
                                  m.text.isEmpty && typing ? '…' : m.text,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (e.stats.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(e.stats,
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          enabled: e.isLoaded,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: e.isLoaded
                                ? 'Mesaj yaz…'
                                : 'Önce model yükleyin',
                            border: const OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.all(Radius.circular(20)),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      generating
                          ? IconButton.filledTonal(
                              tooltip: 'Durdur',
                              icon: const Icon(Icons.stop),
                              onPressed: e.stop,
                            )
                          : IconButton.filled(
                              tooltip: 'Gönder',
                              icon: const Icon(Icons.send),
                              onPressed: e.isLoaded ? _send : null,
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.loaded, required this.onOpen});
  final bool loaded;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            Text(
              loaded
                  ? 'Model hazır. Tüm işlem cihazında, ağ bağlantısı yok.'
                  : 'Cihazındaki bir .gguf modelini seçip RAM\'e yükle.',
              textAlign: TextAlign.center,
            ),
            if (!loaded) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.memory),
                label: const Text('Model seç'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
