#!/usr/bin/env bash
# Regenerate golden .pmda blobs after ANY markdown-parser crate change.
set -euo pipefail
cd "$(dirname "$0")/../.."
( cd native && cargo run -q -p markdown-parser --bin dump_corpus -- \
    markdown-parser/tests/corpus )
echo "Done. Re-run cargo test -p markdown-parser; commit changed .pmda files together with the crate change."
