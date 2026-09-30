#!/bin/sh
# Fetch Parakeet Ultra ONNX weights (sherpa nemo_transducer bundle, ~600 MB)
# into the app bundle resources so they install WITH the app.
# No runtime download: CI runs this before xcodegen on every device build.
# Files are git-ignored; this script is the source of truth.
set -eu

REPO="mldecode/parakeet-ultra-onnx-int8"
DEST="$(cd "$(dirname "$0")/../Sources/Models/parakeet-ultra" 2>/dev/null && pwd || echo "")"
if [ -z "$DEST" ]; then
  DEST="$(cd "$(dirname "$0")/.." && pwd)/Sources/Models/parakeet-ultra"
fi
mkdir -p "$DEST"

fetch() {
  name="$1"; min_bytes="$2"
  url="https://huggingface.co/$REPO/resolve/main/$name"
  echo "-> $name"
  curl -sSL --retry 3 -o "$DEST/$name.tmp" "$url"
  size=$(wc -c < "$DEST/$name.tmp" | tr -d ' ')
  if [ "$size" -lt "$min_bytes" ]; then
    echo "error: $name too small ($size bytes), aborting" >&2
    rm -f "$DEST/$name.tmp"
    exit 1
  fi
  mv "$DEST/$name.tmp" "$DEST/$name"
}

fetch "encoder.int8.onnx" 500000000
fetch "decoder.int8.onnx" 8000000
fetch "joiner.int8.onnx" 3000000
fetch "tokens.txt" 50000

echo "ultra weights ready in $DEST"
du -sh "$DEST"
