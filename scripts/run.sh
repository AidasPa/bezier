#!/bin/zsh
# Builds and launches Bezier, streaming its stdout/stderr. Usage: scripts/run.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."
scripts/build.sh "${1:-debug}"
pkill -x Bezier 2>/dev/null || true
exec build/Bezier.app/Contents/MacOS/Bezier
