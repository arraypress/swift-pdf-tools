#!/bin/bash
# The library ships as source; releasing is tagging. `swift test` is the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
