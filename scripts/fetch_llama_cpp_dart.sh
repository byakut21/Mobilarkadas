#!/usr/bin/env bash
# llama_cpp_dart v0.2.0 kaynağını .build/llama_cpp_dart altına indirir.
# pubspec.yaml bu klasörü yerel yol bağımlılığı olarak kullanır; native derleme de
# aynı kaynağın llama.cpp alt modülünü kullanır (sürüm uyumu garanti).
set -euo pipefail
LCD_TAG="${LCD_TAG:-v0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/llama_cpp_dart"
if [ ! -d "$WORK/.git" ]; then
  git clone --depth 1 --branch "$LCD_TAG" https://github.com/netdur/llama_cpp_dart "$WORK"
fi
# Depodaki geliştiriciye ait kırık sembolik linkleri temizle
find "$WORK" -type l -delete
echo "llama_cpp_dart hazır: $WORK"
