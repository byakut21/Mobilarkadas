#!/usr/bin/env bash
# llama.cpp + mtmd'yi Android arm64-v8a için derler ve jniLibs'e kopyalar.
# llama_cpp_dart v0.2.0 deposunun kendi CMake projesini kullanır; böylece
# FFI bağlamaları ile llama.cpp commit'i (b8595b16e) birebir eşleşir.
#
# Gerekli: Android NDK r26+, CMake 3.22+, Ninja
# Kullanım:  ANDROID_NDK=/yol/ndk ./scripts/build_llama_android.sh

set -euo pipefail
: "${ANDROID_NDK:?ANDROID_NDK ortam değişkenini NDK yoluna ayarlayın}"

LCD_TAG="${LCD_TAG:-v0.2.0}"
ABI="arm64-v8a"
API=28
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/llama_cpp_dart"
OUT="$ROOT/android/app/src/main/jniLibs/$ABI"

if [ ! -d "$WORK/.git" ]; then
  git clone --depth 1 --branch "$LCD_TAG" https://github.com/netdur/llama_cpp_dart "$WORK"
  git -C "$WORK" submodule update --init --depth 1 src/llama.cpp
fi

# Vulkan'ı kapat (CPU derlemesi; host'ta shader derleyici gerektirmez, her telefonda çalışır)
sed -i 's/set(GGML_VULKAN ON/set(GGML_VULKAN OFF/' "$WORK/src/CMakeLists.txt"

# armv8.2-a + dotprod: Snapdragon 845 / 2018 sonrası çoğu telefon. Çok eski cihazda
# "illegal instruction" alırsanız ARCH_FLAGS="-march=armv8-a" ile derleyin.
ARCH_FLAGS="${ARCH_FLAGS:--march=armv8.2-a+dotprod+fp16}"

cmake -S "$WORK/src" -B "$WORK/build-android" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$ARCH_FLAGS" \
  -DCMAKE_CXX_FLAGS="$ARCH_FLAGS" \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_LLAMAFILE=OFF \
  -DLLAMA_CURL=OFF

cmake --build "$WORK/build-android" -j"$(nproc)"

mkdir -p "$OUT"
find "$WORK/build-android" -name "*.so" -exec cp -v {} "$OUT/" \;
# c++_shared çalışma zamanı
cp -v "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT/"

echo "jniLibs ($OUT):"
ls -lh "$OUT"
test -f "$OUT/libmtmd.so" && test -f "$OUT/libllama.so"
