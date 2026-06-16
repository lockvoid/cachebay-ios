#!/usr/bin/env bash
#
# Build a macOS-universal `cachebay-cli` SwiftPM artifact bundle.
#
# The Rust CLI can't be compiled by SwiftPM, so we ship it as a prebuilt
# `binaryTarget` artifact bundle (the SwiftLint / Mozilla rust-components
# pattern). This script produces `Artifacts/cachebay-cli.artifactbundle` (+ a
# zipped, checksummed copy) from `cli/`.
#
#   Local dev:   scripts/build-cli-bundle.sh
#                → unsigned bundle for `CACHEBAY_CLI=local` builds.
#
#   Release CI:  CACHEBAY_SIGN_ID="Developer ID Application: …" \
#                CACHEBAY_NOTARY_KEY=AuthKey.p8 CACHEBAY_NOTARY_KEY_ID=… \
#                CACHEBAY_NOTARY_ISSUER=… scripts/build-cli-bundle.sh --sign
#                → codesigned + notarized, ready to upload to the GitHub Release.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_DIR="$ROOT/cli"
OUT="$ROOT/Artifacts"
BUNDLE="$OUT/cachebay-cli.artifactbundle"
ZIP="$OUT/cachebay-cli.artifactbundle.zip"
BIN_REL="cachebay-cli/bin/cachebay-cli"
VERSION="$(grep -m1 '^version' "$CLI_DIR/Cargo.toml" | sed -E 's/.*"(.*)".*/\1/')"

SIGN=0
[[ "${1:-}" == "--sign" ]] && SIGN=1

echo "==> cachebay-cli $VERSION → artifact bundle (sign=$SIGN)"
rm -rf "$BUNDLE" "$ZIP"
mkdir -p "$BUNDLE/cachebay-cli/bin"

echo "==> cargo build (arm64 + x86_64)"
(
  cd "$CLI_DIR"
  rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
  cargo build --release --target aarch64-apple-darwin
  cargo build --release --target x86_64-apple-darwin
)

echo "==> lipo → universal"
lipo -create \
  "$CLI_DIR/target/aarch64-apple-darwin/release/cachebay-cli" \
  "$CLI_DIR/target/x86_64-apple-darwin/release/cachebay-cli" \
  -output "$BUNDLE/$BIN_REL"
chmod +x "$BUNDLE/$BIN_REL"

cat > "$BUNDLE/info.json" <<JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "cachebay-cli": {
      "version": "$VERSION",
      "type": "executable",
      "variants": [
        {
          "path": "$BIN_REL",
          "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"]
        }
      ]
    }
  }
}
JSON

if [[ "$SIGN" == "1" ]]; then
  : "${CACHEBAY_SIGN_ID:?set CACHEBAY_SIGN_ID to a 'Developer ID Application' identity}"
  echo "==> codesign (hardened runtime)"
  codesign --force --options runtime --timestamp \
    --sign "$CACHEBAY_SIGN_ID" "$BUNDLE/$BIN_REL"
fi

echo "==> zip"
( cd "$OUT" && /usr/bin/zip -qry "$(basename "$ZIP")" "$(basename "$BUNDLE")" )

if [[ "$SIGN" == "1" ]]; then
  : "${CACHEBAY_NOTARY_KEY:?path to the App Store Connect API key (.p8)}"
  : "${CACHEBAY_NOTARY_KEY_ID:?App Store Connect API key id}"
  : "${CACHEBAY_NOTARY_ISSUER:?App Store Connect issuer id}"
  echo "==> notarize (online ticket; a bare executable can't be stapled — Gatekeeper verifies on first run)"
  xcrun notarytool submit "$ZIP" \
    --key "$CACHEBAY_NOTARY_KEY" \
    --key-id "$CACHEBAY_NOTARY_KEY_ID" \
    --issuer "$CACHEBAY_NOTARY_ISSUER" \
    --wait
fi

echo "==> checksum"
# SwiftPM's binaryTarget checksum is just the SHA-256 of the zip, so `shasum`
# matches `swift package compute-checksum` — and keeps the release pipeline
# free of any Swift-toolchain dependency (Rust + shasum only).
CHECKSUM="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$CHECKSUM" > "$OUT/cachebay-cli.artifactbundle.zip.sha256"
echo
echo "bundle:   $BUNDLE"
echo "zip:      $ZIP"
echo "version:  $VERSION"
echo "checksum: $CHECKSUM"
