/// Sohbet mesajı.
class ChatMessage {
  final String role; // 'user' | 'assistant'
  String text;
  ChatMessage(this.role, this.text);
}

/// Model ailesine göre sohbet şablonları. Modelin eğitildiği şablon seçilmezse
/// çıktı kalitesi ciddi düşer (GGUF kartında yazar).
enum ChatTemplateKind { chatml, llama3, gemma, mistral, phi3 }

extension ChatTemplateLabel on ChatTemplateKind {
  String get label => switch (this) {
        ChatTemplateKind.chatml => 'ChatML (Qwen, Hermes, Yi…)',
        ChatTemplateKind.llama3 => 'Llama 3.x',
        ChatTemplateKind.gemma => 'Gemma 2/3',
        ChatTemplateKind.mistral => 'Mistral / Mixtral',
        ChatTemplateKind.phi3 => 'Phi-3 / Phi-4 mini',
      };

  /// Çıktıda görülürse üretimi kesen diziler (EOG token'ı kaçarsa yedek).
  List<String> get stopStrings => switch (this) {
        ChatTemplateKind.chatml => ['<|im_end|>', '<|im_start|>'],
        ChatTemplateKind.llama3 => ['<|eot_id|>', '<|start_header_id|>'],
        ChatTemplateKind.gemma => ['<end_of_turn>', '<start_of_turn>'],
        ChatTemplateKind.mistral => ['</s>', '[INST]'],
        ChatTemplateKind.phi3 => ['<|end|>', '<|user|>'],
      };
}

/// Sistem talimatını her sorguda bağlamın başına enjekte ederek tam prompt üretir.
/// [history] son mesaj kullanıcı mesajı olacak şekilde verilir.
/// Bağlam penceresini aşmamak için en eski tur çiftleri atılır (kaba tahmin: ~3.5 karakter/token).
String buildPrompt({
  required ChatTemplateKind kind,
  required String systemPrompt,
  required List<ChatMessage> history,
  required int nCtx,
  required int maxTokens,
}) {
  final budgetChars = ((nCtx - maxTokens).clamp(256, nCtx) * 3.5).floor();
  var msgs = List<ChatMessage>.from(history);
  String p = _render(kind, systemPrompt, msgs);
  while (p.length > budgetChars && msgs.length > 1) {
    msgs = msgs.sublist(msgs.length > 2 ? 2 : 1); // en eski user+assistant çiftini at
    p = _render(kind, systemPrompt, msgs);
  }
  return p;
}

String _render(ChatTemplateKind kind, String sys, List<ChatMessage> msgs) {
  final b = StringBuffer();
  final s = sys.trim();
  switch (kind) {
    case ChatTemplateKind.chatml:
      if (s.isNotEmpty) b.write('<|im_start|>system\n$s<|im_end|>\n');
      for (final m in msgs) {
        b.write('<|im_start|>${m.role}\n${m.text}<|im_end|>\n');
      }
      b.write('<|im_start|>assistant\n');
    case ChatTemplateKind.llama3:
      // <|begin_of_text|> tokenizer tarafından (add_bos) eklenir.
      if (s.isNotEmpty) {
        b.write('<|start_header_id|>system<|end_header_id|>\n\n$s<|eot_id|>');
      }
      for (final m in msgs) {
        b.write('<|start_header_id|>${m.role}<|end_header_id|>\n\n${m.text}<|eot_id|>');
      }
      b.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    case ChatTemplateKind.gemma:
      // Gemma'da system rolü yok: talimat ilk kullanıcı mesajının başına eklenir.
      for (var i = 0; i < msgs.length; i++) {
        final m = msgs[i];
        final role = m.role == 'assistant' ? 'model' : 'user';
        final text = (i == 0 && s.isNotEmpty) ? '$s\n\n${m.text}' : m.text;
        b.write('<start_of_turn>$role\n$text<end_of_turn>\n');
      }
      b.write('<start_of_turn>model\n');
    case ChatTemplateKind.mistral:
      for (var i = 0; i < msgs.length; i++) {
        final m = msgs[i];
        if (m.role == 'user') {
          final text = (i == 0 && s.isNotEmpty) ? '$s\n\n${m.text}' : m.text;
          b.write('[INST] $text [/INST]');
        } else {
          b.write('${m.text}</s>');
        }
      }
    case ChatTemplateKind.phi3:
      if (s.isNotEmpty) b.write('<|system|>\n$s<|end|>\n');
      for (final m in msgs) {
        b.write('<|${m.role}|>\n${m.text}<|end|>\n');
      }
      b.write('<|assistant|>\n');
  }
  return b.toString();
}
