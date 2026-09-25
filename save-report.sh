#!/usr/bin/env bash
# Save a text + JSON report under samples/
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$DIR/samples"
mkdir -p "$OUT_DIR"
TXT="$OUT_DIR/${HOST}-${STAMP}.txt"
JSON="$OUT_DIR/${HOST}-${STAMP}.json"
"$DIR/check.sh" -j "$JSON" | tee "$TXT"
echo
echo "saved  $TXT"
echo "saved  $JSON"
