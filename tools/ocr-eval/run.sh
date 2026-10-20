#!/usr/bin/env bash
# PaddleOCR（PP-OCR）を Android 端末上で動かし、日本語の認識結果と処理時間を測る。
# 使い方は README.md を参照。
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${OCR_EVAL_DIR:-${TMPDIR:-/tmp}/camereon-ocr-eval}"
PADDLEOCR_COMMIT=dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf

# モデル名 Hugging Face のリビジョン ONNX の SHA-256
MODELS="
PP-OCRv6_small_det 28fe5895c24fd108c19eb3e8479f4ab385fbfc62 d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e
PP-OCRv6_small_rec b8f84f0b80c529de40b4fbb3544b84fa7233a513 5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634
PP-OCRv6_tiny_det 2ba1506c0380b8f0b03dd142459aac66d4421f6c 193bab7a04fca699a6c82e6abb5b81bdb28177f0abd4062552b04908dafb19f8
PP-OCRv6_tiny_rec 2612ab37152ae0a677521bae4e1e3d4fb4cf7c30 9ef676d6ed3c88256a2d92c640c44f25b0c40947e111b14b8be8f594091563e6
PP-OCRv5_mobile_det e6f4fa85f00e168c862bc462aebca69eef9b3d3d a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d
PP-OCRv5_mobile_rec ed152b8b495f84de93cda5709d768548a9127622 da72dc72ca4dc220df0dfde68c1dedc31c58d3e76a25871122e5056227d50092
"

mkdir -p "$WORK_DIR"
SRC="$WORK_DIR/PaddleOCR"
APP="$SRC/deploy/ppocr-android"
TEST_SRC="$APP/ppocr-sdk/src/androidTest"

echo "[1/5] PaddleOCR の Android SDK を取得 ($PADDLEOCR_COMMIT)"
if [ ! -d "$SRC/.git" ]; then
  git clone -q --filter=blob:none --sparse https://github.com/PaddlePaddle/PaddleOCR.git "$SRC"
  git -C "$SRC" sparse-checkout set deploy/ppocr-android
fi
git -C "$SRC" fetch -q --depth 1 origin "$PADDLEOCR_COMMIT"
git -C "$SRC" checkout -q --force "$PADDLEOCR_COMMIT"

# 公式が使う quickbirdstudios/opencv 4.5.3 の arm64 版は、Android 12 以降で
# __sfp_handle_exceptions が見つからず読み込めないため、OpenCV 公式の Maven 版に差し替える
sed -i.bak \
  -e 's|^opencv = "4.5.3"|opencv = "4.10.0"|' \
  -e 's|group = "com.quickbirdstudios", name = "opencv"|group = "org.opencv", name = "opencv"|' \
  "$APP/gradle/libs.versions.toml"

echo "[2/5] モデルを取得"
while read -r name revision sha256; do
  [ -z "$name" ] && continue
  set_name="${name%_*}"
  kind="${name##*_}"
  dir="$TEST_SRC/assets/models_eval/$set_name/$kind"
  mkdir -p "$dir"
  files="inference.onnx"
  [ "$kind" = rec ] && files="inference.onnx inference.yml"
  for f in $files; do
    [ -f "$dir/$f" ] || curl -sfL -o "$dir/$f" \
      "https://huggingface.co/PaddlePaddle/${name}_onnx/resolve/$revision/$f"
  done
  echo "$sha256  $dir/inference.onnx" | shasum -a 256 -c --quiet
done <<< "$MODELS"

echo "[3/5] テスト画像を作成（架空の個人情報）"
mkdir -p "$TEST_SRC/assets/eval"
python3 "$TOOL_DIR/make_images.py" "$TEST_SRC/assets/eval"
mkdir -p "$TEST_SRC/java/com/paddle/ocr/eval"
cp "$TOOL_DIR/CamereonEvalTest.kt" "$TEST_SRC/java/com/paddle/ocr/eval/"

echo "[4/5] テスト APK をビルドしてインストール"
echo "sdk.dir=${ANDROID_HOME:-$HOME/Library/Android/sdk}" > "$APP/local.properties"
# 公式 SDK の Gradle 8.9 は JDK 25 で動かないため JDK 21 を使う
(cd "$APP" && mise exec java@temurin-21 -- sh ./gradlew -q :ppocr-sdk:assembleDebugAndroidTest)
adb install -r -t "$APP/ppocr-sdk/build/outputs/apk/androidTest/debug/ppocr-sdk-debug-androidTest.apk" >/dev/null

echo "[5/5] 端末で実行"
OUT="$WORK_DIR/result-$(adb shell getprop ro.product.model | tr -d '\r ' )-$(date +%Y%m%d%H%M%S).txt"
for limit in "" 960; do
  extra=()
  [ -n "$limit" ] && extra=(-e limitSide "$limit")
  adb logcat -c
  adb shell am instrument -w "${extra[@]}" \
    -e class com.paddle.ocr.eval.CamereonEvalTest \
    com.paddle.ocr.test/androidx.test.runner.AndroidJUnitRunner | grep -E "^OK|FAIL|crash" || true
  adb logcat -d -s System.out:I | grep "\[EVAL\]" | sed 's/^.*\[EVAL\]/[EVAL]/' >> "$OUT"
done
echo "結果: $OUT"
