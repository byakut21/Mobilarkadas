# Yerel Asistan — %100 çevrimdışı GGUF sohbet (Flutter + llama.cpp)

Telefonda `.gguf` modeli RAM'e yükleyip tamamen cihaz içinde çalıştıran Android uygulaması.
APK'da `INTERNET` izni yoktur; uygulama hiçbir sunucuya bağlanamaz.

## Dosya yapısı

```
yerel_asistan/
├── pubspec.yaml
├── lib/
│   ├── main.dart                    # Uygulama girişi
│   ├── core/
│   │   ├── llm_settings.dart        # Parametreler + sistem talimatı (yerel kayıt)
│   │   ├── prompt_templates.dart    # ChatML / Llama3 / Gemma / Mistral / Phi-3 şablonları,
│   │   │                            # sistem talimatı enjeksiyonu, bağlam kırpma
│   │   ├── llm_engine.dart          # Durum yönetimi, isolate köprüsü, model içe aktarma
│   │   └── llm_worker.dart          # Ayrı isolate: llama.cpp yükleme + token akışı
│   └── ui/
│       ├── chat_screen.dart         # Sohbet ekranı (akış, durdur, kopyala)
│       └── model_screen.dart        # .gguf seç, RAM'e yükle/boşalt, parametreler
├── android/app/src/
│   ├── main/AndroidManifest.xml     # INTERNET yok + tools:node="remove"
│   ├── main/res/xml/data_extraction_rules.xml  # Yedekleme kapalı
│   ├── debug/AndroidManifest.xml    # Debug'da da INTERNET kaldırılır
│   ├── profile/AndroidManifest.xml
│   └── main/jniLibs/arm64-v8a/      # (script üretir) libllama.so, libggml*.so
└── scripts/build_llama_android.sh   # llama.cpp → Android .so derlemesi
```

## Kurulum

1. İskeleti oluştur, bu dosyaları üstüne kopyala:
   ```bash
   flutter create --platforms android --org tr.burak yerel_asistan
   # bu paketteki lib/, android/app/src/, scripts/, pubspec.yaml dosyalarını üzerine yaz
   flutter pub get
   ```
2. `android/app/build.gradle.kts` içinde:
   ```kotlin
   android {
       compileSdk = 35
       ndkVersion = "26.3.11579264"
       defaultConfig {
           minSdk = 28
           targetSdk = 35
           ndk { abiFilters += listOf("arm64-v8a") }
       }
       packaging { jniLibs { useLegacyPackaging = true } }
   }
   ```
3. llama.cpp'yi derle (commit'i llama_cpp_dart sürümüyle eşleştir — scriptteki nota bak):
   ```bash
   ANDROID_NDK=$HOME/Android/Sdk/ndk/26.3.11579264 LLAMA_CPP_REF=<commit> ./scripts/build_llama_android.sh
   ```
4. APK:
   ```bash
   flutter build apk --release --target-platform android-arm64
   ```
5. İzinleri doğrula (çıktıda `android.permission.INTERNET` OLMAMALI):
   ```bash
   aapt dump permissions build/app/outputs/flutter-apk/app-release.apk
   ```

## Kullanım
- ⚙ → **.gguf seç** → dosya uygulamanın özel dizinine taşınır (ilk seferde bir kez).
- **RAM'e yükle** → hazır olunca sohbet ekranına dön.
- temperature / top_p / top_k / repeat_penalty / max_tokens anında uygulanır;
  n_ctx ve thread değişince **Yeniden yükle**.
- Doğru **sohbet şablonunu** seç (GGUF kartında yazar). Yanlış şablon = anlamsız çıktı.

## RAM rehberi (Q4_K_M)
| Model boyutu | Dosya | Önerilen cihaz RAM |
|---|---|---|
| 1–1.5B | ~1 GB | 4 GB |
| 3–4B | ~2–2.5 GB | 6–8 GB |
| 7–8B | ~4.5 GB | 12 GB+ |

## Bilinen notlar
- `llama_cpp_dart` **0.2.0** sürümüne sabitlendi (llama.cpp `b8595b16e`). Sürümü değiştirirsen `scripts/build_llama_android.sh` içindeki `LCD_TAG`ı da değiştir.
  alırsan yalnızca `lib/core/llm_worker.dart` içindeki `createLlama` alan adlarını
  (ör. `temp`, `nCtx`, `nGpuLayers`) paketteki sınıflara göre düzelt.
- Debug manifest INTERNET'i kaldırdığı için `flutter run` hot-reload çalışmaz; release APK ile test et.
- `file_picker` büyük dosyayı önce önbelleğe kopyalar; içe aktarma sırasında geçici olarak
  model boyutunun ~2 katı boş alan gerekir.

## GitHub Actions ile APK
`main` dalına her push'ta `.github/workflows/build-apk.yml` çalışır: llama.cpp'yi NDK ile derler,
Flutter iskeletini oluşturur, release APK üretir, INTERNET izni olmadığını doğrular ve
APK'yı **Releases** sayfasına `YerelAsistan.apk` olarak koyar. Elle başlatmak için:
Actions → "APK Derle" → Run workflow.
