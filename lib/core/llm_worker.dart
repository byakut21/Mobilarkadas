// Ayrı bir Dart isolate'inde çalışan llama.cpp katmanı.
// UI donmasın diye model yükleme ve token üretimi ana thread'den tamamen ayrıdır.
//
// llama_cpp_dart 0.2.0 API'sine göre yazıldı. Paket sürümünü değiştirirseniz
// yalnızca bu dosyadaki `_createLlama` ve üretim döngüsünü uyarlamanız yeterlidir.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// Worker giriş noktası. [mainPort] ana isolate'e olay gönderir.
void llmWorkerMain(SendPort mainPort) {
  final inbox = ReceivePort();
  mainPort.send({'type': 'ready', 'port': inbox.sendPort});

  Llama? llama;
  Map<String, dynamic>? loadArgs; // son yükleme parametreleri (sampler değişince yeniden kurmak için)
  String? samplerKey;
  var stopRequested = false;
  var busy = false;

  Llama createLlama(Map<String, dynamic> a, Map<String, dynamic> s) {
    // Android'de .so dosyaları jniLibs'ten uygulamanın native lib dizinine çıkarılır;
    // dlopen sadece dosya adıyla bulur.
    // llama_cpp_dart Android'de libmtmd.so'yu açar (libllama/libggml'e bağlıdır).
    Llama.libraryPath = 'libmtmd.so';

    final mp = ModelParams();
    // CPU-only (Vulkan/OpenCL derlemediyseniz 0 kalmalı)
    mp.nGpuLayers = 0;

    final cp = ContextParams()
      ..nCtx = a['nCtx'] as int
      ..nBatch = a['nBatch'] as int
      ..nThreads = a['nThreads'] as int
      ..nThreadsBatch = a['nThreads'] as int
      ..nPredict = -1; // sınırı kendimiz uyguluyoruz (maxTokens)

    final sp = SamplerParams()
      ..temp = (s['temperature'] as num).toDouble()
      ..topP = (s['topP'] as num).toDouble()
      ..topK = s['topK'] as int
      ..penaltyRepeat = (s['repeatPenalty'] as num).toDouble();

    return Llama(
      a['path'] as String,
      modelParams: mp,
      contextParams: cp,
      samplerParams: sp,
    );
  }

  inbox.listen((dynamic raw) async {
    final msg = raw as Map;
    final cmd = msg['cmd'] as String;

    switch (cmd) {
      case 'load':
        try {
          llama?.dispose();
          llama = null;
          final sw = Stopwatch()..start();
          loadArgs = Map<String, dynamic>.from(msg['args'] as Map);
          final s = Map<String, dynamic>.from(msg['sampler'] as Map);
          final path = File(loadArgs!['path'] as String).absolute.path;
          if (!File(path).existsSync()) {
            throw StateError('Dosya yok: $path');
          }
          loadArgs!['path'] = path;
          llama = createLlama(loadArgs!, s);
          samplerKey = msg['samplerKey'] as String;
          mainPort.send({'type': 'loaded', 'ms': sw.elapsedMilliseconds});
        } catch (e, st) {
          llama = null;
          mainPort.send({
            'type': 'error',
            'message': _explainLoadError(e, loadArgs),
            'detail': '$e\n${st.toString().split('\n').take(6).join('\n')}',
          });
        }

      case 'generate':
        if (llama == null) {
          mainPort.send({'type': 'error', 'message': 'Önce bir model yükleyin.'});
          return;
        }
        if (busy) return;
        busy = true;
        stopRequested = false;
        try {
          // Örnekleme parametreleri değiştiyse sampler'ı yeniden kur.
          // (0.2.x'te sampler bağlamla birlikte kurulur; model mmap'li olduğu için hızlıdır.)
          final key = msg['samplerKey'] as String;
          if (key != samplerKey) {
            llama!.dispose();
            llama = createLlama(loadArgs!, Map<String, dynamic>.from(msg['sampler'] as Map));
            samplerKey = key;
          }

          final prompt = msg['prompt'] as String;
          final maxTokens = msg['maxTokens'] as int;
          final stops = (msg['stops'] as List).cast<String>();

          llama!.clear(); // KV-cache sıfırla: her sorguda sistem talimatı + geçmiş baştan verilir
          llama!.setPrompt(prompt);

          final sw = Stopwatch()..start();
          final out = StringBuffer();
          var emitted = 0; // UI'ye gönderilen karakter sayısı
          var n = 0;

          while (!stopRequested && n < maxTokens) {
            final (token, done) = llama!.getNext();
            n++;
            out.write(token);

            // Durdurma dizisi kontrolü
            final text = out.toString();
            var cut = -1;
            for (final st in stops) {
              final i = text.indexOf(st);
              if (i >= 0 && (cut < 0 || i < cut)) cut = i;
            }
            if (cut >= 0) {
              if (cut > emitted) {
                mainPort.send({'type': 'token', 'text': text.substring(emitted, cut)});
              }
              break;
            }

            // Bir durdurma dizisinin başlangıcı olabilecek son kısmı bekletiyoruz
            final safeEnd = text.length - _longest(stops);
            if (safeEnd > emitted) {
              mainPort.send({'type': 'token', 'text': text.substring(emitted, safeEnd)});
              emitted = safeEnd;
            }

            if (done) {
              if (text.length > emitted) {
                mainPort.send({'type': 'token', 'text': text.substring(emitted)});
              }
              break;
            }
            // Event loop'a nefes aldır: 'stop' komutu bu arada işlenebilsin.
            await Future<void>.delayed(Duration.zero);
          }

          final ms = sw.elapsedMilliseconds;
          mainPort.send({
            'type': 'done',
            'tokens': n,
            'ms': ms,
            'stopped': stopRequested,
          });
        } catch (e) {
          mainPort.send({'type': 'error', 'message': 'Üretim hatası: $e'});
        } finally {
          busy = false;
        }

      case 'stop':
        stopRequested = true;

      case 'unload':
        stopRequested = true;
        llama?.dispose();
        llama = null;
        samplerKey = null;
        mainPort.send({'type': 'unloaded'});

      case 'shutdown':
        llama?.dispose();
        llama = null;
        inbox.close();
        Isolate.exit();
    }
  });
}

int _longest(List<String> s) =>
    s.fold<int>(0, (m, e) => e.length > m ? e.length : m);

/// C++ / FFI hatasını anlaşılır Türkçe açıklamaya çevirir.
String _explainLoadError(Object e, Map<String, dynamic>? a) {
  final t = e.toString();
  final path = a?['path'];
  if (t.contains('Failed to load dynamic library') || t.contains('dlopen')) {
    return 'llama.cpp kütüphanesi açılamadı (libmtmd.so). APK bu cihazın işlemcisiyle '
        'uyumsuz olabilir (eski ARM). Hata: $t';
  }
  if (t.contains('Could not load model')) {
    return 'llama.cpp modeli açamadı: $path\n'
        'Olası sebepler: dosya bozuk/yarım, ya da model mimarisi bu llama.cpp sürümünden yeni '
        '(daha eski/yaygın bir model deneyin, ör. Qwen2.5 veya Llama 3.2). '
        'RAM yetmiyorsa daha küçük bir Q4 modeli seçin.';
  }
  if (t.contains('Could not create context')) {
    return 'Model açıldı ama bağlam oluşturulamadı: RAM yetersiz. '
        'n_ctx değerini düşürün (ör. 1024) veya daha küçük model seçin.';
  }
  return 'Model yüklenemedi: $t';
}
