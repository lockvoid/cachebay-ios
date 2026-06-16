#!/usr/bin/env bash
#
# Build a macOS-universal `cachebay-cli` SwiftPM artifact bundle.
#
# SwiftPM can't compile Rust, so the CLI ships as a prebuilt `binaryTarget`
# artifact bundle. This produces `Artifacts/cachebay-cli.artifactbundle` (+ a
# zipped, checksummed copy) from `cli/`, used by both `CACHEBAY_CLI=local`
# builds and the release workflow:
#
#   scripts/build-cli-bundle.sh
#
# Signing: ad-hoc ONLY (`codesign -s -`), no Apple account. Apple Silicon won't
# exec a binary without a valid signature, and `lipo` invalidates the per-arch
# signature the Rust linker applied — so we re-sign the universal binary ad-hoc.
# Developer ID + notarization are NOT needed: they only matter for Gatekeeper,
# which gates *quarantined* downloads, and SwiftPM doesn't quarantine the
# artifacts it fetches. (Add notarization only if you ever distribute the binary
# outside SwiftPM — e.g. a browser download — or hit a Gatekeeper block.)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_DIR="$ROOT/cli"
OUT="$ROOT/Artifacts"
BUNDLE="$OUT/cachebay-cli.artifactbundle"
ZIP="$OUT/cachebay-cli.artifactbundle.zip"
BIN_REL="cachebay-cli/bin/cachebay-cli"
VERSION="$(grep -m1 '^version' "$CLI_DIR/Cargo.toml" | sed -E 's/.*"(.*)".*/\1/')"

echo "==> cachebay-cli $VERSION → artifact bundle"
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

echo "==> ad-hoc codesign (Apple Silicon needs a valid signature; lipo invalidated the linker's)"
codesign --force --sign - "$BUNDLE/$BIN_REL"
codesign --verify --verbose "$BUNDLE/$BIN_REL"

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

echo "==> zip"
( cd "$OUT" && /usr/bin/zip -qry "$(basename "$ZIP")" "$(basename "$BUNDLE")" )

echo "==> checksum"
# SwiftPM's binaryTarget checksum is just the SHA-256 of the zip, so `shasum`
# matches `swift package compute-checksum` and keeps this pipeline Swift-free.
CHECKSUM="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$CHECKSUM" > "$OUT/cachebay-cli.artifactbundle.zip.sha256"
echo
echo "bundle:   $BUNDLE"
echo "zip:      $ZIP"
echo "version:  $VERSION"
echo "checksum: $CHECKSUM"
