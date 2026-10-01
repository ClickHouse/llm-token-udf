#!/usr/bin/env bash
# Builds static binaries for both architectures ClickHouse Cloud runs on and
# packages them in the layout the Native runtime expects:
#
#   count_tokens.zip
#   ├── amd64/
#   │   ├── main          # linux/amd64 executable, statically linked, no arguments
#   │   └── models.json   # data file, deployed next to the binary (resolve it relative to the
#   └── arm64/            #   executable - the process does not start in the bundle directory)
#       ├── main
#       └── models.json
#
# One-time setup: rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
set -euo pipefail
cd "$(dirname "$0")"

cargo build --release --target x86_64-unknown-linux-musl
cargo build --release --target aarch64-unknown-linux-musl

rm -rf dist && mkdir -p dist/amd64 dist/arm64
cp target/x86_64-unknown-linux-musl/release/count_tokens  dist/amd64/main
cp target/aarch64-unknown-linux-musl/release/count_tokens dist/arm64/main
cp models.json dist/amd64/ && cp models.json dist/arm64/

(cd dist && zip -r ../count_tokens.zip amd64 arm64)
ls -la count_tokens.zip
