import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/llm_engine.dart';
import '../core/llm_settings.dart';
import '../core/prompt_templates.dart';

/// Model seçme, RAM'e yükleme ve parametre ayarları.
class ModelScreen extends StatefulWidget {
  const ModelScreen({super.key, required this.engine});
  final LlmEngine engine;

  @override
  State<ModelScreen> createState() => _ModelScreenState();
}

class _ModelScreenState extends State<ModelScreen> {
  late final TextEditingController _sys;
  bool _importing = false;

  LlmEngine get e => widget.engine;
  LlmSettings get s => e.settings;

  @override
  void initState() {
    super.initState();
    _sys = TextEditingController(text: s.systemPrompt);
  }

  @override
  void dispose() {
    _sys.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    s.systemPrompt = _sys.text;
    await s.save();
  }

  Future<void> _pick() async {
    // .gguf için kayıtlı MIME türü yok; her dosyayı gösterip uzantıyı kendimiz kontrol ediyoruz.
    final f = await FilePicker.pickFile(type: FileType.any);
    if (f == null) return;
    if (!f.name.toLowerCase().endsWith('.gguf')) {
      _snack('Lütfen .gguf uzantılı bir dosya seçin.');
      return;
    }
    if (e.isLoaded) e.unload();
    setState(() => _importing = true);
    try {
      await e.importModel(
        name: f.name,
        bytes: f.readAsByteStream(),
        totalBytes: f.lengthSync(),
      );
      _snack('Model içe aktarıldı: ${f.name}');
    } catch (err) {
      _snack('İçe aktarma hatası: $err');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _snack(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  String _size() {
    final p = s.modelPath;
    if (p == null) return '';
    final f = File(p);
    if (!f.existsSync()) return 'dosya yok';
    final gb = f.lengthSync() / (1024 * 1024 * 1024);
    return '${gb.toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: e,
      builder: (context, _) {
        final loading = e.status == EngineStatus.loading;
        final busy = loading || _importing || e.status == EngineStatus.generating;
        return PopScope(
          onPopInvokedWithResult: (_, __) => _save(),
          child: Scaffold(
            appBar: AppBar(title: const Text('Model ve Parametreler')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ---- Model dosyası ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Model dosyası',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(s.modelName.isEmpty
                            ? 'Seçilmedi'
                            : '${s.modelName}  •  ${_size()}'),
                        const SizedBox(height: 4),
                        Text(
                          switch (e.status) {
                            EngineStatus.idle => 'Durum: RAM\'de değil',
                            EngineStatus.loading => 'Durum: yükleniyor…',
                            EngineStatus.ready => 'Durum: RAM\'de, hazır',
                            EngineStatus.generating => 'Durum: yanıt üretiyor',
                            EngineStatus.error => 'Durum: hata',
                          },
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (e.stats.isNotEmpty)
                          Text(e.stats,
                              style: Theme.of(context).textTheme.bodySmall),
                        if (_importing || loading)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: LinearProgressIndicator(
                              value: _importing ? e.importProgress : null,
                            ),
                          ),
                        if (_importing)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              e.importProgress == null
                                  ? 'Kopyalanıyor…'
                                  : 'Kopyalanıyor… %${(e.importProgress! * 100).toStringAsFixed(0)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: busy ? null : _pick,
                              icon: const Icon(Icons.folder_open),
                              label: const Text('.gguf seç'),
                            ),
                            FilledButton.icon(
                              onPressed: busy || s.modelPath == null
                                  ? null
                                  : () async {
                                      await _save();
                                      await e.load();
                                    },
                              icon: const Icon(Icons.memory),
                              label: Text(e.isLoaded
                                  ? 'Yeniden yükle'
                                  : 'RAM\'e yükle'),
                            ),
                            if (e.isLoaded)
                              TextButton.icon(
                                onPressed: busy ? null : e.unload,
                                icon: const Icon(Icons.eject),
                                label: const Text('Boşalt'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // ---- Şablon ----
                const SizedBox(height: 16),
                DropdownButtonFormField<ChatTemplateKind>(
                  value: s.template,
                  decoration: const InputDecoration(
                    labelText: 'Sohbet şablonu (model ailesi)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final k in ChatTemplateKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (v) => setState(() {
                    if (v != null) s.template = v;
                    _save();
                  }),
                ),

                // ---- Örnekleme ----
                _section('Örnekleme (anında uygulanır)'),
                _slider('temperature', s.temperature, 0, 2, 40,
                    (v) => s.temperature = v, fmt: 2),
                _slider('top_p', s.topP, 0.05, 1, 19, (v) => s.topP = v,
                    fmt: 2),
                _slider('top_k', s.topK.toDouble(), 1, 100, 99,
                    (v) => s.topK = v.round()),
                _slider('repeat_penalty', s.repeatPenalty, 1, 1.5, 50,
                    (v) => s.repeatPenalty = v, fmt: 2),
                _slider('max_tokens', s.maxTokens.toDouble(), 16, 4096, 255,
                    (v) => s.maxTokens = v.round()),

                // ---- Bağlam / donanım ----
                _section('Bağlam ve donanım (yeniden yükleme gerekir)'),
                DropdownButtonFormField<int>(
                  value: s.nCtx,
                  decoration: const InputDecoration(
                    labelText: 'Bağlam penceresi (n_ctx)',
                    helperText: 'Büyüdükçe RAM kullanımı artar',
                    border: OutlineInputBorder(),
                  ),
                  items: const [512, 1024, 2048, 4096, 8192]
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: (v) => setState(() {
                    if (v != null) s.nCtx = v;
                    _save();
                  }),
                ),
                const SizedBox(height: 8),
                _slider('CPU thread', s.nThreads.toDouble(), 1, 8, 7,
                    (v) => s.nThreads = v.round()),

                // ---- Sistem talimatı ----
                _section('Sistem talimatı (her sorguda bağlamın başına eklenir)'),
                TextField(
                  controller: _sys,
                  minLines: 6,
                  maxLines: 16,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Modelin rolü ve yanıt biçimi…',
                  ),
                  onChanged: (_) => _save(),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() {
                      _sys.text = kDefaultSystemPrompt;
                      _save();
                    }),
                    child: const Text('Varsayılana dön'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _slider(String label, double value, double min, double max,
      int divisions, void Function(double) set,
      {int fmt = 0}) {
    return Row(
      children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: value.toStringAsFixed(fmt),
            onChanged: (v) => setState(() => set(v)),
            onChangeEnd: (_) => _save(),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(value.toStringAsFixed(fmt), textAlign: TextAlign.end),
        ),
      ],
    );
  }
}
