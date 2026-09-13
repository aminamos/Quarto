#!/bin/bash
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$DIR/.." && pwd )"
cd "$DIR/quarto-adskip"

echo "==> Building Rust crate for iOS Device (aarch64-apple-ios)..."
cargo build --release --target aarch64-apple-ios

echo "==> Building Rust crate for iOS Simulator (aarch64-apple-ios-sim)..."
cargo build --release --target aarch64-apple-ios-sim

echo "==> Building Rust crate for iOS Simulator (x86_64-apple-ios)..."
cargo build --release --target x86_64-apple-ios

echo "==> Building Rust crate for macOS (aarch64-apple-darwin)..."
cargo build --release --target aarch64-apple-darwin

echo "==> Building Rust crate for macOS (x86_64-apple-darwin)..."
cargo build --release --target x86_64-apple-darwin

mkdir -p "$DIR/lib"

echo "==> Packaging libraries..."
cp "$DIR/quarto-adskip/target/aarch64-apple-ios/release/libquarto_adskip.a" "$DIR/lib/libquarto_adskip_device.a"

lipo -create \
  "$DIR/quarto-adskip/target/aarch64-apple-ios-sim/release/libquarto_adskip.a" \
  "$DIR/quarto-adskip/target/x86_64-apple-ios/release/libquarto_adskip.a" \
  -output "$DIR/lib/libquarto_adskip_sim.a"

lipo -create \
  "$DIR/quarto-adskip/target/aarch64-apple-darwin/release/libquarto_adskip.a" \
  "$DIR/quarto-adskip/target/x86_64-apple-darwin/release/libquarto_adskip.a" \
  -output "$DIR/lib/libquarto_adskip_macos.a"

# Default fallback
cp "$DIR/lib/libquarto_adskip_sim.a" "$DIR/lib/libquarto_adskip.a"

echo "==> Creating QuartoAdSkip.xcframework..."
FRAMEWORK_DIR="$ROOT_DIR/Frameworks"
mkdir -p "$FRAMEWORK_DIR"
rm -rf "$FRAMEWORK_DIR/QuartoAdSkip.xcframework"

xcodebuild -create-xcframework \
  -library "$DIR/lib/libquarto_adskip_device.a" -headers "$DIR/include" \
  -library "$DIR/lib/libquarto_adskip_sim.a" -headers "$DIR/include" \
  -library "$DIR/lib/libquarto_adskip_macos.a" -headers "$DIR/include" \
  -output "$FRAMEWORK_DIR/QuartoAdSkip.xcframework"

echo "==> Successfully created QuartoAdSkip.xcframework in $FRAMEWORK_DIR/"
