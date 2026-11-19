import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'prompt_templates.dart';

/// Varsayılan sistem talimatı. Ayarlar ekranından tamamen değiştirilebilir;
/// her sorguda bağlamın en başına enjekte edilir.
const String kDefaultSystemPrompt = '''
Sen bu telefonda tamamen çevrimdışı çalışan kişisel bir asistansın.
Kullanıcının adı Burak. Türkçe yaz, aksi istenmedikçe Türkçe yanıt ver.
Soruya doğrudan cevapla: önce sonucu söyle, sonra gerekirse kısa açıklama yap.
Gereksiz giriş cümlesi, tekrar ve kalıp uyarılar kullanma.
Emin olmadığın bilgide bunu açıkça belirt, uydurma.
Hesap, metraj ve teknik konularda adım adım ve birimleriyle yaz.''';

/// Model ve örnekleme parametreleri. Değerler cihazda (SharedPreferences) saklanır.
class LlmSettings {
  String? modelPath;
  String modelName;
  int? modelBytes; // kaynak dosya boyutu (kopya doğrulaması)
  ChatTemplateKind template;
  String systemPrompt;

  // Örnekleme
  double temperature;
  double topP;
  int topK;
  double repeatPenalty;
  int maxTokens;

  // Bağlam / donanım
  int nCtx;
  int nThreads;
  int nBatch;

  LlmSettings({
    this.modelPath,
    this.modelName = '',
    this.modelBytes,
    this.template = ChatTemplateKind.chatml,
    this.systemPrompt = kDefaultSystemPrompt,
    this.temperature = 0.7,
    this.topP = 0.9,
    this.topK = 40,
    this.repeatPenalty = 1.1,
    this.maxTokens = 512,
    this.nCtx = 2048,
    this.nThreads = 4,
    this.nBatch = 512,
  });

  /// Örnekleme parametrelerinin anahtarı: değişirse worker sampler'ı yeniden kurar.
  String get samplerKey => '$temperature|$topP|$topK|$repeatPenalty';

  Map<String, dynamic> toJson() => {
        'modelPath': modelPath,
        'modelName': modelName,
        'modelBytes': modelBytes,
        'template': template.name,
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'topP': topP,
        'topK': topK,
        'repeatPenalty': repeatPenalty,
        'maxTokens': maxTokens,
        'nCtx': nCtx,
        'nThreads': nThreads,
        'nBatch': nBatch,
      };

  factory LlmSettings.fromJson(Map<String, dynamic> j) => LlmSettings(
        modelPath: j['modelPath'] as String?,
        modelName: (j['modelName'] as String?) ?? '',
        modelBytes: (j['modelBytes'] as num?)?.toInt(),
        template: ChatTemplateKind.values.firstWhere(
          (e) => e.name == j['template'],
          orElse: () => ChatTemplateKind.chatml,
        ),
        systemPrompt: (j['systemPrompt'] as String?) ?? kDefaultSystemPrompt,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
        topP: (j['topP'] as num?)?.toDouble() ?? 0.9,
        topK: (j['topK'] as num?)?.toInt() ?? 40,
        repeatPenalty: (j['repeatPenalty'] as num?)?.toDouble() ?? 1.1,
        maxTokens: (j['maxTokens'] as num?)?.toInt() ?? 512,
        nCtx: (j['nCtx'] as num?)?.toInt() ?? 2048,
        nThreads: (j['nThreads'] as num?)?.toInt() ?? 4,
        nBatch: (j['nBatch'] as num?)?.toInt() ?? 512,
      );

  static const _key = 'llm_settings_v1';

  static Future<LlmSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return LlmSettings();
    try {
      return LlmSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return LlmSettings();
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(toJson()));
  }
}
