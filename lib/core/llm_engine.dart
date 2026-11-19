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
  String? lastErrorDetail; // teknik ayrıntı (stack trace başı)
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
        lastErrorDetail = m['detail'] as String?;
        if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
          status = EngineStatus.error; // yükleme başarısız
          _loadCompleter!.completeError(lastError!);
        } else if (status == EngineStatus.generating) {
          status = EngineStatus.ready; // model hâlâ RAM'de
        }
    }
    notifyListeners();
  }

  /// İçe aktarma ilerlemesi (0..1, bilinmiyorsa null).
  double? importProgress;

  /// Seçilen dosyayı uygulamanın özel dizinine kopyalar (dışarıdan erişilemez, kalıcı).
  /// Android'de seçici içerik URI'si verdiği için veriyi akış olarak okuyoruz.
  Future<String> importModel({
    required String name,
    String? sourcePath, // seçici gerçek dosya yolu verdiyse
    required Stream<List<int>> Function() openStream, // yol yoksa (content://) akış
    int? sourceBytes,
  }) async {
    // Uygulamanın dahili, başka uygulamaların erişemediği klasörü
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.absolute.path}/models');
    await dir.create(recursive: true);
    final targetPath = '${dir.absolute.path}/$name';

    // 1) Eski .gguf (ve yarım .part) dosyalarını tamamen sil
    for (final f in dir.listSync()) {
      if (f is File) f.deleteSync();
    }

    // Kaynak boyutu: gerçek yol varsa dosyadan, yoksa seçicinin bildirdiği değerden
    final srcFile = sourcePath != null ? File(sourcePath) : null;
    final expected = (srcFile != null && srcFile.existsSync())
        ? srcFile.lengthSync()
        : sourceBytes;

    importProgress = expected == null ? null : 0;
    notifyListeners();

    try {
      if (srcFile != null && srcFile.existsSync()) {
        // 2a) Gerçek dosya yolu: File.copy — tamamlanınca dosya kapalıdır
        await srcFile.copy(targetPath);
      } else {
        // 2b) content:// URI: akışı kopyala, flush + close bitene kadar bekle
        final sink = File(targetPath).openWrite();
        var done = 0, lastNotify = 0;
        try {
          await for (final chunk in openStream()) {
            sink.add(chunk);
            done += chunk.length;
            if (expected != null && done - lastNotify > 32 * 1024 * 1024) {
              lastNotify = done;
              importProgress = done / expected;
              notifyListeners();
            }
          }
          await sink.flush();
        } finally {
          await sink.close(); // dosya tanıtıcısı kesin kapanır
        }
      }

      // 3) Boyut doğrulaması
      final got = File(targetPath).lengthSync();
      if (got == 0 || (expected != null && got != expected)) {
        throw Exception('Dosya kopyalama eksik yapıldı ($got / ${expected ?? '?'} bayt).');
      }
      final bad = await validateGguf(targetPath);
      if (bad != null) throw Exception(bad);
    } catch (_) {
      final t = File(targetPath);
      if (t.existsSync()) t.deleteSync();
      importProgress = null;
      notifyListeners();
      rethrow;
    }

    settings.modelPath = targetPath;
    settings.modelName = name;
    settings.modelBytes = expected ?? File(targetPath).lengthSync();
    await settings.save();
    importProgress = null;
    notifyListeners();
    return targetPath;
  }

  /// Dosya geçerli bir GGUF mu? Sorun varsa açıklama, yoksa null döner.
  static Future<String?> validateGguf(String path) async {
    final f = File(path);
    if (!await f.exists()) return 'Model dosyası bulunamadı: $path';
    final len = await f.length();
    if (len < 1024 * 1024) return 'Dosya çok küçük ($len bayt); indirme yarım kalmış olabilir.';
    final raf = await f.open();
    try {
      final magic = String.fromCharCodes(await raf.read(4));
      if (magic != 'GGUF') {
        return 'Bu dosya GGUF değil (başlık: "$magic"). Doğru .gguf dosyasını seçin.';
      }
    } finally {
      await raf.close();
    }
    return null;
  }

  Map<String, dynamic> _sampler() => {
        'temperature': settings.temperature,
        'topP': settings.topP,
        'topK': settings.topK,
        'repeatPenalty': settings.repeatPenalty,
      };

  Future<void> load() async {
    final stored = settings.modelPath;
    if (stored == null) {
      lastError = 'Önce bir .gguf dosyası seçin.';
      status = EngineStatus.error;
      notifyListeners();
      return;
    }
    lastErrorDetail = null;
    final path = File(stored).absolute.path; // C++ tarafına kesin yerel yol
    final bad = await validateGguf(path);
    if (bad != null) {
      lastError = '$bad\nModeli yeniden seçin.';
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
        'expectedBytes': settings.modelBytes,
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
