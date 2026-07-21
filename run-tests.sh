#!/bin/bash
# Runs the SuperResCore unit tests.
#
# Uses the classic ("native"/llbuild) build system: Xcode 27's newer
# "swiftbuild" system codesigns the .xctest bundle and fails on some Macs
# with "resource fork, Finder information, or similar detritus not allowed".
# `-Xswiftc -gnone` skips the debug-symbol/dsymutil step some Macs also block.
set -euo pipefail
cd "$(dirname "$0")"
swift test --build-system native -Xswiftc -gnone
