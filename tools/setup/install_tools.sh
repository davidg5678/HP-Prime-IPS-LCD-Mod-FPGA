#!/usr/bin/env bash
set -euo pipefail
echo "==> Homebrew: simulation + open-source flashing tools"
brew list icarus-verilog &>/dev/null || brew install icarus-verilog   # NOTE: NOT "iverilog" — that's the binary name
brew list verilator      &>/dev/null || brew install verilator
brew list openfpgaloader &>/dev/null || brew install openfpgaloader

OSS_DIR="$HOME/.local/oss-cad-suite"
if [ ! -d "$OSS_DIR" ]; then
  echo "==> Fetching oss-cad-suite (nextpnr-himbaechel + apycula Gowin backend)"
  ASSET_URL=$(curl -s https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
    | python3 -c "import json,sys; d=json.load(sys.stdin); \
        print(next(a['browser_download_url'] for a in d['assets'] if 'darwin-arm64' in a['name']))")
  TMP=$(mktemp -d)
  curl -L "$ASSET_URL" -o "$TMP/oss-cad-suite.tgz"
  mkdir -p "$OSS_DIR"
  tar -xzf "$TMP/oss-cad-suite.tgz" -C "$OSS_DIR" --strip-components=1
  rm -rf "$TMP"
else
  echo "==> oss-cad-suite already present at $OSS_DIR"
fi
echo
echo "Add to your shell profile (e.g. ~/.zshrc):"
echo "  export PATH=\"$OSS_DIR/bin:\$PATH\""
