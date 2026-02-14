#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

clang -fobjc-arc typeless-autoenter.m \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework Carbon \
    -O2 -Wall -Wextra \
    -o typeless-autoenter

echo "build done → ./typeless-autoenter"
