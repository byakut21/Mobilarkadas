import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'llm_settings.dart';
import 'llm_worker.dart';
import 'prompt_templates.dart';

enum EngineStatus { idle, loading, ready, generating, error }

/// Uygulama durumu + worker isolate yöneticisi.
class LlmEngine extends ChangeNotifier {
  LlmEngine(this.settings);

  final LlmSettings settings;
  final List<ChatMessage> messages = [];

  EngineStatus status = EngineStatus.idle;
  String? lastError;
  String stats = '';

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<void>? _loadCompleter;

  bool get isLoaded =>
      status == EngineStatus.ready || status == EngineStatus.generating;

  Future<void> _ensureWorker() async {
    if (_toWorker != null) return;
    final rp = ReceivePort();
    _fromWorker = rp;
    final ready = Completer<SendPort>();
    rp.listen((dynamic raw) {
      final m = raw as Map;
      if (m['type'] == 'ready') {
        ready.complete(m['port'] as SendPort);
      } else {
        _onEvent(m);
      }
    });
    _isolate = await Isolate.spawn(llmWorkerMain, rp.sendPort,
        debugName: 'llm-worker');
    _toWorker = await ready.future;
  }

  void _onEvent(Map m) {
    switch (m['type']) {
      case 'loaded':
        status = EngineStatus.ready;
        stats = 'Model ${(m['ms'] as int) / 1000} sn\'de yüklendi';
        _loadCompleter?.complete();
      case 'token':
        if (messages.isNotEmpty && messages.last.role == 'assistant') {
          messages.last.text += m['text'] as String;
        }
      case 'done':
        status = EngineStatus.ready;
        final n = m['tokens'] as int;
        final ms = (m['ms'] as int).clamp(1, 1 << 31);
        stats = '$n token • ${(n * 1000 / ms).toStringAsFixed(1)} token/sn'
            '${m['stopped'] == true ? ' • durduruldu' : ''}';
        if (messages.isNotEmpty) {
          messages.last.text = messages.last.text.trim();
        }
      case 'unloaded':
        status = EngineStatus.idle;
        stats = 'Model RAM\'den boşaltıldı';
      case 'error':
        lastError = m['message'] as String;
        if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
          status = EngineStatus.error; // yükleme başarısız
          _loadCompleter!.completeError(lastError!);
        } else if (status == EngineStatus.generating) {
          status = EngineStatus.ready; // model hâlâ RAM'de
        }
    }
    notifyListeners();
  }

  /// Seçilen dosyayı uygulamanın özel dizinine taşır (dışarıdan erişilemez, kalıcı).
  Future<String> importModel(String pickedPath, String name) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/models');
    await dir.create(recursive: true);
    final dest = File('${dir.path}/$name');
    final src = File(pickedPath);
    if (src.path != dest.path) {
      try {
        await src.rename(dest.path); // aynı bölümdeyse anında
      } on FileSystemException {
        await src.copy(dest.path);
        await src.delete().catchError((_) => src);
      }
    }
    // Eski modelleri temizle (depolama tasarrufu)
    await for (final f in dir.list()) {
      if (f is File && f.path != dest.path) await f.delete();
    }
    settings.modelPath = dest.path;
    settings.modelName = name;
    await settings.save();
    notifyListeners();
    return dest.path;
  }

  Map<String, dynamic> _sampler() => {
        'temperature': settings.temperature,
        'topP': settings.topP,
        'topK': settings.topK,
        'repeatPenalty': settings.repeatPenalty,
      };

  Future<void> load() async {
    final path = settings.modelPath;
    if (path == null || !File(path).existsSync()) {
      lastError = 'Model dosyası bulunamadı. Önce .gguf seçin.';
      status = EngineStatus.error;
      notifyListeners();
      return;
    }
    await _ensureWorker();
    status = EngineStatus.loading;
    lastError = null;
    stats = 'RAM\'e yükleniyor…';
    notifyListeners();
    _loadCompleter = Completer<void>();
    _toWorker!.send({
      'cmd': 'load',
      'args': {
        'path': path,
        'nCtx': settings.nCtx,
        'nBatch': settings.nBatch,
        'nThreads': settings.nThreads,
      },
      'sampler': _sampler(),
      'samplerKey': settings.samplerKey,
    });
    try {
      await _loadCompleter!.future;
    } catch (_) {/* hata durumu _onEvent'te işlendi */}
  }

  void unload() => _toWorker?.send({'cmd': 'unload'});

  void send(String text) {
    if (!isLoaded || status == EngineStatus.generating) return;
    final t = text.trim();
    if (t.isEmpty) return;
    messages.add(ChatMessage('user', t));
    final prompt = buildPrompt(
      kind: settings.template,
      systemPrompt: settings.systemPrompt, // her sorguda enjekte
      history: messages,
      nCtx: settings.nCtx,
      maxTokens: settings.maxTokens,
    );
    messages.add(ChatMessage('assistant', ''));
    status = EngineStatus.generating;
    lastError = null;
    notifyListeners();
    _toWorker!.send({
      'cmd': 'generate',
      'prompt': prompt,
      'maxTokens': settings.maxTokens,
      'stops': settings.template.stopStrings,
      'sampler': _sampler(),
      'samplerKey': settings.samplerKey,
    });
  }

  void stop() => _toWorker?.send({'cmd': 'stop'});

  void clearChat() {
    if (status == EngineStatus.generating) return;
    messages.clear();
    stats = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _toWorker?.send({'cmd': 'shutdown'});
    _fromWorker?.close();
    _isolate = null;
    super.dispose();
  }
}
